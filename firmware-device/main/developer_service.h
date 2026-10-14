// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
/* Developer services are restricted to the directly attached USB NCM link. */
esp_err_t developer_service_start(bool (*online)(void), uint32_t (*epoch)(void), uint32_t interface_index);
/* BLE input and a USB relay share one reservation until their safe release. */
bool developer_service_busy(void);
bool developer_service_reserve_input(void);
void developer_service_release_input(void);
