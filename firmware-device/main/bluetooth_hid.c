/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bluetooth_hid.h"
#include "developer_service.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_npl.h"
#include "host/ble_att.h"
#include "services/hid/ble_svc_hid.h"
#include "services/bas/ble_svc_bas.h"
#include "services/dis/ble_svc_dis.h"
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

#define BH_LINE_MAX 160
#define BH_HISTORY 32
#define BH_QUEUE 8
#define BH_LEASE_MS 750
#define BH_TX_MS 250
static const char zero_owner[]="00000000000000000000000000000000";
enum kind { BEGIN,PING,MOUSE,KEY,STOP };
enum phase { ACCEPTED,REPORTS_SENT,NEUTRAL_SENT,CANCELLED,UNKNOWN,REJECTED };
enum code { OK,FORMAT,SESSION,OWNER,BUSY,MTU,SUBSCRIPTIONS,STALE,CONFLICT,HISTORY_FULL,LEASE,STOPPED,DISCONNECT,SECURITY,NOTIFY,QUEUE_FULL,SUSPENDED };
enum mode { IDLE,ACTIVE,RELEASING };
typedef struct {
    char session[33],owner[33];uint32_t id;enum kind kind;
    int16_t dx,dy,wheel;uint8_t buttons,modifiers,keys[6];
} bh_command;
typedef struct { bool valid;bh_command command;enum phase phase;enum code code; } bh_receipt;
static bh_receipt history[BH_HISTORY];
static uint8_t queue[BH_QUEUE];
static size_t cursor,queue_head,queue_count;
static uint32_t highest;
static uint16_t connection=BLE_HS_CONN_HANDLE_NONE,keyboard_handle,mouse_handle;
uint16_t bluetooth_hid_ack_handle;
static char nonce[33],owner[33],last_owner[33];
static enum mode mode;
static enum code release_requested;
static bool gate_held,keyboard_subscribed,mouse_subscribed,ack_subscribed,suspended;
static uint64_t lease_until;
/* Exactly one report is outstanding. A STOP waits for its terminal TX event
 * before publishing all-up; it cannot confuse a late old TX with neutral TX. */
static uint16_t pending_handle;
static int pending_status=INT_MIN,pending_receipt=-1;
static uint64_t pending_until;
static unsigned neutral_stage;
static bool pending_neutral;
static struct ble_npl_callout timer;
static uint64_t now_ms(void) { return (uint64_t)esp_timer_get_time()/1000; }
static bool secured(void) {
    struct ble_gap_conn_desc security;
    return connection!=BLE_HS_CONN_HANDLE_NONE&&ble_gap_conn_find(connection,&security)==0&&security.sec_state.encrypted&&security.sec_state.bonded;
}
static bool hex_token(const char **input,char output[33]) {
    if(strlen(*input)<33)return false;
    for(size_t i=0;i<32;i++) {
        char c=(*input)[i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return false;output[i]=c;
    }
    output[32]=0;*input+=32;if(**input!=' ')return false;(*input)++;return true;
}
static bool number(const char **input,int32_t *value,bool negative) {
    const char *p=*input;bool minus=negative&&*p=='-';if(minus)p++;
    if(*p<'0'||*p>'9'||(*p=='0'&&p[1]>='0'&&p[1]<='9'))return false;
    uint32_t n=0;while(*p>='0'&&*p<='9') {unsigned d=(unsigned)(*p++-'0');if(n>(INT32_MAX-d)/10)return false;n=n*10+d;}
    if(minus&&!n)return false;
    *input=p;*value=minus?-(int32_t)n:(int32_t)n;return true;
}
static bool parse(const char *input,bh_command *command) {
    memset(command,0,sizeof *command);if(strncmp(input,"BH1 ",4))return false;input+=4;
    if(!hex_token(&input,command->session)||!hex_token(&input,command->owner)||!strcmp(command->owner,zero_owner))return false;
    /* IDs use full UInt32. No leading zeros, wrapping or signed IDs. */
    if(*input<'1'||*input>'9')return false;
    while(*input>='0'&&*input<='9') {unsigned d=(unsigned)(*input++-'0');if(command->id>(UINT32_MAX-d)/10)return false;command->id=command->id*10+d;}
    if(*input++!=' ')return false;
    if(!strcmp(input,"BEGIN")){command->kind=BEGIN;return true;}
    if(!strcmp(input,"PING")){command->kind=PING;return true;}
    if(!strcmp(input,"STOP")){command->kind=STOP;return true;}
    int32_t values[7]={0};size_t count;
    if(!strncmp(input,"MOUSE ",6)){command->kind=MOUSE;input+=6;count=4;}
    else if(!strncmp(input,"KEY ",4)){command->kind=KEY;input+=4;count=7;}
    else return false;
    for(size_t i=0;i<count;i++) {
        if(!number(&input,&values[i],command->kind==MOUSE&&i<3))return false;
        if(i+1<count&&*input++!=' ')return false;
    }
    if(*input)return false;
    if(command->kind==MOUSE) {
        for(size_t i=0;i<3;i++)if(values[i]<-127||values[i]>127)return false;
        if(values[3]<0||values[3]>7)return false;
        command->dx=(int16_t)values[0];command->dy=(int16_t)values[1];command->wheel=(int16_t)values[2];command->buttons=(uint8_t)values[3];
    } else {
        if(values[0]<0||values[0]>255)return false;
        command->modifiers=(uint8_t)values[0];
        for(size_t i=0;i<6;i++) {
            if(values[i+1]<0||values[i+1]>223||(values[i+1]>0&&values[i+1]<4))return false;
            command->keys[i]=(uint8_t)values[i+1];
            for(size_t j=0;j<i;j++)if(command->keys[i]&&command->keys[i]==command->keys[j])return false;
        }
    }
    return true;
}
static const char *phase_name(enum phase phase) {
    static const char *values[]={"accepted","reports_sent","neutral_sent","cancelled","unknown","rejected"};return values[phase];
}
static const char *code_name(enum code code) {
    static const char *values[]={"ok","format","session","owner","busy","mtu","subscriptions","stale","conflict","history_full","lease","stopped","disconnect","security","notify","queue_full","suspended"};return values[code];
}
static void ack(const bh_command *command,enum phase phase,enum code code) {
    if(connection==BLE_HS_CONN_HANDLE_NONE||!ack_subscribed||!secured())return;
    char output[BH_LINE_MAX+1];int length=snprintf(output,sizeof output,"BH1 %s %s %"PRIu32" %s %s",command->session,command->owner,command->id,phase_name(phase),code_name(code));
    if(length<0||(size_t)length>=sizeof output||ble_att_mtu(connection)<(uint16_t)(length+3)) {if(mode==ACTIVE)release_requested=NOTIFY;return;}
    struct os_mbuf *packet=ble_hs_mbuf_from_flat(output,(uint16_t)length);
    if(!packet||ble_gatts_notify_custom(connection,bluetooth_hid_ack_handle,packet)!=0) {if(mode==ACTIVE)release_requested=NOTIFY;}
}
static void finish(bh_receipt *receipt,enum phase phase,enum code code) {receipt->phase=phase;receipt->code=code;ack(&receipt->command,phase,code);}
static void release(enum code reason) {
    mode=RELEASING;lease_until=0;release_requested=OK;neutral_stage=0;
    if(pending_receipt>=0&&history[pending_receipt].phase==ACCEPTED)finish(&history[pending_receipt],UNKNOWN,reason);
    pending_receipt=-1;
    while(queue_count) {uint8_t index=queue[queue_head];queue_head=(queue_head+1)%BH_QUEUE;queue_count--;finish(&history[index],CANCELLED,reason);}
}
static void disconnect_state(void) {
    /* The physical link is gone: no queued input event may acquire its new
     * connection. The next connection gets a new nonce and neutral baseline. */
    connection=BLE_HS_CONN_HANDLE_NONE;mode=IDLE;pending_handle=0;pending_receipt=-1;pending_status=INT_MIN;queue_count=0;lease_until=0;
    keyboard_subscribed=mouse_subscribed=ack_subscribed=false;suspended=false;release_requested=OK;
    memset(owner,0,sizeof owner);memset(nonce,0,sizeof nonce);
    if(gate_held){gate_held=false;developer_service_release_input();}
}
static void terminate(void) {
    struct ble_gap_conn_desc descriptor;
    if(ble_gap_conn_find(connection,&descriptor)!=0){disconnect_state();return;}
    (void)ble_gap_terminate(connection,BLE_ERR_REM_USER_CONN_TERM);
}
static bool clear_baseline(void) {
    const uint8_t neutral[8]={0};
    const uint16_t handles[]={keyboard_handle,mouse_handle};
    for(size_t i=0;i<2;i++) {
        if(!handles[i])return false;
        struct os_mbuf *packet=ble_hs_mbuf_from_flat(neutral,i?4:8);
        if(!packet||ble_att_svr_write_local(handles[i],packet)!=0)return false;
    }
    return true;
}
static bool send_report(uint16_t handle,const uint8_t *data,size_t length,int index) {
    if(!secured()||suspended||!handle||(handle==keyboard_handle?!keyboard_subscribed:!mouse_subscribed))return false;
    struct os_mbuf *packet=ble_hs_mbuf_from_flat(data,(uint16_t)length);if(!packet)return false;
    pending_handle=handle;pending_status=INT_MIN;pending_until=now_ms()+BH_TX_MS;pending_receipt=index;pending_neutral=index<0;
    /* The built-in service updates its readable report and schedules NOTIFY.
     * The public local-write API consumes packet even on failure. */
    if(ble_att_svr_write_local(handle,packet)!=0){pending_handle=0;pending_receipt=-1;return false;}
    return true;
}
static void tick(struct ble_npl_event *event) {
    (void)event;uint64_t now=now_ms();
    if(connection!=BLE_HS_CONN_HANDLE_NONE) {
        if(mode==ACTIVE&&(release_requested!=OK||now>=lease_until||!secured()))release(!secured()?SECURITY:release_requested!=OK?release_requested:LEASE);
        if(pending_handle) {
            if(pending_status==INT_MIN&&now<pending_until)goto reschedule;
            if(pending_status==INT_MIN) {
                if(mode==ACTIVE)release(NOTIFY);
                terminate();goto reschedule;
            }
            int status=pending_status,index=pending_receipt;bool neutral=pending_neutral;pending_handle=0;pending_receipt=-1;pending_status=INT_MIN;
            if(status) {
                if(mode==ACTIVE){if(index>=0)finish(&history[index],UNKNOWN,NOTIFY);release(NOTIFY);}
                else {terminate();goto reschedule;}
            } else if(mode==ACTIVE) {
                if(index>=0&&history[index].phase==ACCEPTED)finish(&history[index],REPORTS_SENT,OK);
            } else if(mode==RELEASING&&neutral)neutral_stage++;
        }
        if(mode==RELEASING) {
            /* A fresh connection has no inherited owner. Clear the readable
             * baseline without requiring HID subscriptions or claiming TX.
             * On allocation failure keep diagnostics connected and fail closed. */
            if(!owner[0]) {if(clear_baseline())mode=IDLE;goto reschedule;}
            if(!secured()||!keyboard_subscribed||!mouse_subscribed||suspended) {
                terminate();
                goto reschedule;
            }
            if(!gate_held) {if(!developer_service_reserve_input())goto reschedule;gate_held=true;}
            if(neutral_stage<2) {
                const uint8_t neutral[8]={0};bool sent=send_report(neutral_stage?mouse_handle:keyboard_handle,neutral,neutral_stage?4:8,-1);
                if(!sent)terminate();
                goto reschedule;
            }
            for(size_t i=0;i<BH_HISTORY;i++)if(history[i].valid&&history[i].phase==ACCEPTED&&history[i].command.kind==STOP&&!strcmp(history[i].command.owner,owner))finish(&history[i],NEUTRAL_SENT,OK);
            if(owner[0])memcpy(last_owner,owner,sizeof last_owner);
            memset(owner,0,sizeof owner);mode=IDLE;
            gate_held=false;developer_service_release_input();
        } else if(mode==ACTIVE&&queue_count&&!pending_handle) {
            uint8_t index=queue[queue_head];queue_head=(queue_head+1)%BH_QUEUE;queue_count--;bh_command *command=&history[index].command;
            uint8_t data[8]={0};uint16_t handle;size_t length;
            if(command->kind==KEY){data[0]=command->modifiers;memcpy(data+2,command->keys,6);handle=keyboard_handle;length=8;}
            else {data[0]=command->buttons;data[1]=(uint8_t)command->dx;data[2]=(uint8_t)command->dy;data[3]=(uint8_t)command->wheel;handle=mouse_handle;length=4;}
            if(!send_report(handle,data,length,index)){finish(&history[index],UNKNOWN,NOTIFY);release(NOTIFY);}
        }
    }
reschedule:
    (void)ble_npl_callout_reset(&timer,ble_npl_time_ms_to_ticks32(20));
}
static int accept(const bh_command *command) {
    if(strcmp(command->session,nonce)){ack(command,REJECTED,SESSION);return 0;}
    for(size_t i=0;i<BH_HISTORY;i++)if(history[i].valid&&history[i].command.id==command->id) {
        if(memcmp(&history[i].command,command,sizeof *command))ack(command,REJECTED,CONFLICT);
        else ack(command,history[i].phase,history[i].code);
        return 0;
    }
    if(command->id<=highest){ack(command,REJECTED,STALE);return 0;}
    bool stopping=command->kind==STOP&&owner[0]&&!strcmp(owner,command->owner);
    if(stopping&&mode!=RELEASING)release(STOPPED);
    if(history[cursor].valid&&history[cursor].phase==ACCEPTED&&history[cursor].command.kind!=BEGIN&&history[cursor].command.kind!=PING){ack(command,REJECTED,HISTORY_FULL);return 0;}
    size_t index=cursor;cursor=(cursor+1)%BH_HISTORY;highest=command->id;
    bh_receipt *receipt=&history[index];memset(receipt,0,sizeof *receipt);
    receipt->valid=true;receipt->command=*command;receipt->phase=ACCEPTED;receipt->code=OK;
    enum code refusal=OK;
    if(stopping) { /* Release takes precedence over MTU/suspend changes. */ }
    else if(ble_att_mtu(connection)<BH_LINE_MAX+3)refusal=MTU;
    else if(suspended)refusal=SUSPENDED;
    else if(command->kind==BEGIN) {
        if(mode!=IDLE||!strcmp(command->owner,last_owner))refusal=BUSY;
        else if(!keyboard_subscribed||!mouse_subscribed||!ack_subscribed)refusal=SUBSCRIPTIONS;
        else if(!developer_service_reserve_input())refusal=BUSY;
        else {gate_held=true;memcpy(owner,command->owner,sizeof owner);mode=ACTIVE;lease_until=now_ms()+BH_LEASE_MS;}
    } else if(!owner[0]||strcmp(owner,command->owner))refusal=OWNER;
    else if(mode!=ACTIVE)refusal=BUSY;
    else if(now_ms()>=lease_until){release(LEASE);refusal=LEASE;}
    else if(command->kind==PING)lease_until=now_ms()+BH_LEASE_MS;
    else if(queue_count>=BH_QUEUE)refusal=QUEUE_FULL;
    else {queue[(queue_head+queue_count)%BH_QUEUE]=(uint8_t)index;queue_count++;lease_until=now_ms()+BH_LEASE_MS;}
    if(refusal!=OK)finish(receipt,REJECTED,refusal);
    else ack(command,ACCEPTED,OK);
    return 0;
}
int bluetooth_hid_access(uint16_t current,struct ble_gatt_access_ctxt *context,bool writing) {
    struct ble_gap_conn_desc security;
    if(current!=connection||ble_gap_conn_find(current,&security)||!security.sec_state.encrypted)return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    if(!security.sec_state.bonded)return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
    if(!writing) {
        char information[BH_LINE_MAX+1];uint64_t now=now_ms();uint32_t remaining=mode==ACTIVE&&lease_until>now?(uint32_t)(lease_until-now):0;
        int length=snprintf(information,sizeof information,"BH1 READY %s %s %s %"PRIu32" %"PRIu32,nonce,mode==IDLE?"idle":mode==ACTIVE?"active":"releasing",owner[0]?owner:zero_owner,highest,remaining);
        if(length<0||(size_t)length>=sizeof information)return BLE_ATT_ERR_UNLIKELY;
        return os_mbuf_append(context->om,information,(uint16_t)length)==0?0:BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    uint16_t length=OS_MBUF_PKTLEN(context->om);char input[BH_LINE_MAX+1];
    if(!length||length>BH_LINE_MAX||ble_hs_mbuf_to_flat(context->om,input,length,NULL)!=0)return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    for(size_t i=0;i<length;i++)if((unsigned char)input[i]<32||(unsigned char)input[i]>126)return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    input[length]=0;bh_command command;
    if(!parse(input,&command))return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    return accept(&command);
}
static void register_attribute(struct ble_gatt_register_ctxt *context,void *unused) {
    (void)unused;
    if(context->op!=BLE_GATT_REGISTER_OP_DSC||ble_uuid_u16(context->dsc.dsc_def->uuid)!=BLE_SVC_HID_DSC_UUID16_RPT_REF||!context->dsc.dsc_def->arg)return;
    struct os_mbuf *value=NULL;uint8_t reference[2]={0};
    if(ble_att_svr_read_local(context->dsc.handle,&value)!=0)return;
    int result=ble_hs_mbuf_to_flat(value,reference,sizeof reference,NULL);os_mbuf_free_chain(value);
    if(result||reference[1]!=BLE_SVC_HID_RPT_TYPE_INPUT)return;
    uint16_t handle=*(uint16_t *)context->dsc.dsc_def->arg;
    if(reference[0]==1)keyboard_handle=handle;else if(reference[0]==2)mouse_handle=handle;
}
static void control_write(uint16_t attribute,uint16_t uuid,uint8_t value) {
    (void)attribute;
    if(uuid==BLE_SVC_HID_CHR_UUID16_HID_CTRL_PT) {suspended=value==0;if(suspended&&mode==ACTIVE)release_requested=SUSPENDED;}
}
void bluetooth_hid_gap(struct ble_gap_event *event) {
    switch(event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if(event->connect.status)return;
        disconnect_state();connection=event->connect.conn_handle;mode=clear_baseline()?IDLE:RELEASING;highest=0;cursor=queue_head=queue_count=0;neutral_stage=0;
        memset(history,0,sizeof history);memset(last_owner,0,sizeof last_owner);uint8_t random[16];esp_fill_random(random,sizeof random);
        for(size_t i=0;i<sizeof random;i++)snprintf(nonce+i*2,3,"%02x",random[i]);
        memset(random,0,sizeof random);break;
    case BLE_GAP_EVENT_DISCONNECT:
        if(event->disconnect.conn.conn_handle==connection)disconnect_state();
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if(event->subscribe.conn_handle!=connection)return;
        if(event->subscribe.attr_handle==keyboard_handle)keyboard_subscribed=event->subscribe.cur_notify;
        else if(event->subscribe.attr_handle==mouse_handle)mouse_subscribed=event->subscribe.cur_notify;
        else if(event->subscribe.attr_handle==bluetooth_hid_ack_handle)ack_subscribed=event->subscribe.cur_notify;
        if(mode==ACTIVE&&(!keyboard_subscribed||!mouse_subscribed||!ack_subscribed))release_requested=SUBSCRIPTIONS;
        break;
    case BLE_GAP_EVENT_NOTIFY_TX:
        if(event->notify_tx.conn_handle!=connection||event->notify_tx.indication)return;
        if(event->notify_tx.attr_handle==pending_handle)pending_status=event->notify_tx.status;
        else if(event->notify_tx.attr_handle==bluetooth_hid_ack_handle&&event->notify_tx.status&&mode==ACTIVE)release_requested=NOTIFY;
        break;
    case BLE_GAP_EVENT_ENC_CHANGE:
        if(event->enc_change.conn_handle==connection&&mode==ACTIVE&&!secured())release_requested=SECURITY;
        break;
    default:break;
    }
}
void bluetooth_hid_reset(void) {disconnect_state();}
int bluetooth_hid_init(void) {
    /* Composite keyboard input/LED output and relative mouse. Report IDs are
     * conveyed by Report Reference descriptors, not prefixed to GATT values. */
    static const uint8_t report_map[]={
        0x05,0x01,0x09,0x06,0xa1,0x01,0x85,0x01,0x05,0x07,0x19,0xe0,0x29,0xe7,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x08,0x81,0x02,
        0x75,0x08,0x95,0x01,0x81,0x03,0x05,0x08,0x19,0x01,0x29,0x05,0x75,0x01,0x95,0x05,0x91,0x02,0x75,0x03,0x95,0x01,0x91,0x03,
        0x05,0x07,0x19,0x00,0x29,0xdf,0x15,0x00,0x26,0xdf,0x00,0x75,0x08,0x95,0x06,0x81,0x00,0xc0,
        0x05,0x01,0x09,0x02,0xa1,0x01,0x85,0x02,0x09,0x01,0xa1,0x00,0x05,0x09,0x19,0x01,0x29,0x03,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x03,0x81,0x02,
        0x75,0x05,0x95,0x01,0x81,0x03,0x05,0x01,0x09,0x30,0x09,0x31,0x09,0x38,0x15,0x81,0x25,0x7f,0x75,0x08,0x95,0x03,0x81,0x06,0xc0,0xc0
    };
    struct ble_svc_hid_params parameters={.hid_info=0x02000111,.external_rpt_ref=0x180f,.rpts_len=3};
    memcpy(parameters.report_map,report_map,sizeof report_map);parameters.report_map_len=sizeof report_map;
    parameters.rpts[0]=(struct report){.id=1,.type=BLE_SVC_HID_RPT_TYPE_INPUT,.len=8};
    parameters.rpts[1]=(struct report){.id=1,.type=BLE_SVC_HID_RPT_TYPE_OUTPUT,.len=1};
    parameters.rpts[2]=(struct report){.id=2,.type=BLE_SVC_HID_RPT_TYPE_INPUT,.len=4};
    ble_svc_bas_init();ble_svc_dis_init();static const char pnp[7]={2,0x3a,0x30,0x02,0x40,0x00,0x01};
    (void)ble_svc_dis_pnp_id_set(pnp);int result=ble_svc_hid_add(parameters);if(result)return result;
    ble_svc_hid_init();ble_svc_hid_register_char_write_cb(control_write);ble_hs_cfg.gatts_register_cb=register_attribute;
    result=ble_npl_callout_init(&timer,nimble_port_get_dflt_eventq(),tick,NULL);if(result)return result;
    return ble_npl_callout_reset(&timer,ble_npl_time_ms_to_ticks32(20));
}
