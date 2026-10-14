set(CORE "${CMAKE_CURRENT_LIST_DIR}/../../ncm-dev/core")
set(BRIDGE "${CMAKE_CURRENT_LIST_DIR}/../../firmware/components/bridge_core")
idf_component_register(SRCS "main.c" "usb_network.c" "usb_hid.c" "protocol.c" "hid_motion.c" "developer_service.c" "bluetooth_board.c" "bluetooth_hid.c" "wifi_board.c"
    "${CORE}/nd_discovery.c" "${CORE}/nd_pairing.c" "${CORE}/nd_socket.c" "${CORE}/nd_server.c" "${CORE}/nd_services.c" "${CORE}/nd_http.c" "${CORE}/nd_relay.c"
    "${BRIDGE}/bridge_xpc.c" "${BRIDGE}/bridge_hid.c" "${BRIDGE}/bridge_requests.c"
    "${BRIDGE}/bridge_screenshot_stream.c" "${BRIDGE}/bridge_remotexpc.c" "${BRIDGE}/bridge_rsd.c" "${BRIDGE}/bridge_operations.c"
    "${BRIDGE}/bridge_io.c" "${BRIDGE}/bridge_bplist.c" "${BRIDGE}/bridge_lockdown_probe.c"
    INCLUDE_DIRS "." "${CORE}" "${BRIDGE}/include"
    PRIV_REQUIRES esp_netif esp_event esp_timer json bt nvs_flash esp_wifi esp_driver_gpio)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra -Werror)
