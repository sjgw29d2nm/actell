# PhoneAgent USB Device 固件

2026-10-06：主固件已接入经过独立 App 验证的开发者服务转发。一次 USB 网络初始化同时提供 `28766` 的原 PA3 服务和 `28767` 的 ND1/NR1/NL1 服务。新链路由主 App“设置 → S3 控制”发起，S3 只负责外向连接与有界转发，身份、认证、截图协议和触控协议由 App 处理。NCM-only 也可以通过开发者服务执行截图和点击；下文“NCM-only 拒绝 tap/drag”仅指 PA3 协议命令。

构建继续使用 `tools/build_usb_device.sh ncm` / `hid`。主网络接口增加 IPv6 link-local 和 IGMP/MLD，用于同链路发现；不设置默认路由。转发服务源码位于 `main/developer_service.c`，复用 `ncm-dev/core` 协议模块；独立诊断固件也引用同一份服务实现。整合后构建与验证状态见 [主工程整合](../docs/ncm-coredevice/MAIN-INTEGRATION.md)。

入口是 `main/main.c`，ESP32-S3 原生 USB Device。默认仅 NCM；HID 需要独立构建。当前源码使用 **PA3 免 PSK、跨任务复用 TCP**，无需设备或 App 密钥配置。App 与固件需要一起更新，不兼容 PA1/PA2。两种固件已本机构建；PA3 NCM+HID 已完成 COM 烧录、三段摘要校验和启动检查，iPhone 常连/HID 仍待验收，见 [PA3 升级说明](../docs/usb-device/PERSISTENT-USB.md)。以下为历史设备记录：2026-10-04 19:34 已通过 COM 烧录 PA2 NCM-only；用户随后确认 iPhone PA2 双向 PING、最新版 App 本机截图预览正常。23:03 经用户明确批准烧录已修复 STOP 竞争的 NCM+HID 候选，三段设备摘要、UART 启动检查通过，真实 HID 输入仍待验证，见 [HID 烧录与联调](../archives/history/docs/usb-device/HID-BRINGUP.md)。历史记录见[首次实机记录](../archives/history/docs/usb-device/NCM-BRINGUP.md)及[免 PSK 验证与烧录记录](../archives/history/docs/usb-device/NO-PSK.md)。

从仓库根目录：

```sh
./tools/build_usb_device.sh ncm
./tools/build_usb_device.sh hid
./tools/test_usb_device.sh
./tools/with_device_idf.sh python tools/verify_usb_device_builds.py
```

构建入口复用本机 `../with-esp/.build/toolchains/` 中已安装的 ESP-IDF 5.5.5，所有新 build/cache 在本 worktree 的 `.build/`。其他机器可通过 `IDF_PATH`、`IDF_TOOLS_PATH` 指向已安装工具链。没有安装脚本，没有 flash/monitor 命令。

依赖固定为 `esp_tinyusb ==2.2.0`、`tinyusb ==0.21.0~2`，锁文件带组件 hash。`SDKCONFIG` 为每个构建独立保存，不使用原 Host 项目的配置。当前随办硬件启用 BLE 身份／PING 与标准键盘、相对鼠标，不启动 Wi-Fi／AP／STA；console 为 UART，不借调试 CDC。PSRAM 当前未使用，flash 配置 16 MB。真实 COM 与 iPhone 接线验证状态见上述实机记录及 [最新证据](../docs/PROJECT-TODOS.md)。

BLE 已移除 `.104`～`.106` 配网服务，保留 `.100`～`.103` 的 SB1 身份／PING 和 `.107`／`.108` 的 BH1 输入／回执。仅已加密、绑定且具备完整系统 HID 订阅的连接可开始输入；750ms 有限租约、严格指令 ID、去重和 STOP 释放保护共享输入门。USB 开发者服务继续固定实际 USB netif，保留 ND1／NR1／NL1。

构建产物：

```text
.build/device-{ncm,hid}/
  phoneagent_usb_device.bin
  phoneagent_usb_device.elf
  bootloader/bootloader.bin
  partition_table/partition-table.bin
  flash_args
  flasher_args.json
  sdkconfig
```

当前 PA3 产物是实际本机交叉编译生成的镜像；HID 候选已烧录，NCM-only 仅构建。历史 PA2 NCM-only 和随后 NCM+HID 均已分别烧录并通过 UART 启动检查；镜像未签名，真实 HID/Agent 闭环尚待验收。NCM-only 可 PING/STOP，始终拒绝 tap/drag。历史 NCM-only 串口压缩传输曾中断，最终以 57600、ROM 无 stub/无压缩方式恢复；历史 HID 烧录沿用该方式，三段一次写入及校验成功，未重复备份。详情见上述记录。

USB 没有通信密钥，能访问 USB 网络的其他程序也能调用协议；用户已接受此行为。硬件无线 TCP 与 `NW1 AUTH` 已移除。固件继续使用 NVS 保存 BLE 绑定，升级不覆盖旧 NVS，也不修改 eFuse、安全启动或 Flash 加密。App 与固件需要同时采用 PA3；系统全屏采集、本地网络授权仍保留，USB 普通动作在用户开始任务时授权。旧 Host TLS 与模型 API 的 Keychain 不受影响。

后续烧录约定（用户于 2026-10-04 明确调整）：对于来源已知、保有源码和构建配置、可重新构建的工程固件，**默认跳过设备固件读回备份**，直接核对目标、镜像与写入范围，再执行已授权的烧录、设备摘要校验和必要启动检查。仅在将覆盖不可重建的数据（如 NVS 中的配置/凭据、校准数据）、替换来源未知且需要保留的固件，或分区变更确实需要保留原数据时，按实际需要备份相关区域并说明原因；不再把每次读取 512 KiB 或整片 Flash 当作固定前置步骤。现有备份与历史日志保留。此约定不改变烧录授权及接线确认要求。

接线初步要求：只通过已确认 D−/D+ 接 GPIO19/20 的原生 USB 口连接 USB-C iPhone，由 iPhone 供电。不要误用 CH340/COM 口，也不要默认同时接 Mac COM 供电；板上 VBUS 回流路径、现有焊盘状态和额定电流需确认。N16R8 不是板型证据。不要求新增 Hub、Wi-Fi/BLE 模块或其它设备。

固定 IP 验证：设备 `192.168.7.1/24`，iPhone `192.168.7.2/24`，Router/DNS 留空。如果 iOS 不接受空 Router 或不枚举以太网，不填假网关，记录现象后停止。现有蜂窝/系统 VPN 是否仍能访问模型必须单独测试，不修改 VPN。

详细协议、架构和验收顺序见 [架构](../archives/history/docs/usb-device/ARCHITECTURE.md)、[协议](../docs/usb-device/PROTOCOL.md)、[验证记录](../archives/history/docs/usb-device/VALIDATION.md)。
