/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "developer_service.h"
#include "nd_server.h"
#include "nd_http.h"
#include "nd_relay.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "lwip/if_api.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static bool (*usb_online_callback)(void);
static uint32_t (*usb_epoch_callback)(void);
static uint32_t usb_interface_index;
enum gate_kind { GATE_IDLE,GATE_RELAY,GATE_INPUT };
static atomic_uint operation_gate;
typedef struct { uint32_t epoch; } link_lifetime;
typedef struct {
    int listener;
    nd_server server;
    nd_http http;
    nd_link link;
    link_lifetime diagnostic_lifetime,relay_lifetime;
    uint64_t listen_retry;
} service_link;
typedef struct { nd_relay_job job;int fd; } relay_worker;
bool developer_service_busy(void) { return atomic_load(&operation_gate)!=GATE_IDLE; }
bool developer_service_reserve_input(void) {
    unsigned expected=GATE_IDLE;return atomic_compare_exchange_strong(&operation_gate,&expected,GATE_INPUT);
}
void developer_service_release_input(void) {
    unsigned expected=GATE_INPUT;(void)atomic_compare_exchange_strong(&operation_gate,&expected,GATE_IDLE);
}
static void reap_relay(nd_relay *relay) {
    if(!nd_relay_busy(relay)) {
        unsigned expected=GATE_RELAY;(void)atomic_compare_exchange_strong(&operation_gate,&expected,GATE_IDLE);
    }
}
static void rotate(nd_http *http) {
    uint8_t nonce[16];esp_fill_random(nonce,sizeof nonce);
    for(size_t i=0;i<sizeof nonce;i++)snprintf(http->token+2*i,3,"%02x",nonce[i]);
}
static bool alive(void *context) {
    link_lifetime *lifetime=context;
    return usb_online_callback()&&usb_epoch_callback()==lifetime->epoch;
}
static bool owns_source(const nd_relay *relay,const service_link *source) {
    return relay->claimed&&relay->base.interface_index==source->link.interface_index&&
        !memcmp(relay->base.local4,source->link.local4,4)&&!memcmp(relay->base.peer4,source->link.peer4,4);
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
    if(source->listener>=0||!source->link.interface_index||!alive(&source->diagnostic_lifetime)||nd_now(NULL)<source->listen_retry)return;
    source->listen_retry=nd_now(NULL)+1000;
    int descriptor=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);if(descriptor<0)return;
    struct ifreq device={0};
    struct sockaddr_in address={.sin_family=AF_INET,.sin_port=htons(28767)};
    memcpy(&address.sin_addr,source->link.local4,4);
    if(!lwip_if_indextoname(source->link.interface_index,device.ifr_name)||
       setsockopt(descriptor,SOL_SOCKET,SO_BINDTODEVICE,&device,sizeof device)||
       bind(descriptor,(struct sockaddr *)&address,sizeof address)||listen(descriptor,1)||fcntl(descriptor,F_SETFL,O_NONBLOCK)<0) {
        close(descriptor);return;
    }
    source->listener=descriptor;
    ESP_LOGI("pa_developer","USB developer transport listening");
}
static void accept_command(service_link *source,nd_relay *relay,relay_worker workers[2],char *output,size_t output_capacity) {
    if(source->listener<0||!alive(&source->diagnostic_lifetime))return;
    struct sockaddr_in peer={0};socklen_t length=sizeof peer;
    int descriptor=accept(source->listener,(struct sockaddr *)&peer,&length);if(descriptor<0)return;
    uint8_t peer_address[4];memcpy(peer_address,&peer.sin_addr,4);
    if(memcmp(peer_address,source->link.peer4,4)!=0||
       fcntl(descriptor,F_SETFL,O_NONBLOCK)<0){close(descriptor);return;}
    nd_socket socket={.fd=descriptor,.link=&source->link};bridge_io io=nd_socket_io(&socket);
    char command[ND_RELAY_LINE_LIMIT+1];uint64_t deadline=nd_now(NULL)+3000;
    bool complete=read_line(&io,command,sizeof command,deadline);
    if(complete&&(!strncmp(command,"NR1 ",4)||!strncmp(command,"NL1 ",4))) {
        nd_relay_job cancellation={0};bool opening=!strncmp(command,"NR1 OPEN ",9)||!strncmp(command,"NL1 OPEN ",9);
        relay_worker *worker=opening?&workers[0]:!strncmp(command,"NR1 TUNNEL ",11)?&workers[1]:NULL;
        unsigned expected=GATE_IDLE;
        bool reserved=!opening||atomic_compare_exchange_strong(&operation_gate,&expected,GATE_RELAY);
        if(!nd_relay_busy(relay))source->relay_lifetime=source->diagnostic_lifetime;
        nd_link pinned=source->link;pinned.context=&source->relay_lifetime;
        bridge_status result=reserved?nd_relay_prepare(relay,&source->server,&pinned,command,worker?&worker->job:&cancellation):BRIDGE_E_LIMIT;
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
        reap_relay(relay);
    } else if(complete&&strstr(command," HTTP/")!=NULL) {
        bridge_status result=nd_http_serve(&source->http,&source->server,&source->link,&io,command,output,output_capacity,deadline);
        ESP_LOGI("ncm_http","%s result=%s socketError=%d",!strncmp(command,"POST ",5)?"POST":"GET",bridge_status_name(result),socket.error);
    } else if(complete&&nd_server_command(&source->server,&source->link,command,output,output_capacity)==BRIDGE_OK) {
        (void)bridge_write_exact(&io,(const uint8_t *)output,strlen(output),nd_now(NULL)+1000);
    }
    memset(command,0,sizeof command);nd_socket_close(&socket);
}
static void refresh_source(service_link *source,nd_relay *relay) {
    const uint8_t local[4]={192,168,7,1},peer[4]={192,168,7,2};
    uint32_t index=usb_interface_index,epoch=usb_epoch_callback();
    bool changed=epoch!=source->diagnostic_lifetime.epoch||index!=source->link.interface_index||
        memcmp(local,source->link.local4,4)||memcmp(peer,source->link.peer4,4);
    if(changed) {
        if(owns_source(relay,source))nd_relay_cancel(relay);
        if(source->listener>=0){close(source->listener);source->listener=-1;}
        source->listen_retry=0;source->diagnostic_lifetime.epoch=epoch;nd_server_reset(&source->server);rotate(&source->http);
        memcpy(source->link.local4,local,4);memcpy(source->link.peer4,peer,4);source->link.interface_index=index;
    }
    if(owns_source(relay,source)&&!alive(&source->relay_lifetime))nd_relay_cancel(relay);
}
static void serve(void *unused) {
    (void)unused;
    static service_link source;static nd_relay relay;static relay_worker workers[2];static char output[ND_HTTP_BODY_LIMIT];
    source.listener=-1;source.link=(nd_link){.alive=alive,.context=&source.diagnostic_lifetime};rotate(&source.http);
    ESP_LOGI("pa_developer","USB ND1 / NR1 / NL1 and BLE input share one owner; no payload logging");
    for(;;) {
        reap_relay(&relay);
        refresh_source(&source,&relay);prepare_listener(&source);accept_command(&source,&relay,workers,output,sizeof output);
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}
esp_err_t developer_service_start(bool (*online)(void),uint32_t (*epoch)(void),uint32_t interface_index) {
    if(!online||!epoch||!interface_index)return ESP_ERR_INVALID_ARG;
    usb_online_callback=online;usb_epoch_callback=epoch;usb_interface_index=interface_index;
    return xTaskCreate(serve,"ncm_developer",32768,NULL,4,NULL)==pdPASS?ESP_OK:ESP_ERR_NO_MEM;
}
