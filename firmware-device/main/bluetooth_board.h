/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include "esp_err.h"
#include <stdbool.h>
esp_err_t bluetooth_board_start(void);
bool bluetooth_board_open_wifi_window(void);
void bluetooth_board_close_wifi_window(void);
