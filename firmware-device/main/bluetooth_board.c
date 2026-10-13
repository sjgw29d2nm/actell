/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bluetooth_board.h"
#include "usb_device.h"
#include "wifi_board.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "store/config/ble_store_config.h"
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

/* ESP-IDF 5.5's public bleprph example declares this store initializer
 * explicitly; the bundled store/config header does not declare it. */
void ble_store_config_init(void);

/* AD51B100-2A4B-4C6D-8E90-102030405060; UUID bytes are little endian. */
#define BOARD_UUID(last) BLE_UUID128_INIT(0x60,0x50,0x40,0x30,0x20,0x10,0x90,0x8e,0x6d,0x4c,0x4b,0x2a,last,0xb1,0x51,0xad)
static const ble_uuid128_t service_uuid=BOARD_UUID(0x00);
static const ble_uuid128_t information_uuid=BOARD_UUID(0x01);
static const ble_uuid128_t command_uuid=BOARD_UUID(0x02);
static const ble_uuid128_t response_uuid=BOARD_UUID(0x03);
static const ble_uuid128_t wifi_information_uuid=BOARD_UUID(0x04);
static const char *TAG="suiban_ble";
static uint8_t address_type;
static uint16_t response_handle;
static char device_id[13];
static char response[21]="SB1 READY";
static int gap_event(struct ble_gap_event *event,void *argument);
static portMUX_TYPE window_lock=portMUX_INITIALIZER_UNLOCKED;
static uint16_t connected_handle=BLE_HS_CONN_HANDLE_NONE,wifi_window_handle=BLE_HS_CONN_HANDLE_NONE;
static uint32_t connection_epoch=1,wifi_window_epoch;
static int64_t wifi_window_deadline;

void bluetooth_board_close_wifi_window(void) {
    taskENTER_CRITICAL(&window_lock);wifi_window_handle=BLE_HS_CONN_HANDLE_NONE;wifi_window_deadline=0;taskEXIT_CRITICAL(&window_lock);
}
bool bluetooth_board_open_wifi_window(void) {
    taskENTER_CRITICAL(&window_lock);uint16_t handle=connected_handle;uint32_t epoch=connection_epoch;taskEXIT_CRITICAL(&window_lock);
    struct ble_gap_conn_desc connection;
    if(handle==BLE_HS_CONN_HANDLE_NONE||ble_gap_conn_find(handle,&connection)||!connection.sec_state.encrypted||!connection.sec_state.bonded)return false;
    taskENTER_CRITICAL(&window_lock);
    bool valid=connected_handle==handle&&connection_epoch==epoch;
    if(valid){wifi_window_handle=handle;wifi_window_epoch=epoch;wifi_window_deadline=esp_timer_get_time()+60000000;}
    taskEXIT_CRITICAL(&window_lock);return valid;
}

static int access_characteristic(uint16_t connection,uint16_t attribute,
                                 struct ble_gatt_access_ctxt *context,void *argument) {
    (void)attribute;
    uintptr_t kind=(uintptr_t)argument;
    if(context->op==BLE_GATT_ACCESS_OP_READ_CHR&&kind==4) {
        taskENTER_CRITICAL(&window_lock);
        bool allowed=connection==wifi_window_handle&&wifi_window_epoch==connection_epoch&&esp_timer_get_time()<wifi_window_deadline;
        taskEXIT_CRITICAL(&window_lock);
        struct ble_gap_conn_desc security;
        if(!allowed||ble_gap_conn_find(connection,&security)||!security.sec_state.encrypted||!security.sec_state.bonded)return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
        char information[512];
        if(wifi_board_information(information,sizeof information)!=ESP_OK)return BLE_ATT_ERR_UNLIKELY;
        int result=os_mbuf_append(context->om,information,(uint16_t)strlen(information));
        memset(information,0,sizeof information);return result==0?0:BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (context->op==BLE_GATT_ACCESS_OP_READ_CHR && kind==1) {
        char information[256];
        int length=snprintf(information,sizeof information,
            "{\"version\":1,\"id\":\"%s\",\"name\":\"随办硬件v1\",\"chip\":\"esp32s3\","
            "\"usb_connected\":%s,\"uptime_ms\":%"PRId64",\"capabilities\":[\"status\",\"ping\",\"wifi_setup\"]}",
            device_id,usb_online()?"true":"false",esp_timer_get_time()/1000);
        if (length<0 || (size_t)length>=sizeof information) return BLE_ATT_ERR_UNLIKELY;
        return os_mbuf_append(context->om,information,(uint16_t)length)==0?0:BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (context->op==BLE_GATT_ACCESS_OP_READ_CHR && kind==3) {
        return os_mbuf_append(context->om,response,(uint16_t)strlen(response))==0?0:BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (context->op!=BLE_GATT_ACCESS_OP_WRITE_CHR || kind!=2) return BLE_ATT_ERR_UNLIKELY;
    uint16_t length=OS_MBUF_PKTLEN(context->om);
    char command[21];
    if (!length || length>=sizeof command || ble_hs_mbuf_to_flat(context->om,command,length,NULL)!=0) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    command[length]=0;
    /* One bounded diagnostic per write; never accepts phone input commands. */
    unsigned long long number=0;
    char trailing=0;
    if (sscanf(command,"SB1 PING %llu%c",&number,&trailing)!=1 || number==0 || number>UINT32_MAX) return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    snprintf(response,sizeof response,"SB1 OK %"PRIu32,(uint32_t)number);
    int result=ble_gatts_notify(connection,response_handle);
    if (result!=0) ESP_LOGW(TAG,"response notification failed: %d",result);
    return 0;
}

static const struct ble_gatt_svc_def services[]={
    {.type=BLE_GATT_SVC_TYPE_PRIMARY,.uuid=&service_uuid.u,
     .characteristics=(struct ble_gatt_chr_def[]){
         {.uuid=&information_uuid.u,.access_cb=access_characteristic,.arg=(void *)1,.flags=BLE_GATT_CHR_F_READ},
         {.uuid=&command_uuid.u,.access_cb=access_characteristic,.arg=(void *)2,.flags=BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_ENC},
         {.uuid=&response_uuid.u,.access_cb=access_characteristic,.arg=(void *)3,.val_handle=&response_handle,.flags=BLE_GATT_CHR_F_READ|BLE_GATT_CHR_F_NOTIFY|BLE_GATT_CHR_F_READ_ENC},
         {.uuid=&wifi_information_uuid.u,.access_cb=access_characteristic,.arg=(void *)4,.flags=BLE_GATT_CHR_F_READ|BLE_GATT_CHR_F_READ_ENC},
         {0}}},
    {0}
};

static void advertise(void) {
    struct ble_hs_adv_fields fields={0};
    fields.flags=BLE_HS_ADV_F_DISC_GEN|BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128=(ble_uuid128_t *)&service_uuid;
    fields.num_uuids128=1;
    fields.uuids128_is_complete=1;
    int result=ble_gap_adv_set_fields(&fields);
    if (result!=0) { ESP_LOGE(TAG,"advertising data failed: %d",result);return; }
    struct ble_hs_adv_fields scan_response={0};
    const char *name=ble_svc_gap_device_name();
    scan_response.name=(const uint8_t *)name;
    scan_response.name_len=(uint8_t)strlen(name);
    scan_response.name_is_complete=1;
    result=ble_gap_adv_rsp_set_fields(&scan_response);
    if (result!=0) { ESP_LOGE(TAG,"scan response failed: %d",result);return; }
    struct ble_gap_adv_params parameters={0};
    parameters.conn_mode=BLE_GAP_CONN_MODE_UND;
    parameters.disc_mode=BLE_GAP_DISC_MODE_GEN;
    result=ble_gap_adv_start(address_type,NULL,BLE_HS_FOREVER,&parameters,gap_event,NULL);
    if (result!=0) ESP_LOGE(TAG,"advertising start failed: %d",result);
    else ESP_LOGI(TAG,"advertising Suiban-v1; encrypted diagnostic service SB1");
}

static int gap_event(struct ble_gap_event *event,void *argument) {
    (void)argument;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        taskENTER_CRITICAL(&window_lock);++connection_epoch;connected_handle=event->connect.status==0?event->connect.conn_handle:BLE_HS_CONN_HANDLE_NONE;wifi_window_handle=BLE_HS_CONN_HANDLE_NONE;wifi_window_deadline=0;taskEXIT_CRITICAL(&window_lock);
        ESP_LOGI(TAG,"connection result=%d",event->connect.status);
        if (event->connect.status!=0) advertise();
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        taskENTER_CRITICAL(&window_lock);++connection_epoch;connected_handle=BLE_HS_CONN_HANDLE_NONE;wifi_window_handle=BLE_HS_CONN_HANDLE_NONE;wifi_window_deadline=0;taskEXIT_CRITICAL(&window_lock);
        snprintf(response,sizeof response,"SB1 READY");
        ESP_LOGI(TAG,"disconnected reason=%d",event->disconnect.reason);
        advertise();
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE: advertise();break;
    case BLE_GAP_EVENT_ENC_CHANGE: ESP_LOGI(TAG,"encryption result=%d",event->enc_change.status);break;
    case BLE_GAP_EVENT_REPEAT_PAIRING:
        /* Preserve existing bonds; re-pairing never silently deletes a key. */
        return BLE_GAP_REPEAT_PAIRING_IGNORE;
    default: break;
    }
    return 0;
}

static void host_reset(int reason) {
    taskENTER_CRITICAL(&window_lock);++connection_epoch;connected_handle=BLE_HS_CONN_HANDLE_NONE;wifi_window_handle=BLE_HS_CONN_HANDLE_NONE;wifi_window_deadline=0;taskEXIT_CRITICAL(&window_lock);
    ESP_LOGE(TAG,"host reset reason=%d",reason);
}
static void host_sync(void) {
    int result=ble_hs_util_ensure_addr(0);
    if (result==0) result=ble_hs_id_infer_auto(0,&address_type);
    if (result!=0) { ESP_LOGE(TAG,"identity setup failed: %d",result);return; }
    /* The built-in GATT service retains Service Changed indications for
     * disconnected bonded peers, refreshing iOS's cache after firmware upgrade. */
    ble_svc_gatt_changed(1,UINT16_MAX);
    advertise();
}
static void host_task(void *argument) {
    (void)argument;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t bluetooth_board_start(void) {
    /* PHY calibration and BLE bonds use NVS. Existing contents are never erased. */
    esp_err_t result=nvs_flash_init();
    if (result!=ESP_OK) return result;
    uint8_t mac[6];
    result=esp_read_mac(mac,ESP_MAC_WIFI_STA);
    if (result!=ESP_OK) return result;
    snprintf(device_id,sizeof device_id,"%02x%02x%02x%02x%02x%02x",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    result=nimble_port_init();
    if (result!=ESP_OK) return result;
    ble_hs_cfg.reset_cb=host_reset;
    ble_hs_cfg.sync_cb=host_sync;
    /* The demo's round-robin callback deletes the oldest bond on overflow.
     * Refuse new storage instead, preserving existing paired devices. */
    ble_hs_cfg.store_status_cb=NULL;
    ble_hs_cfg.sm_io_cap=BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding=1;
    ble_hs_cfg.sm_sc=1;
    ble_hs_cfg.sm_our_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    int code=ble_gatts_count_cfg(services);
    if (code==0) code=ble_gatts_add_svcs(services);
    if (code==0) code=ble_svc_gap_device_name_set("Suiban-v1");
    if (code!=0) { nimble_port_deinit();return ESP_FAIL; }
    ble_store_config_init();
    nimble_port_freertos_init(host_task);
    return ESP_OK;
}
