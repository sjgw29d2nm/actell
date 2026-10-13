/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "developer_service.h"
#include "wifi_board.h"
#include "nd_server.h"
#include "nd_http.h"
#include "nd_relay.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>

static bool (*usb_online_callback)(void);
static uint32_t (*usb_epoch_callback)(void);
static uint32_t usb_interface_index;
typedef struct { bool wifi;uint32_t epoch; } link_lifetime;
typedef struct {
    bool wifi;
    int listener;
    nd_server server;
    nd_http http;
    nd_link link;
    link_lifetime diagnostic_lifetime,relay_lifetime;
    uint64_t listen_retry;
} service_link;
typedef struct { nd_relay_job job;int fd; } relay_worker;
static void rotate(nd_http *http) {
    uint8_t nonce[16];esp_fill_random(nonce,sizeof nonce);
    for(size_t i=0;i<sizeof nonce;i++)snprintf(http->token+2*i,3,"%02x",nonce[i]);
}
static bool alive(void *context) {
    link_lifetime *lifetime=context;
    return lifetime->wifi?(wifi_board_online()&&wifi_board_epoch()==lifetime->epoch):
        (usb_online_callback()&&usb_epoch_callback()==lifetime->epoch);
}
static bool owns_source(const nd_relay *relay,const service_link *source) {
    return relay->claimed&&!memcmp(relay->base.local4,source->link.local4,4)&&!memcmp(relay->base.peer4,source->link.peer4,4);
}
static void relay_task(void *argument) {
    relay_worker *worker=argument;(void)nd_relay_run(&worker->job,worker->fd,NULL);vTaskDelete(NULL);
}
static bool read_line(bridge_io *io,char *line,size_t capacity,uint64_t deadline) {
    size_t length=0;
    while(length+1<capacity) {
        uint8_t value=0;if(bridge_read_exact(io,&value,1,deadline)!=BRIDGE_OK)break;
        if(value=='\n'){line[length]=0;return true;}
        if(value=='\r'){
            if(bridge_read_exact(io,&value,1,deadline)==BRIDGE_OK&&value=='\n'){line[length]=0;return true;}
            break;
        }
        if(value<32||value>126)break;
        line[length++]=(char)value;
    }
    line[0]=0;return false;
}
static void prepare_listener(service_link *source) {
    if(source->listener>=0||!source->link.interface_index||nd_now(NULL)<source->listen_retry)return;
    source->listen_retry=nd_now(NULL)+1000;
    int descriptor=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);if(descriptor<0)return;
    struct sockaddr_in address={.sin_family=AF_INET,.sin_port=htons(28767)};
    memcpy(&address.sin_addr,source->link.local4,4);
    if(bind(descriptor,(struct sockaddr *)&address,sizeof address)||listen(descriptor,1)||fcntl(descriptor,F_SETFL,O_NONBLOCK)<0) {
        close(descriptor);return;
    }
    source->listener=descriptor;
    ESP_LOGI("pa_developer","%s developer transport listening; credentials omitted",source->wifi?"authenticated Wi-Fi":"USB");
}
static void accept_command(service_link *source,nd_relay *relay,relay_worker workers[2],char *output,size_t output_capacity) {
    if(source->listener<0||!alive(&source->diagnostic_lifetime))return;
    struct sockaddr_in peer={0};socklen_t length=sizeof peer;
    int descriptor=accept(source->listener,(struct sockaddr *)&peer,&length);if(descriptor<0)return;
    if(memcmp(&peer.sin_addr,source->link.peer4,4)||fcntl(descriptor,F_SETFL,O_NONBLOCK)<0){close(descriptor);return;}
    nd_socket socket={.fd=descriptor,.link=&source->link};bridge_io io=nd_socket_io(&socket);
    char command[ND_RELAY_LINE_LIMIT+1];uint64_t deadline=nd_now(NULL)+3000;
    if(source->wifi) {
        bool authorized=read_line(&io,command,sizeof command,deadline)&&!strncmp(command,"NW1 AUTH ",9)&&wifi_board_authorize(command+9);
        memset(command,0,sizeof command);
        if(!authorized){nd_socket_close(&socket);return;}
        /* AUTH consumes one prefix, with no ACK and no payload forwarding. */
        deadline=nd_now(NULL)+3000;
    }
    bool complete=read_line(&io,command,sizeof command,deadline);
    if(complete&&(!strncmp(command,"NR1 ",4)||!strncmp(command,"NL1 ",4))) {
        nd_relay_job cancellation={0};
        relay_worker *worker=(!strncmp(command,"NR1 OPEN ",9)||!strncmp(command,"NL1 OPEN ",9))?&workers[0]:
            !strncmp(command,"NR1 TUNNEL ",11)?&workers[1]:NULL;
        if(!nd_relay_busy(relay))source->relay_lifetime=source->diagnostic_lifetime;
        nd_link pinned=source->link;pinned.context=&source->relay_lifetime;
        bridge_status result=nd_relay_prepare(relay,&source->server,&pinned,command,worker?&worker->job:&cancellation);
        if(result==BRIDGE_OK&&worker) {
            worker->fd=descriptor;
            if(xTaskCreate(relay_task,"device_relay",8192,worker,4,NULL)==pdPASS)socket.fd=-1;
            else nd_relay_abandon(&worker->job);
        } else {
            bool lockdown=command[1]=='L';
            const char *reply=lockdown?(result==BRIDGE_OK?"NL1 OK\n":"NL1 ERR rejected\n"):
                (result==BRIDGE_OK?"NR1 OK\n":"NR1 ERR rejected\n");
            (void)bridge_write_exact(&io,(const uint8_t *)reply,strlen(reply),nd_now(NULL)+500);
        }
    } else if(complete&&strstr(command," HTTP/")!=NULL) {
        bridge_status result=nd_http_serve(&source->http,&source->server,&source->link,&io,command,output,output_capacity,deadline);
        ESP_LOGI("ncm_http","%s result=%s socketError=%d",!strncmp(command,"POST ",5)?"POST":"GET",bridge_status_name(result),socket.error);
    } else if(complete&&nd_server_command(&source->server,&source->link,command,output,output_capacity)==BRIDGE_OK) {
        (void)bridge_write_exact(&io,(const uint8_t *)output,strlen(output),nd_now(NULL)+1000);
    }
    memset(command,0,sizeof command);nd_socket_close(&socket);
}
static void serve(void *unused) {
    (void)unused;
    static service_link links[2];static nd_relay relay;static relay_worker workers[2];static char output[ND_HTTP_BODY_LIMIT];
    for(size_t i=0;i<2;i++) {
        service_link *source=&links[i];source->wifi=i==1;source->listener=-1;
        source->diagnostic_lifetime=(link_lifetime){.wifi=source->wifi,.epoch=source->wifi?wifi_board_epoch():usb_epoch_callback()};
        source->relay_lifetime=source->diagnostic_lifetime;
        source->link=(nd_link){.local4={192,168,(uint8_t)(source->wifi?8:7),1},.peer4={192,168,(uint8_t)(source->wifi?8:7),2},.alive=alive,.context=&source->diagnostic_lifetime};
        rotate(&source->http);
    }
    ESP_LOGI("pa_developer","ND1 / NR1 / NL1 share one USB/Wi-Fi relay owner; no payload logging");
    for(;;) {
        for(size_t i=0;i<2;i++) {
            service_link *source=&links[i];uint32_t current_epoch=source->wifi?wifi_board_epoch():usb_epoch_callback();
            if(current_epoch!=source->diagnostic_lifetime.epoch) {
                if(owns_source(&relay,source))nd_relay_cancel(&relay);
                source->diagnostic_lifetime.epoch=current_epoch;nd_server_reset(&source->server);rotate(&source->http);
            }
            source->link.interface_index=source->wifi?wifi_board_network_index():usb_interface_index;
            if(owns_source(&relay,source)&&!alive(&source->relay_lifetime))nd_relay_cancel(&relay);
            prepare_listener(source);accept_command(source,&relay,workers,output,sizeof output);
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}
esp_err_t developer_service_start(bool (*online)(void),uint32_t (*epoch)(void),uint32_t interface_index) {
    if(!online||!epoch||!interface_index)return ESP_ERR_INVALID_ARG;
    usb_online_callback=online;usb_epoch_callback=epoch;usb_interface_index=interface_index;
    return xTaskCreate(serve,"ncm_developer",32768,NULL,4,NULL)==pdPASS?ESP_OK:ESP_ERR_NO_MEM;
}
