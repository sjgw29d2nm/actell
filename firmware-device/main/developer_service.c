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
enum source_kind { SOURCE_USB,SOURCE_AP,SOURCE_ROUTER };
enum gate_kind { GATE_IDLE,GATE_RELAY,GATE_CONFIG };
static atomic_uint operation_gate;
typedef struct { enum source_kind kind;uint32_t epoch; } link_lifetime;
typedef struct {
    enum source_kind kind;
    int listener;
    nd_server server;
    nd_http http;
    nd_link link;
    uint8_t netmask[4];
    link_lifetime diagnostic_lifetime,relay_lifetime;
    uint64_t listen_retry;
} service_link;
typedef struct { nd_relay_job job;int fd; } relay_worker;
bool developer_service_busy(void) { return atomic_load(&operation_gate)!=GATE_IDLE; }
bool developer_service_reserve_wifi_configuration(void) {
    unsigned expected=GATE_IDLE;return atomic_compare_exchange_strong(&operation_gate,&expected,GATE_CONFIG);
}
void developer_service_release_wifi_configuration(void) {
    unsigned expected=GATE_CONFIG;(void)atomic_compare_exchange_strong(&operation_gate,&expected,GATE_IDLE);
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
    if(lifetime->kind==SOURCE_AP)return wifi_board_online()&&wifi_board_epoch()==lifetime->epoch;
    if(lifetime->kind==SOURCE_ROUTER)return wifi_board_router_online()&&wifi_board_router_epoch()==lifetime->epoch;
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
    ESP_LOGI("pa_developer","%s developer transport listening; credentials omitted",source->kind==SOURCE_USB?"USB":source->kind==SOURCE_AP?"authenticated AP":"authenticated router Wi-Fi");
}
static bool router_peer(const service_link *source,const uint8_t peer[4]) {
    uint32_t address=0,local=0,mask=0;memcpy(&address,peer,4);memcpy(&local,source->link.local4,4);memcpy(&mask,source->netmask,4);
    address=ntohl(address);local=ntohl(local);mask=ntohl(mask);uint32_t inverse=~mask;
    bool private=(address&0xff000000)==0x0a000000||(address&0xfff00000)==0xac100000||(address&0xffff0000)==0xc0a80000;
    return private&&mask>=0xff000000&&mask<=0xfffffffc&&!(inverse&(inverse+1))&&
        (address&mask)==(local&mask)&&address!=local&&address!=(local&mask)&&address!=((local&mask)|inverse);
}
/* The router has multiple LAN peers. Only IPv4 addresses equal to the
 * authenticated TCP peer enter this source's catalog and NR1 indices. */
static bridge_status router_command(service_link *source,const char *command,char *output,size_t capacity) {
    if(strcmp(command,"DISCOVER4")&&strcmp(command,"DISCOVER6"))return nd_server_command(&source->server,&source->link,command,output,capacity);
    nd_server *server=&source->server;nd_server_reset(server);int error=0;
    bridge_status result=!strcmp(command,"DISCOVER4")?nd_discover(&source->link,4,&server->catalog,nd_now(NULL)+3000,&error):BRIDGE_E_UNSUPPORTED;
    if(result==BRIDGE_OK) {
        nd_endpoint candidates[ND_ENDPOINTS];size_t count=nd_dns_endpoints(&server->catalog,source->link.peer4,candidates,ND_ENDPOINTS);
        for(size_t i=0;i<count;i++)if(candidates[i].family==4&&!memcmp(candidates[i].address,source->link.peer4,4))server->endpoints[server->count++]=candidates[i];
        server->expires=nd_now(NULL)+5000;if(server->catalog.expires<server->expires)server->expires=server->catalog.expires;
        if(server->expires<=nd_now(NULL))server->count=0;
    }
    int length=snprintf(output,capacity,"{\"protocol\":\"ND1\",\"layer\":\"discovery\",\"result\":\"%s\",\"osError\":%d,\"generation\":%"PRIu32",\"authenticated\":false,\"endpoints\":[",result==BRIDGE_OK?(server->count?"candidates":"no-candidates"):bridge_status_name(result),error,server->generation);
    if(length<0||(size_t)length>=capacity)return BRIDGE_E_LIMIT;
    size_t used=(size_t)length;
    for(size_t i=0;i<server->count;i++) {
        nd_endpoint *endpoint=&server->endpoints[i];
        length=snprintf(output+used,capacity-used,"%s{\"index\":%zu,\"service\":\"%s\",\"family\":4,\"port\":%u}",i?",":"",i,nd_service_name(endpoint->service),endpoint->port);
        if(length<0||(size_t)length>=capacity-used)return BRIDGE_E_LIMIT;
        used+=(size_t)length;
    }
    if(used+4>capacity)return BRIDGE_E_LIMIT;
    memcpy(output+used,"]}\n",4);return BRIDGE_OK;
}
static void accept_command(service_link *source,nd_relay *relay,relay_worker workers[2],char *output,size_t output_capacity) {
    if(source->listener<0||!alive(&source->diagnostic_lifetime))return;
    struct sockaddr_in peer={0};socklen_t length=sizeof peer;
    int descriptor=accept(source->listener,(struct sockaddr *)&peer,&length);if(descriptor<0)return;
    uint8_t peer_address[4];memcpy(peer_address,&peer.sin_addr,4);
    if((source->kind==SOURCE_ROUTER?!router_peer(source,peer_address):memcmp(peer_address,source->link.peer4,4)!=0)||
       fcntl(descriptor,F_SETFL,O_NONBLOCK)<0){close(descriptor);return;}
    nd_socket socket={.fd=descriptor,.link=&source->link};bridge_io io=nd_socket_io(&socket);
    char command[ND_RELAY_LINE_LIMIT+1];uint64_t deadline=nd_now(NULL)+3000;
    if(source->kind!=SOURCE_USB) {
        bool authorized=read_line(&io,command,sizeof command,deadline)&&!strncmp(command,"NW1 AUTH ",9)&&wifi_board_authorize(command+9);
        memset(command,0,sizeof command);
        if(!authorized){nd_socket_close(&socket);return;}
        /* AUTH consumes one prefix, with no ACK and no payload forwarding. */
        if(source->kind==SOURCE_ROUTER&&memcmp(peer_address,source->link.peer4,4)) {
            if(nd_relay_busy(relay)){nd_socket_close(&socket);return;}
            memcpy(source->link.peer4,peer_address,4);nd_server_reset(&source->server);rotate(&source->http);
        }
        deadline=nd_now(NULL)+3000;
    }
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
    } else if(complete&&strstr(command," HTTP/")!=NULL&&source->kind!=SOURCE_ROUTER) {
        bridge_status result=nd_http_serve(&source->http,&source->server,&source->link,&io,command,output,output_capacity,deadline);
        ESP_LOGI("ncm_http","%s result=%s socketError=%d",!strncmp(command,"POST ",5)?"POST":"GET",bridge_status_name(result),socket.error);
    } else if(complete&&(source->kind==SOURCE_ROUTER?router_command(source,command,output,output_capacity):nd_server_command(&source->server,&source->link,command,output,output_capacity))==BRIDGE_OK) {
        (void)bridge_write_exact(&io,(const uint8_t *)output,strlen(output),nd_now(NULL)+1000);
    }
    memset(command,0,sizeof command);nd_socket_close(&socket);
}
static void refresh_source(service_link *source,nd_relay *relay) {
    uint8_t local[4]={192,168,7,1},peer[4]={192,168,7,2},mask[4]={255,255,255,0};
    uint32_t index=usb_interface_index,epoch=usb_epoch_callback();
    if(source->kind==SOURCE_AP) {
        if(!wifi_board_ap_link(local,peer,&index,&epoch))index=0;
    } else if(source->kind==SOURCE_ROUTER) {
        memset(local,0,sizeof local);memset(peer,0,sizeof peer);memset(mask,0,sizeof mask);index=0;epoch=wifi_board_router_epoch();
        (void)wifi_board_router_link(local,mask,&index,&epoch);
        if(epoch==source->diagnostic_lifetime.epoch&&index==source->link.interface_index&&!memcmp(local,source->link.local4,4))memcpy(peer,source->link.peer4,4);
    }
    bool changed=epoch!=source->diagnostic_lifetime.epoch||index!=source->link.interface_index||
        memcmp(local,source->link.local4,4)||memcmp(peer,source->link.peer4,4)||memcmp(mask,source->netmask,4);
    if(changed) {
        if(owns_source(relay,source))nd_relay_cancel(relay);
        if(source->listener>=0){close(source->listener);source->listener=-1;}
        source->listen_retry=0;source->diagnostic_lifetime.epoch=epoch;nd_server_reset(&source->server);rotate(&source->http);
        memcpy(source->link.local4,local,4);memcpy(source->link.peer4,peer,4);memcpy(source->netmask,mask,4);source->link.interface_index=index;
    }
    if(owns_source(relay,source)&&!alive(&source->relay_lifetime))nd_relay_cancel(relay);
}
static void serve(void *unused) {
    (void)unused;
    static service_link links[3];static nd_relay relay;static relay_worker workers[2];static char output[ND_HTTP_BODY_LIMIT];
    for(size_t i=0;i<3;i++) {
        service_link *source=&links[i];source->kind=(enum source_kind)i;source->listener=-1;
        source->diagnostic_lifetime=(link_lifetime){.kind=source->kind};source->relay_lifetime=source->diagnostic_lifetime;
        source->link=(nd_link){.alive=alive,.context=&source->diagnostic_lifetime};rotate(&source->http);
    }
    ESP_LOGI("pa_developer","ND1 / NR1 / NL1 share one USB/AP/router relay owner; no payload logging");
    for(;;) {
        reap_relay(&relay);
        for(size_t i=0;i<3;i++) {
            service_link *source=&links[i];refresh_source(source,&relay);prepare_listener(source);accept_command(source,&relay,workers,output,sizeof output);
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}
esp_err_t developer_service_start(bool (*online)(void),uint32_t (*epoch)(void),uint32_t interface_index) {
    if(!online||!epoch||!interface_index)return ESP_ERR_INVALID_ARG;
    usb_online_callback=online;usb_epoch_callback=epoch;usb_interface_index=interface_index;
    return xTaskCreate(serve,"ncm_developer",32768,NULL,4,NULL)==pdPASS?ESP_OK:ESP_ERR_NO_MEM;
}
