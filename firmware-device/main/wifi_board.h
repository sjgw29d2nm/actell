/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include "esp_err.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Saved access-point credentials survive restart independently of BLE.
 * Credentials are created once at startup and read over paired encrypted BLE. */
esp_err_t wifi_board_start(void);
bool wifi_board_online(void);
uint32_t wifi_board_epoch(void);
uint32_t wifi_board_network_index(void);
bool wifi_board_authorize(const char *token);
esp_err_t wifi_board_information(char *output,size_t capacity);
