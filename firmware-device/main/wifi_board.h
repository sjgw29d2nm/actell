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
bool wifi_board_ap_link(uint8_t address[4],uint8_t peer[4],uint32_t *index,uint32_t *epoch);
bool wifi_board_authorize(const char *token);
esp_err_t wifi_board_information(char *output,size_t capacity);
/* Router credentials are accepted asynchronously over bonded encrypted BLE. */
esp_err_t wifi_board_configure_router(const char *json,size_t length);
esp_err_t wifi_board_router_information(char *output,size_t capacity);
bool wifi_board_router_online(void);
uint32_t wifi_board_router_epoch(void);
bool wifi_board_router_link(uint8_t address[4],uint8_t mask[4],uint32_t *index,uint32_t *epoch);
