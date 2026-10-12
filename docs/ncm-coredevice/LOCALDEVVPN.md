# VPN 回环（VPN loopback）免 ESP32 模式

在「设置 → 手机操控 → 连接模式」选择「VPN 回环」，再打开「连接与验证」。VPN 回环为第一项及未保存偏好时的默认值；已有手动选择会保留。任务占用连接、系统配对、诊断操作和媒体释放期间禁止切换。

## 使用步骤

1. 在同一台 iPhone 启用支持本机数据包回注的 VPN，例如已验证的 LocalDevVPN。控制页提供普通字体的「接口地址」「对端地址」文本框，默认 `10.7.1.1`、`10.7.0.1`；可修改为外部 VPN 实际使用的 IPv4 地址并保存。App 不依赖特定 VPN App 的身份或 API；普通远程 VPN 不因此自动具备本机回注能力。
2. 开启 iOS 开发者模式并允许随办访问本地网络。没有配对身份时，通过现有「配对」入口到系统设置选择「随办」完成配对；已有 ESP32 路线的配对身份可直接复用。
3. 点击「连接」，等待身份认证、TLS/CDTunnel、RSD、开发者模式及镜像检查通过。
4. 获取截图，再进入「点击验证」。中央计数增加才算实际触控成功。最后回到会话执行真实任务，验证截图、点击、拖动、停止，以及切后台后的行为。

App 不安装或启停外部 VPN，也不添加 Network Extension entitlement。VPN 系统许可由对应 VPN App 自己管理。配对、开发者镜像和系统服务是否可用仍取决于真实设备状态。

## 授权与连接

ESP32 与 VPN 回环共用本 App 沙盒里的 `RemotePairing/identity.plist`，包括控制端私钥和认证后的设备公钥。模式切换不复制、重写或删除此文件；「重新配对」会更新这份共享身份，因此影响两条路线。

共享身份不意味着共享活动连接。每次切换关闭旧传输与媒体，变更会话代次，清除截图和动作授权；新通道重新做 Pair Verify。既有单次授权、同一手机整轮排队、未知结果不重放与停止释放机制继续共用。切换不回退到另一条路线。

## 实现

- `LocalVPNDiscovery` 先检查与已保存接口地址匹配的 `utun` 接口，再浏览 `_remotepairing._tcp`。只接受解析地址与本机地址相符的服务；没有候选或端口不唯一时失败，不扫描或猜测端口。发现超时为四秒，取消会停止 Bonjour。
- `ncm_local_vpn_start_configured` 与 ESP32 入口执行同样的身份和权限检查，复用 CoreDevice 后端。Rust connector 每次建连重新检查接口，并使用 `IP_BOUND_IF` 和本地地址绑定已保存的接口地址，直接向已保存的 VPN 对端发送协议数据，不发送 S3 relay 前缀。
- 首条连接使用发现的 RemotePairing 端口，第二条使用认证后协商的 TLS 隧道端口。每个入口只能拨号一次，没有默认路由回退或输入重放。
- 截图继续复用视频 JPEG，点击、拖动和应用服务沿用现有实现。

地址与反射方式依据 [LocalDevVPN 默认配置](https://github.com/jkcoxson/LocalDevVPN/blob/main/LocalDevVPN/Constants.swift) 和 [PacketTunnelProvider](https://github.com/jkcoxson/LocalDevVPN/blob/main/TunnelProv/PacketTunnelProvider.swift)，核对于 2026-10-09。本改动未复制其 VPN 实现。

## 验证边界

本次新增接口选择、端口歧义、授权前置、单次拨号、不回退，以及模式切换保持身份/撤销旧连接/运行中拒绝切换的自动化覆盖。模拟器能验证模式 UI 与持久化，不能证明真实系统接受本机 CoreDevice 通道。

2026-10-09 21:12（北京时间），已在用户开启 LocalDevVPN 的 iPhone 15 Pro 上通过实际测试：

- 新版本沿用原 Bundle ID/签名更新安装；`paired=true`，没有重新配对。
- `route=localDevVPN`，四秒内完成 CoreDevice 身份认证、隧道与服务检查。
- 截图为 **1179 × 2556 JPEG**；通过生产 `NCMDeviceBridge` 调用触控，App 自己的真实按钮计数 **0 → 1**，第二张截图确认计数为 1。
- 同时刻事件记录 `control.mediaReleased peerConfirmed=true connectionRetained=true`，确认远端媒体释放成功。
- 验证后恢复正常 App 启动，保留 LocalDevVPN 模式。Mac 只用于构建、安装、启动和读取诊断文件；截图及触控由手机 App 经 LocalDevVPN 执行，不经 ESP32，也未调用 Mac 截图/触控服务。

证据在 `.build/local-vpn-validation/`：`probe.log`、`before.jpg`、`after.jpg`、`events.log`。DEBUG 启动参数 `--local-vpn-probe` 可复现本机测试计数器上的一次截图/点击/截图/释放，不操作用户业务数据；正常启动不运行该诊断。

自动化：默认 App **325 项通过**（`.build/validation/core.jAMSbp/Tests.xcresult`）；Swift/C/Rust 全链路 **39 项通过**；Rust backend **44 项**、上游协议 **176 项**通过；PA3 ASan/UBSan 与 TCP **25 项**通过。签名及无签名 iPhoneOS 构建通过。断连聊天夹具已更新为公共连接错误文字，修正后完整默认 target 通过。

首次模拟器验证在重启步骤转为真机测试；后续通用命名改动已完成完整 UI 持久化用例，见下文。VPN 回环路线的真机拖动、后台持续执行及完整模型任务尚未单独验收，不从本次前台截图/点击结果外推。


## 通用命名与地址编辑

2026-10-09 改用「VPN 回环」技术名称，移除控制页顶部介绍和等宽地址说明。编辑后保存会撤销旧连接与截图授权，保留共享配对身份；非法、相同、回环或组播 IPv4 地址不会写入设置。任务占用连接时禁止修改。已有模式偏好使用兼容的持久化值保留。服务端口继续由 Bonjour 发现及认证协议协商，不需要用户填写端口。

本次验证：默认 App **326 项**、Swift/C/Rust 全链路 **40 项**、Rust backend **45 项**与上游协议 **176 项**、PA3 ASan/UBSan 与 TCP **25 项**均通过。模拟器 UI 用例验证新名称、默认地址输入框、顶部介绍移除、重启后模式持久化及切回 ESP32；截图已人工检查。签名及无签名 iPhoneOS 构建通过。

2026-10-09 21:35（北京时间）更新安装到同一台 iPhone 15 Pro，使用默认地址再次验证：沿用已有配对身份，CoreDevice 认证成功，取得 **1179 × 2556** 截图，真实计数按钮 **0 → 1**，媒体释放确认成功，随后恢复正常 App 启动。证据：`.build/vpn-loopback-validation/probe.log`、`ui/` 与 `.build/validation/VPNLoopbackSettings.xcresult`。自定义地址的校验、保存与接口选择由自动化测试验证；其他地址及其他 VPN App 未做真机兼容验收。

新建配对时，系统发现广播与配对协议中的授权名称均为「随办」。已有配对身份继续复用，不自动删除或重新配对；系统保存的旧名称可能需用户重新配对才会更新。

默认模式与授权名称调整后，完整 App **326 项**通过（`.build/validation/core.3i9Rvn/Tests.xcresult`），包括未保存/未知偏好默认 VPN 回环、保留显式 ESP32 选择、模式切换撤销连接且保留身份。Rust backend **45 项**及上游协议 **176 项**通过；签名与无签名 iPhoneOS 构建通过，新版本已更新安装并正常启动。未重做系统配对，因此新授权名称尚未在真机系统配对页面单独验收。
