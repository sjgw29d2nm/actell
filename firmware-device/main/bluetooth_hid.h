/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include <stdbool.h>
#include <stdint.h>

/* BH1 commands/receipts and HOGP share the sole NimBLE connection.
 * State changes run on NimBLE's default event queue; no input worker survives
 * STOP, link loss or a connection nonce change. */
extern uint16_t bluetooth_hid_ack_handle;
int bluetooth_hid_init(void);
int bluetooth_hid_access(uint16_t connection,struct ble_gatt_access_ctxt *context,bool writing);
void bluetooth_hid_gap(struct ble_gap_event *event);
void bluetooth_hid_reset(void);
