/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "wifi_board.h"
#include "bluetooth_board.h"
#include "driver/gpio.h"
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
#include "freertos/task.h"
#include "lwip/netif.h"
#include "lwip/tcpip.h"
#include "apps/dhcpserver/dhcpserver.h"
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static const char *TAG="suiban_wifi";
typedef struct { uint32_t version; char ssid[33],passphrase[65],relay_token[65]; } wifi_credentials;
static wifi_credentials credentials;
static char device_id[13];
static bool credentials_ready;
static SemaphoreHandle_t credentials_lock;
static esp_netif_t *access_point;
static atomic_bool access_point_ready,peer_ready;
static atomic_uint_least32_t link_epoch=1,interface_index;
static esp_event_handler_instance_t wifi_handler,ip_handler;
/* Only the serialized default event loop reads or writes this station identity. */
static bool station_associated;
static uint8_t station_mac[6];

static bool hex_string(const char *value,size_t length,size_t capacity) {
    if(strnlen(value,capacity)!=length)return false;
    for(size_t i=0;i<length;i++)if(!((value[i]>='0'&&value[i]<='9')||(value[i]>='a'&&value[i]<='f')))return false;
    return true;
}
static esp_err_t load_credentials(bool create) {
    nvs_handle_t store;
    esp_err_t result=nvs_open("suiban_wifi",create?NVS_READWRITE:NVS_READONLY,&store);
    if(result!=ESP_OK)return result;
    wifi_credentials candidate={0};size_t length=sizeof candidate;
    result=nvs_get_blob(store,"credentials",&candidate,&length);
    if(result==ESP_ERR_NVS_NOT_FOUND&&create) {
        candidate.version=1;
        snprintf(candidate.ssid,sizeof candidate.ssid,"Suiban-v1-%.6s",device_id+6);
        uint8_t random[32];esp_fill_random(random,sizeof random);
        for(size_t i=0;i<16;i++)snprintf(candidate.passphrase+i*2,3,"%02x",random[i]);
        esp_fill_random(random,sizeof random);
        for(size_t i=0;i<sizeof random;i++)snprintf(candidate.relay_token+i*2,3,"%02x",random[i]);
        memset(random,0,sizeof random);
        result=nvs_set_blob(store,"credentials",&candidate,sizeof candidate);
        if(result==ESP_OK)result=nvs_commit(store);
        length=sizeof candidate;
    }
    nvs_close(store);
    if(result!=ESP_OK){memset(&candidate,0,sizeof candidate);return result;}
    char expected_ssid[33];snprintf(expected_ssid,sizeof expected_ssid,"Suiban-v1-%.6s",device_id+6);
    if(length!=sizeof candidate||candidate.version!=1||
       strnlen(candidate.ssid,sizeof candidate.ssid)!=strlen(expected_ssid)||strcmp(candidate.ssid,expected_ssid)||
       !hex_string(candidate.passphrase,32,sizeof candidate.passphrase)||!hex_string(candidate.relay_token,64,sizeof candidate.relay_token)) {
        memset(&candidate,0,sizeof candidate);return ESP_ERR_INVALID_STATE;
    }
    credentials=candidate;credentials_ready=true;memset(&candidate,0,sizeof candidate);return ESP_OK;
}
static void no_default_route(void *unused) { (void)unused;netif_set_default(NULL); }
static void revoke_peer(void) { atomic_store(&peer_ready,false);atomic_fetch_add(&link_epoch,1); }
static void network_event(void *unused,esp_event_base_t base,int32_t event,void *data) {
    (void)unused;
    if(base==WIFI_EVENT) {
        if(event==WIFI_EVENT_AP_START) {
            int index=esp_netif_get_netif_impl_index(access_point);
            atomic_store(&interface_index,index>0?(uint32_t)index:0);
            atomic_store(&access_point_ready,index>0);
            (void)esp_netif_create_ip6_linklocal(access_point);
            (void)tcpip_callback(no_default_route,NULL);
            ESP_LOGI(TAG,"local access point started; no router/DNS/NAT; credentials omitted");
        } else if(event==WIFI_EVENT_AP_STOP) {
            station_associated=false;revoke_peer();atomic_store(&access_point_ready,false);atomic_store(&interface_index,0);
        } else if(event==WIFI_EVENT_AP_STACONNECTED) {
            wifi_event_ap_staconnected_t *station=data;
            memcpy(station_mac,station->mac,sizeof station_mac);station_associated=true;
            revoke_peer();
            /* SDK stop frees every lease; start resets allocation to .2.
             * The public pool setter requires start < end, hence .2-.3. */
            esp_err_t result=esp_netif_dhcps_stop(access_point);
            if(result==ESP_OK||result==ESP_ERR_ESP_NETIF_DHCP_ALREADY_STOPPED)result=esp_netif_dhcps_start(access_point);
            if(result!=ESP_OK) {
                ESP_LOGW(TAG,"DHCP restart failed: %s",esp_err_to_name(result));
                (void)esp_wifi_deauth_sta(station->aid);
            }
        } else if(event==WIFI_EVENT_AP_STADISCONNECTED){station_associated=false;revoke_peer();}
    } else if(base==IP_EVENT&&event==IP_EVENT_AP_STAIPASSIGNED) {
        ip_event_ap_staipassigned_t *assigned=data;esp_ip4_addr_t expected;
        if(assigned->esp_netif!=access_point||!station_associated||memcmp(assigned->mac,station_mac,sizeof station_mac))return;
        IP4_ADDR(&expected,192,168,8,2);
        if(assigned->ip.addr==expected.addr)atomic_store(&peer_ready,true);
        else {
            revoke_peer();ESP_LOGW(TAG,"unexpected DHCP address rejected; reconnect the phone");
            (void)esp_wifi_deauth_sta(0);
        }
    }
}
/* Called with credentials_lock held; failures preserve the committed blob. */
static esp_err_t start_access_point(void) {
    if(access_point)return ESP_OK;
    esp_err_t result=esp_event_loop_create_default();
    if(result!=ESP_OK&&result!=ESP_ERR_INVALID_STATE)return result;
    wifi_init_config_t initialization=WIFI_INIT_CONFIG_DEFAULT();
    result=esp_wifi_init(&initialization);if(result!=ESP_OK)return result;
    access_point=esp_netif_create_default_wifi_ap();
    if(!access_point){(void)esp_wifi_deinit();return ESP_ERR_NO_MEM;}
    bool wifi_registered=false,ip_registered=false;
    result=esp_netif_dhcps_stop(access_point);
    if(result!=ESP_OK&&result!=ESP_ERR_ESP_NETIF_DHCP_ALREADY_STOPPED)goto failed;
    esp_netif_ip_info_t addresses={0};IP4_ADDR(&addresses.ip,192,168,8,1);IP4_ADDR(&addresses.netmask,255,255,255,0);
    result=esp_netif_set_ip_info(access_point,&addresses);if(result!=ESP_OK)goto failed;
    dhcps_lease_t lease={.enable=true};IP4_ADDR(&lease.start_ip,192,168,8,2);IP4_ADDR(&lease.end_ip,192,168,8,3);
    result=esp_netif_dhcps_option(access_point,ESP_NETIF_OP_SET,ESP_NETIF_REQUESTED_IP_ADDRESS,&lease,sizeof lease);if(result!=ESP_OK)goto failed;
    uint8_t no_offer=0;
    result=esp_netif_dhcps_option(access_point,ESP_NETIF_OP_SET,ESP_NETIF_ROUTER_SOLICITATION_ADDRESS,&no_offer,sizeof no_offer);if(result!=ESP_OK)goto failed;
    result=esp_netif_dhcps_option(access_point,ESP_NETIF_OP_SET,ESP_NETIF_DOMAIN_NAME_SERVER,&no_offer,sizeof no_offer);if(result!=ESP_OK)goto failed;
    result=esp_wifi_set_storage(WIFI_STORAGE_RAM);if(result!=ESP_OK)goto failed;
    result=esp_wifi_set_mode(WIFI_MODE_AP);if(result!=ESP_OK)goto failed;
    wifi_config_t configuration={0};
    memcpy(configuration.ap.ssid,credentials.ssid,strlen(credentials.ssid));
    configuration.ap.ssid_len=(uint8_t)strlen(credentials.ssid);
    memcpy(configuration.ap.password,credentials.passphrase,strlen(credentials.passphrase));
    configuration.ap.channel=6;configuration.ap.max_connection=1;configuration.ap.authmode=WIFI_AUTH_WPA2_PSK;
    configuration.ap.pmf_cfg.capable=true;configuration.ap.pmf_cfg.required=false;
    result=esp_wifi_set_config(WIFI_IF_AP,&configuration);memset(configuration.ap.password,0,sizeof configuration.ap.password);
    if(result!=ESP_OK)goto failed;
    result=esp_event_handler_instance_register(WIFI_EVENT,ESP_EVENT_ANY_ID,network_event,NULL,&wifi_handler);if(result!=ESP_OK)goto failed;
    wifi_registered=true;
    result=esp_event_handler_instance_register(IP_EVENT,IP_EVENT_AP_STAIPASSIGNED,network_event,NULL,&ip_handler);if(result!=ESP_OK)goto failed;
    ip_registered=true;
    result=esp_wifi_start();if(result==ESP_OK)return ESP_OK;
failed:
    if(ip_registered)(void)esp_event_handler_instance_unregister(IP_EVENT,IP_EVENT_AP_STAIPASSIGNED,ip_handler);
    if(wifi_registered)(void)esp_event_handler_instance_unregister(WIFI_EVENT,ESP_EVENT_ANY_ID,wifi_handler);
    esp_netif_destroy_default_wifi(access_point);access_point=NULL;(void)esp_wifi_deinit();return result;
}
static void setup_button_task(void *unused) {
    (void)unused;bool pressed=gpio_get_level(GPIO_NUM_0)==0;
    for(;;) {
        bool now_pressed=gpio_get_level(GPIO_NUM_0)==0;
        if(now_pressed&&!pressed&&bluetooth_board_open_wifi_window()) {
            xSemaphoreTake(credentials_lock,portMAX_DELAY);
            esp_err_t result=credentials_ready?ESP_OK:load_credentials(true);
            if(result==ESP_OK)result=start_access_point();
            xSemaphoreGive(credentials_lock);
            if(result!=ESP_OK){bluetooth_board_close_wifi_window();ESP_LOGW(TAG,"physical Wi-Fi setup failed: %s; NVS preserved",esp_err_to_name(result));}
            else ESP_LOGI(TAG,"Wi-Fi setup authorized for the current bonded BLE connection for 60 seconds");
        }
        pressed=now_pressed;vTaskDelay(pdMS_TO_TICKS(50));
    }
}
esp_err_t wifi_board_start(void) {
    esp_err_t result=nvs_flash_init();if(result!=ESP_OK)return result;
    uint8_t mac[6];result=esp_read_mac(mac,ESP_MAC_WIFI_STA);if(result!=ESP_OK)return result;
    snprintf(device_id,sizeof device_id,"%02x%02x%02x%02x%02x%02x",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    credentials_lock=xSemaphoreCreateMutex();if(!credentials_lock)return ESP_ERR_NO_MEM;
    gpio_config_t button={.pin_bit_mask=1ULL<<GPIO_NUM_0,.mode=GPIO_MODE_INPUT,.pull_up_en=GPIO_PULLUP_ENABLE,.pull_down_en=GPIO_PULLDOWN_DISABLE,.intr_type=GPIO_INTR_DISABLE};
    result=gpio_config(&button);if(result!=ESP_OK)return result;
    result=load_credentials(false);
    if(result==ESP_OK)result=start_access_point();
    else if(result==ESP_ERR_NVS_NOT_FOUND)result=ESP_OK;
    if(xTaskCreate(setup_button_task,"wifi_setup",6144,NULL,4,NULL)!=pdPASS)return ESP_ERR_NO_MEM;
    return result;
}
bool wifi_board_online(void) { return atomic_load(&access_point_ready)&&atomic_load(&peer_ready); }
uint32_t wifi_board_epoch(void) { return atomic_load(&link_epoch); }
uint32_t wifi_board_network_index(void) { return atomic_load(&interface_index); }
bool wifi_board_authorize(const char *token) {
    if(!credentials_lock||!token||strnlen(token,65)!=64||!wifi_board_online())return false;
    xSemaphoreTake(credentials_lock,portMAX_DELAY);uint8_t difference=0;
    for(size_t i=0;i<64;i++)difference|=(uint8_t)(token[i]^credentials.relay_token[i]);
    bool accepted=credentials_ready&&difference==0;xSemaphoreGive(credentials_lock);return accepted;
}
esp_err_t wifi_board_information(char *output,size_t capacity) {
    if(!credentials_lock||!output||capacity<1||!atomic_load(&access_point_ready))return ESP_ERR_INVALID_STATE;
    xSemaphoreTake(credentials_lock,portMAX_DELAY);
    int length=credentials_ready?snprintf(output,capacity,"{\"version\":1,\"id\":\"%s\",\"ssid\":\"%s\",\"passphrase\":\"%s\",\"relay_token\":\"%s\",\"local_ip\":\"192.168.8.2\",\"board_ip\":\"192.168.8.1\"}",device_id,credentials.ssid,credentials.passphrase,credentials.relay_token):-1;
    xSemaphoreGive(credentials_lock);return length<0||(size_t)length>=capacity?ESP_ERR_INVALID_SIZE:ESP_OK;
}
