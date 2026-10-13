/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "wifi_board.h"
#include "developer_service.h"
#include "cJSON.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lwip/inet.h"
#include "lwip/netif.h"
#include "lwip/tcpip.h"
#include "apps/dhcpserver/dhcpserver.h"
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static const char *TAG="suiban_wifi";
typedef struct { uint32_t version;char ssid[33],passphrase[65],relay_token[65]; } wifi_credentials;
/* Versioned independent blob; the last successful CIDR selects the AP pool at boot. */
typedef struct { uint32_t version;char ssid[33],passphrase[64];uint32_t address,netmask; } router_credentials;
enum router_phase { ROUTER_UNCONFIGURED,ROUTER_CONNECTING,ROUTER_READY,ROUTER_FAILED };
static wifi_credentials credentials;
static router_credentials saved_router,pending_router;
static char device_id[13],router_error[32];
static bool credentials_ready,saved_router_ready,router_attempt_active,router_got_ip,reconnect_saved,router_requested_disconnect;
static enum router_phase router_phase;
static SemaphoreHandle_t credentials_lock,router_lock;
static QueueHandle_t router_queue;
static TaskHandle_t router_task;
static esp_netif_t *access_point,*station;
static atomic_bool access_point_ready,peer_ready,router_ready;
static atomic_uint_least32_t link_epoch=1,interface_index,router_epoch=1,router_index;
static atomic_uint_least32_t ap_address,ap_peer;
static uint32_t router_address,router_netmask;
static esp_event_handler_instance_t wifi_handler,ip_handler;
/* Only the serialized default event loop reads or writes this AP station identity. */
static bool station_associated;
static uint8_t station_mac[6];

static bool utf8_ssid(const char *value) {
    size_t length=strnlen(value,33);if(!length||length>32)return false;
    for(size_t i=0;i<length;) {
        unsigned char c=(unsigned char)value[i++];
        if(c<0x80){if(c<0x20||c==0x7f)return false;continue;}
        size_t count=c>=0xc2&&c<=0xdf?1:c>=0xe0&&c<=0xef?2:c>=0xf0&&c<=0xf4?3:0;
        if(!count||count>length-i)return false;
        unsigned char first=(unsigned char)value[i];
        if((c==0xe0&&first<0xa0)||(c==0xed&&first>=0xa0)||(c==0xf0&&first<0x90)||(c==0xf4&&first>=0x90))return false;
        for(size_t k=0;k<count;k++)if(((unsigned char)value[i++]&0xc0)!=0x80)return false;
    }
    return true;
}
static bool router_valid(const router_credentials *value) {
    if(value->version!=1||!utf8_ssid(value->ssid))return false;
    size_t length=strnlen(value->passphrase,sizeof value->passphrase);
    if(length&&(length<8||length>63))return false;
    for(size_t i=0;i<length;i++)if((unsigned char)value->passphrase[i]<0x20||(unsigned char)value->passphrase[i]>0x7e)return false;
    return true;
}
static bool private_ip(uint32_t address) {
    return (address&0xff000000)==0x0a000000||(address&0xfff00000)==0xac100000||(address&0xffff0000)==0xc0a80000;
}
static bool router_network_valid(const esp_netif_ip_info_t *info) {
    uint32_t address=ntohl(info->ip.addr),mask=ntohl(info->netmask.addr),inverse=~mask;
    if(!private_ip(address)||mask<0xff000000||mask>0xfffffffc||(inverse&(inverse+1)))return false;
    return address!=(address&mask)&&address!=((address&mask)|inverse);
}
static uint32_t selected_ap_pool(uint32_t address,uint32_t netmask) {
    uint32_t mask=ntohl(netmask),subnet=ntohl(address)&mask;
    return address&&mask&&subnet==(0xc0a80801&mask)?0xac1ffe01:0xc0a80801;
}
static esp_err_t router_store(router_credentials *value,bool write) {
    nvs_handle_t store;esp_err_t result=nvs_open("suiban_wifi",write?NVS_READWRITE:NVS_READONLY,&store);
    if(result!=ESP_OK)return result;
    if(write){result=nvs_set_blob(store,"router",value,sizeof *value);if(result==ESP_OK)result=nvs_commit(store);}
    else {
        size_t size=sizeof *value;result=nvs_get_blob(store,"router",value,&size);
        esp_netif_ip_info_t info={.ip.addr=value->address,.netmask.addr=value->netmask};
        if(result==ESP_OK&&(size!=sizeof *value||!router_valid(value)||!router_network_valid(&info)))result=ESP_ERR_INVALID_STATE;
    }
    nvs_close(store);return result;
}
static void router_revoke(void) { atomic_store(&router_ready,false);atomic_fetch_add(&router_epoch,1); }
/* router_lock held; errors contain public codes only. */
static void router_failed(const char *reason) {
    router_phase=ROUTER_FAILED;snprintf(router_error,sizeof router_error,"%s",reason);router_got_ip=false;router_revoke();
}
static bool hex_string(const char *value,size_t length,size_t capacity) {
    if(strnlen(value,capacity)!=length)return false;
    for(size_t i=0;i<length;i++)if(!((value[i]>='0'&&value[i]<='9')||(value[i]>='a'&&value[i]<='f')))return false;
    return true;
}
static void ip4_string(uint32_t address,char output[16]) {
    esp_ip4_addr_t ip={.addr=address};snprintf(output,16,IPSTR,IP2STR(&ip));
}
static esp_err_t load_credentials(void) {
    nvs_handle_t store;esp_err_t result=nvs_open("suiban_wifi",NVS_READWRITE,&store);if(result!=ESP_OK)return result;
    wifi_credentials candidate={0};size_t length=sizeof candidate;
    result=nvs_get_blob(store,"credentials",&candidate,&length);
    if(result==ESP_ERR_NVS_NOT_FOUND) {
        candidate.version=1;snprintf(candidate.ssid,sizeof candidate.ssid,"Suiban-v1-%.6s",device_id+6);
        uint8_t random[32];esp_fill_random(random,sizeof random);
        for(size_t i=0;i<16;i++)snprintf(candidate.passphrase+i*2,3,"%02x",random[i]);
        esp_fill_random(random,sizeof random);
        for(size_t i=0;i<sizeof random;i++)snprintf(candidate.relay_token+i*2,3,"%02x",random[i]);
        memset(random,0,sizeof random);result=nvs_set_blob(store,"credentials",&candidate,sizeof candidate);
        if(result==ESP_OK)result=nvs_commit(store);
        length=sizeof candidate;
    }
    nvs_close(store);
    if(result!=ESP_OK){memset(&candidate,0,sizeof candidate);return result;}
    char expected_ssid[33];snprintf(expected_ssid,sizeof expected_ssid,"Suiban-v1-%.6s",device_id+6);
    if(length!=sizeof candidate||candidate.version!=1||strnlen(candidate.ssid,sizeof candidate.ssid)!=strlen(expected_ssid)||strcmp(candidate.ssid,expected_ssid)||
       !hex_string(candidate.passphrase,32,sizeof candidate.passphrase)||!hex_string(candidate.relay_token,64,sizeof candidate.relay_token)) {
        memset(&candidate,0,sizeof candidate);return ESP_ERR_INVALID_STATE;
    }
    credentials=candidate;credentials_ready=true;memset(&candidate,0,sizeof candidate);return ESP_OK;
}
static void no_default_route(void *unused) { (void)unused;netif_set_default(NULL); }
static void revoke_peer(void) { atomic_store(&peer_ready,false);atomic_fetch_add(&link_epoch,1); }
/* A committed router configuration reservation prevents any relay during pool changes. */
static esp_err_t configure_ap_pool(uint32_t host_address,bool running) {
    if(running&&atomic_load(&ap_address)==htonl(host_address))return ESP_OK;
    atomic_store(&access_point_ready,false);revoke_peer();
    if(running)(void)esp_wifi_deauth_sta(0);
    esp_err_t result=esp_netif_dhcps_stop(access_point);
    if(result!=ESP_OK&&result!=ESP_ERR_ESP_NETIF_DHCP_ALREADY_STOPPED)return result;
    esp_netif_ip_info_t addresses={.ip.addr=htonl(host_address),.netmask.addr=htonl(0xffffff00)};
    result=esp_netif_set_ip_info(access_point,&addresses);if(result!=ESP_OK)return result;
    dhcps_lease_t lease={.enable=true,.start_ip.addr=htonl(host_address+1),.end_ip.addr=htonl(host_address+2)};
    result=esp_netif_dhcps_option(access_point,ESP_NETIF_OP_SET,ESP_NETIF_REQUESTED_IP_ADDRESS,&lease,sizeof lease);if(result!=ESP_OK)return result;
    atomic_store(&ap_address,addresses.ip.addr);atomic_store(&ap_peer,lease.start_ip.addr);
    if(running) {
        result=esp_netif_dhcps_start(access_point);
        if(result==ESP_OK)atomic_store(&access_point_ready,true);
    }
    return result;
}
static void network_event(void *unused,esp_event_base_t base,int32_t event,void *data) {
    (void)unused;
    if(base==WIFI_EVENT) {
        if(event==WIFI_EVENT_AP_START) {
            int index=esp_netif_get_netif_impl_index(access_point);
            atomic_store(&interface_index,index>0?(uint32_t)index:0);atomic_store(&access_point_ready,index>0);
            (void)esp_netif_create_ip6_linklocal(access_point);(void)tcpip_callback(no_default_route,NULL);
            ESP_LOGI(TAG,"local access point started; no router/DNS/NAT; credentials omitted");
        } else if(event==WIFI_EVENT_AP_STOP) {
            station_associated=false;revoke_peer();atomic_store(&access_point_ready,false);atomic_store(&interface_index,0);
        } else if(event==WIFI_EVENT_AP_STACONNECTED) {
            wifi_event_ap_staconnected_t *joined=data;memcpy(station_mac,joined->mac,sizeof station_mac);station_associated=true;revoke_peer();
            /* SDK stop frees every lease; start resets allocation to .2.
             * The public pool setter requires start < end, hence .2-.3. */
            esp_err_t result=esp_netif_dhcps_stop(access_point);
            if(result==ESP_OK||result==ESP_ERR_ESP_NETIF_DHCP_ALREADY_STOPPED)result=esp_netif_dhcps_start(access_point);
            if(result!=ESP_OK){ESP_LOGW(TAG,"DHCP restart failed: %s",esp_err_to_name(result));(void)esp_wifi_deauth_sta(joined->aid);}
        } else if(event==WIFI_EVENT_AP_STADISCONNECTED){station_associated=false;revoke_peer();}
        else if(event==WIFI_EVENT_STA_START) {
            int index=esp_netif_get_netif_impl_index(station);atomic_store(&router_index,index>0?(uint32_t)index:0);
        } else if(event==WIFI_EVENT_STA_DISCONNECTED||event==WIFI_EVENT_STA_STOP) {
            xSemaphoreTake(router_lock,portMAX_DELAY);
            if(event==WIFI_EVENT_STA_STOP)atomic_store(&router_index,0);
            wifi_event_sta_disconnected_t *left=event==WIFI_EVENT_STA_DISCONNECTED?data:NULL;
            bool deliberate=left&&left->reason==WIFI_REASON_ASSOC_LEAVE&&router_requested_disconnect;
            if(deliberate)router_requested_disconnect=false;
            bool matches=!left||(left->ssid_len==strlen(pending_router.ssid)&&!memcmp(left->ssid,pending_router.ssid,left->ssid_len));
            if(matches&&!deliberate&&(router_phase==ROUTER_READY||router_attempt_active)) {
                bool was_ready=router_phase==ROUTER_READY;char error[32];snprintf(error,sizeof error,"wifi_%u",left?(unsigned)left->reason:0);
                router_failed(error);if(was_ready&&saved_router_ready)reconnect_saved=true;
                if(router_attempt_active&&router_task)xTaskNotifyGive(router_task);
            }
            xSemaphoreGive(router_lock);
        }
    } else if(base==IP_EVENT&&event==IP_EVENT_AP_STAIPASSIGNED) {
        ip_event_ap_staipassigned_t *assigned=data;
        if(assigned->esp_netif!=access_point||!station_associated||memcmp(assigned->mac,station_mac,sizeof station_mac))return;
        if(assigned->ip.addr==atomic_load(&ap_peer))atomic_store(&peer_ready,true);
        else {revoke_peer();ESP_LOGW(TAG,"unexpected DHCP address rejected; reconnect the phone");(void)esp_wifi_deauth_sta(0);}
    } else if(base==IP_EVENT&&event==IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *assigned=data;if(assigned->esp_netif!=station)return;
        wifi_ap_record_t joined={0};if(esp_wifi_sta_get_ap_info(&joined)!=ESP_OK)return;
        xSemaphoreTake(router_lock,portMAX_DELAY);
        if(strcmp((const char *)joined.ssid,pending_router.ssid)){xSemaphoreGive(router_lock);return;}
        router_requested_disconnect=false;
        if(ntohl(assigned->ip_info.ip.addr)==0xc0a80701)router_failed("usb_address_conflict");
        else if(!router_network_valid(&assigned->ip_info))router_failed("network_unsupported");
        else if(router_attempt_active) {
            router_address=assigned->ip_info.ip.addr;router_netmask=assigned->ip_info.netmask.addr;router_got_ip=true;
        } else if(router_phase==ROUTER_READY) {
            if(selected_ap_pool(assigned->ip_info.ip.addr,assigned->ip_info.netmask.addr)!=ntohl(atomic_load(&ap_address))) {
                router_failed("network_changed");reconnect_saved=saved_router_ready;
            } else if(router_address!=assigned->ip_info.ip.addr||router_netmask!=assigned->ip_info.netmask.addr) {
                router_revoke();router_address=assigned->ip_info.ip.addr;router_netmask=assigned->ip_info.netmask.addr;atomic_store(&router_ready,true);
            }
        }
        if(router_attempt_active&&router_task)xTaskNotifyGive(router_task);
        xSemaphoreGive(router_lock);(void)tcpip_callback(no_default_route,NULL);
    } else if(base==IP_EVENT&&event==IP_EVENT_STA_LOST_IP) {
        xSemaphoreTake(router_lock,portMAX_DELAY);bool was_ready=router_phase==ROUTER_READY;router_failed("lost_ip");
        if(was_ready&&saved_router_ready)reconnect_saved=true;
        if(router_attempt_active&&router_task)xTaskNotifyGive(router_task);
        xSemaphoreGive(router_lock);
    }
}
static void router_worker(void *unused) {
    (void)unused;router_credentials candidate={0};
    for(;;) {
        if(xQueueReceive(router_queue,&candidate,pdMS_TO_TICKS(5000))!=pdTRUE) {
            xSemaphoreTake(router_lock,portMAX_DELAY);
            bool retry=reconnect_saved&&saved_router_ready;router_credentials previous=saved_router;
            xSemaphoreGive(router_lock);
            if(!retry||!developer_service_reserve_wifi_configuration()){memset(&previous,0,sizeof previous);continue;}
            candidate=previous;memset(&previous,0,sizeof previous);
        }
        (void)ulTaskNotifyTake(pdTRUE,0);
        wifi_ap_record_t current={0};bool was_connected=esp_wifi_sta_get_ap_info(&current)==ESP_OK;
        xSemaphoreTake(router_lock,portMAX_DELAY);pending_router=candidate;router_attempt_active=true;router_got_ip=false;reconnect_saved=false;router_requested_disconnect=was_connected;
        router_phase=ROUTER_CONNECTING;router_error[0]=0;router_address=router_netmask=0;router_revoke();xSemaphoreGive(router_lock);
        esp_err_t disconnected=esp_wifi_disconnect();
        if(disconnected!=ESP_OK){xSemaphoreTake(router_lock,portMAX_DELAY);router_requested_disconnect=false;xSemaphoreGive(router_lock);}
        wifi_config_t configuration={0};memcpy(configuration.sta.ssid,candidate.ssid,strlen(candidate.ssid));
        memcpy(configuration.sta.password,candidate.passphrase,strlen(candidate.passphrase));
        configuration.sta.scan_method=WIFI_ALL_CHANNEL_SCAN;
        configuration.sta.threshold.authmode=candidate.passphrase[0]?WIFI_AUTH_WPA2_PSK:WIFI_AUTH_OPEN;
        configuration.sta.pmf_cfg.capable=true;configuration.sta.pmf_cfg.required=false;
        esp_err_t result=esp_wifi_set_config(WIFI_IF_STA,&configuration);memset(configuration.sta.password,0,sizeof configuration.sta.password);
        if(result==ESP_OK)result=esp_wifi_connect();
        uint32_t notified=result==ESP_OK?ulTaskNotifyTake(pdTRUE,pdMS_TO_TICKS(20000)):0;
        xSemaphoreTake(router_lock,portMAX_DELAY);bool connected=result==ESP_OK&&notified&&router_got_ip;
        if(connected){candidate.address=router_address;candidate.netmask=router_netmask;}
        else if(router_phase==ROUTER_CONNECTING)router_failed(result==ESP_OK?"connect_timeout":"connect_failed");
        xSemaphoreGive(router_lock);
        if(connected) {
            xSemaphoreTake(credentials_lock,portMAX_DELAY);result=configure_ap_pool(selected_ap_pool(candidate.address,candidate.netmask),true);xSemaphoreGive(credentials_lock);
            xSemaphoreTake(router_lock,portMAX_DELAY);
            /* Commit only a validated live attempt. Event serialization keeps
             * a post-commit disconnect distinct from a failed configuration. */
            if(result==ESP_OK&&router_got_ip)result=router_store(&candidate,true);
            if(result==ESP_OK&&router_got_ip) {
                saved_router=candidate;saved_router_ready=true;router_phase=ROUTER_READY;router_error[0]=0;atomic_fetch_add(&router_epoch,1);atomic_store(&router_ready,true);
            } else {router_failed(result==ESP_OK?"connection_lost":"storage_or_ap_failed");connected=false;}
            xSemaphoreGive(router_lock);
        }
        xSemaphoreTake(router_lock,portMAX_DELAY);router_attempt_active=false;xSemaphoreGive(router_lock);
        if(!connected)(void)esp_wifi_disconnect();
        developer_service_release_wifi_configuration();memset(&candidate,0,sizeof candidate);
    }
}
static esp_err_t start_access_point(void) {
    esp_err_t result=esp_event_loop_create_default();if(result!=ESP_OK&&result!=ESP_ERR_INVALID_STATE)return result;
    wifi_init_config_t initialization=WIFI_INIT_CONFIG_DEFAULT();result=esp_wifi_init(&initialization);if(result!=ESP_OK)return result;
    access_point=esp_netif_create_default_wifi_ap();station=esp_netif_create_default_wifi_sta();
    if(!access_point||!station){result=ESP_ERR_NO_MEM;goto failed;}
    bool wifi_registered=false,ip_registered=false;
    result=configure_ap_pool(saved_router_ready?selected_ap_pool(saved_router.address,saved_router.netmask):0xc0a80801,false);if(result!=ESP_OK)goto registered_failed;
    uint8_t no_offer=0;
    result=esp_netif_dhcps_option(access_point,ESP_NETIF_OP_SET,ESP_NETIF_ROUTER_SOLICITATION_ADDRESS,&no_offer,sizeof no_offer);if(result!=ESP_OK)goto registered_failed;
    result=esp_netif_dhcps_option(access_point,ESP_NETIF_OP_SET,ESP_NETIF_DOMAIN_NAME_SERVER,&no_offer,sizeof no_offer);if(result!=ESP_OK)goto registered_failed;
    result=esp_wifi_set_storage(WIFI_STORAGE_RAM);if(result!=ESP_OK)goto registered_failed;
    result=esp_wifi_set_mode(WIFI_MODE_APSTA);if(result!=ESP_OK)goto registered_failed;
    wifi_config_t configuration={0};memcpy(configuration.ap.ssid,credentials.ssid,strlen(credentials.ssid));
    configuration.ap.ssid_len=(uint8_t)strlen(credentials.ssid);memcpy(configuration.ap.password,credentials.passphrase,strlen(credentials.passphrase));
    configuration.ap.channel=6;configuration.ap.max_connection=1;configuration.ap.authmode=WIFI_AUTH_WPA2_PSK;
    configuration.ap.pmf_cfg.capable=true;configuration.ap.pmf_cfg.required=false;
    result=esp_wifi_set_config(WIFI_IF_AP,&configuration);memset(configuration.ap.password,0,sizeof configuration.ap.password);if(result!=ESP_OK)goto registered_failed;
    result=esp_event_handler_instance_register(WIFI_EVENT,ESP_EVENT_ANY_ID,network_event,NULL,&wifi_handler);if(result!=ESP_OK)goto registered_failed;wifi_registered=true;
    result=esp_event_handler_instance_register(IP_EVENT,ESP_EVENT_ANY_ID,network_event,NULL,&ip_handler);if(result!=ESP_OK)goto registered_failed;ip_registered=true;
    result=esp_wifi_start();if(result==ESP_OK)return ESP_OK;
registered_failed:
    if(ip_registered)(void)esp_event_handler_instance_unregister(IP_EVENT,ESP_EVENT_ANY_ID,ip_handler);
    if(wifi_registered)(void)esp_event_handler_instance_unregister(WIFI_EVENT,ESP_EVENT_ANY_ID,wifi_handler);
failed:
    if(access_point)esp_netif_destroy_default_wifi(access_point);
    if(station)esp_netif_destroy_default_wifi(station);
    access_point=station=NULL;(void)esp_wifi_deinit();return result;
}
esp_err_t wifi_board_start(void) {
    esp_err_t result=nvs_flash_init();if(result!=ESP_OK)return result;
    uint8_t mac[6];result=esp_read_mac(mac,ESP_MAC_WIFI_STA);if(result!=ESP_OK)return result;
    snprintf(device_id,sizeof device_id,"%02x%02x%02x%02x%02x%02x",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    credentials_lock=xSemaphoreCreateMutex();router_lock=xSemaphoreCreateMutex();router_queue=xQueueCreate(1,sizeof(router_credentials));
    if(!credentials_lock||!router_lock||!router_queue)return ESP_ERR_NO_MEM;
    result=load_credentials();if(result!=ESP_OK)return result;
    result=router_store(&saved_router,false);saved_router_ready=result==ESP_OK;
    if(result!=ESP_OK&&result!=ESP_ERR_NVS_NOT_FOUND){router_failed("saved_configuration_invalid");memset(&saved_router,0,sizeof saved_router);}
    result=start_access_point();if(result!=ESP_OK)return result;
    if(xTaskCreate(router_worker,"suiban_router",6144,NULL,4,&router_task)!=pdPASS)return ESP_ERR_NO_MEM;
    if(saved_router_ready) {
        if(developer_service_reserve_wifi_configuration()) {
            if(xQueueSend(router_queue,&saved_router,0)!=pdTRUE)developer_service_release_wifi_configuration();
        } else {xSemaphoreTake(router_lock,portMAX_DELAY);reconnect_saved=true;xSemaphoreGive(router_lock);}
    }
    return ESP_OK;
}
bool wifi_board_online(void) { return atomic_load(&access_point_ready)&&atomic_load(&peer_ready); }
uint32_t wifi_board_epoch(void) { return atomic_load(&link_epoch); }
uint32_t wifi_board_network_index(void) { return atomic_load(&interface_index); }
bool wifi_board_ap_link(uint8_t address[4],uint8_t peer[4],uint32_t *index,uint32_t *epoch) {
    if(!credentials_lock)return false;
    xSemaphoreTake(credentials_lock,portMAX_DELAY);
    uint32_t local=atomic_load(&ap_address),remote=atomic_load(&ap_peer);memcpy(address,&local,4);memcpy(peer,&remote,4);
    *index=atomic_load(&interface_index);*epoch=wifi_board_epoch();bool ready=wifi_board_online();xSemaphoreGive(credentials_lock);return ready;
}
bool wifi_board_authorize(const char *token) {
    if(!credentials_lock||!token||strnlen(token,65)!=64)return false;
    xSemaphoreTake(credentials_lock,portMAX_DELAY);uint8_t difference=0;
    for(size_t i=0;i<64;i++)difference|=(uint8_t)(token[i]^credentials.relay_token[i]);
    bool accepted=credentials_ready&&difference==0;xSemaphoreGive(credentials_lock);return accepted;
}
esp_err_t wifi_board_information(char *output,size_t capacity) {
    if(!credentials_lock||!output||capacity<1||!atomic_load(&access_point_ready))return ESP_ERR_INVALID_STATE;
    xSemaphoreTake(credentials_lock,portMAX_DELAY);char local[16],board[16];
    ip4_string(atomic_load(&ap_peer),local);ip4_string(atomic_load(&ap_address),board);
    int length=credentials_ready?snprintf(output,capacity,"{\"version\":1,\"id\":\"%s\",\"ssid\":\"%s\",\"passphrase\":\"%s\",\"relay_token\":\"%s\",\"local_ip\":\"%s\",\"board_ip\":\"%s\",\"netmask\":\"255.255.255.0\"}",device_id,credentials.ssid,credentials.passphrase,credentials.relay_token,local,board):-1;
    xSemaphoreGive(credentials_lock);return length<0||(size_t)length>=capacity?ESP_ERR_INVALID_SIZE:ESP_OK;
}
bool wifi_board_router_online(void) { return atomic_load(&router_ready); }
uint32_t wifi_board_router_epoch(void) { return atomic_load(&router_epoch); }
bool wifi_board_router_link(uint8_t address[4],uint8_t mask[4],uint32_t *index,uint32_t *epoch) {
    if(!router_lock)return false;
    xSemaphoreTake(router_lock,portMAX_DELAY);bool ready=wifi_board_router_online();
    memcpy(address,&router_address,4);memcpy(mask,&router_netmask,4);*index=ready?atomic_load(&router_index):0;*epoch=wifi_board_router_epoch();
    xSemaphoreGive(router_lock);return ready;
}
esp_err_t wifi_board_router_information(char *output,size_t capacity) {
    if(!router_lock||!output||!capacity)return ESP_ERR_INVALID_STATE;
    char ssid[33],error[32],board[16]="",mask[16]="";enum router_phase phase;
    xSemaphoreTake(router_lock,portMAX_DELAY);phase=router_phase;memcpy(ssid,pending_router.ssid,sizeof ssid);memcpy(error,router_error,sizeof error);
    if(phase==ROUTER_READY) {
        ip4_string(router_address,board);ip4_string(router_netmask,mask);
    }
    xSemaphoreGive(router_lock);const char *states[]={"unconfigured","connecting","ready","failed"};
    cJSON *object=cJSON_CreateObject();if(!object)return ESP_ERR_NO_MEM;
    bool built=cJSON_AddNumberToObject(object,"version",1)&&cJSON_AddStringToObject(object,"id",device_id)&&
        cJSON_AddStringToObject(object,"ssid",ssid)&&cJSON_AddStringToObject(object,"state",states[phase])&&
        cJSON_AddStringToObject(object,"board_ip",board)&&cJSON_AddStringToObject(object,"netmask",mask)&&cJSON_AddStringToObject(object,"error",error);
    bool printed=built&&capacity<=INT32_MAX&&cJSON_PrintPreallocated(object,output,(int)capacity,false);cJSON_Delete(object);
    return printed?ESP_OK:ESP_ERR_INVALID_SIZE;
}
esp_err_t wifi_board_configure_router(const char *json,size_t length) {
    if(!json||!length||length>512||memchr(json,0,length))return ESP_ERR_INVALID_ARG;
    /* cJSON strings are NUL-terminated: reject a JSON escaped NUL before parsing. */
    for(size_t i=0;i<length;i++)if(json[i]=='\\') {
        if(i+5<length&&!memcmp(json+i,"\\u0000",6))return ESP_ERR_INVALID_ARG;
        if(i+1<length)i++;
    }
    char input[513];memcpy(input,json,length);input[length]=0;cJSON *object=cJSON_ParseWithLengthOpts(input,length+1,NULL,true);
    router_credentials candidate={.version=1};esp_err_t result=ESP_ERR_INVALID_ARG;
    if(object&&cJSON_IsObject(object)&&cJSON_GetArraySize(object)==4) {
        cJSON *version=cJSON_GetObjectItemCaseSensitive(object,"version"),*id=cJSON_GetObjectItemCaseSensitive(object,"id");
        cJSON *ssid=cJSON_GetObjectItemCaseSensitive(object,"ssid"),*pass=cJSON_GetObjectItemCaseSensitive(object,"passphrase");
        if(cJSON_IsNumber(version)&&version->valuedouble==1&&cJSON_IsString(id)&&!strcmp(id->valuestring,device_id)&&
           cJSON_IsString(ssid)&&cJSON_IsString(pass)&&strnlen(ssid->valuestring,33)<=32&&strnlen(pass->valuestring,64)<=63) {
            snprintf(candidate.ssid,sizeof candidate.ssid,"%s",ssid->valuestring);snprintf(candidate.passphrase,sizeof candidate.passphrase,"%s",pass->valuestring);
            if(router_valid(&candidate))result=ESP_OK;
        }
    }
    cJSON_Delete(object);memset(input,0,sizeof input);
    if(result==ESP_OK) {
        if(!router_task||!developer_service_reserve_wifi_configuration())result=ESP_ERR_INVALID_STATE;
        else {
            if(xSemaphoreTake(router_lock,0)!=pdTRUE)result=ESP_ERR_INVALID_STATE;
            else {
                pending_router=candidate;router_phase=ROUTER_CONNECTING;router_error[0]=0;
                result=xQueueSend(router_queue,&candidate,0)==pdTRUE?ESP_OK:ESP_ERR_INVALID_STATE;xSemaphoreGive(router_lock);
            }
            if(result!=ESP_OK)developer_service_release_wifi_configuration();
        }
    }
    memset(&candidate,0,sizeof candidate);return result;
}
