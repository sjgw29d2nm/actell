// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
/* USB retains its existing protocol; Wi-Fi joins the same owner after NW1 AUTH. */
esp_err_t developer_service_start(bool (*online)(void), uint32_t (*epoch)(void), uint32_t interface_index);
/* A configuration reservation excludes a new relay OPEN until it completes. */
bool developer_service_busy(void);
bool developer_service_reserve_wifi_configuration(void);
void developer_service_release_wifi_configuration(void);
