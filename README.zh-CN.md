# 随办 · iPhone Agent

[English](README.md) | 简体中文

[![CI](https://github.com/sjgw29d2nm/actell/actions/workflows/ios-ci.yml/badge.svg?branch=main)](https://github.com/sjgw29d2nm/actell/actions/workflows/ios-ci.yml)

**面向 iPhone Agent 操控的早期技术原型，用于思路分享。** 随办（Actell）探索让 iPhone 上的 Agent 调用 CoreDevice 服务，获取屏幕画面并执行点击、拖动。当前默认使用外部 VPN 回环的免 ESP32 路线，也可选择 ESP32-S3 USB NCM 转发；尚不具备生产可用性或长期后台稳定性保证。

https://github.com/user-attachments/assets/2aefc1a7-bdf1-42e7-83b9-51bd879256c8

App 使用 [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit)、[MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) 和 [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui)。开发者服务后端复用 [Device Hub](https://github.com/JaviSoto/device-hub-ios) 的补丁版 [idevice](https://github.com/jkcoxson/idevice)，协议实现参考 [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)；具体复用边界见下文。

## 从 ESP32 外设到 CoreDevice

最初希望通过 ESP32 模拟键盘、鼠标等外设，利用 iPhone 的通用外设能力实现控制，并在后续提供标准 MCP 接口，让各类 Agent 扩展使用。探索中遇到中文键鼠输入效率低、USB-C DP Alt Mode 画面采集对硬件要求高，以及用 App 录屏会占用录制通道等限制，因此当前改用 CoreDevice 服务获取画面和执行触控。现阶段 ESP32-S3 提供 USB NCM 网络、发现与受限双向数据转发；配对身份、认证和控制协议由 App 处理，画面与触控由 iPhone 系统服务执行。调用 CoreDevice 也可以探索 Network Extension 的本机回连路径，ESP32 不是这条路径的必要硬件：当前 App 已接入 VPN 回环路线（已用 LocalDevVPN 验证），共用配对身份和 CoreDevice 后端，但本仓库没有实现或管理自己的 Network Extension。标准 MCP 接口仍是后续规划，当前未实现。

## 当前能力与边界

- 支持 OpenAI Chat Completions 兼容服务商与模型，通过 `screenshot`、`tap`、`drag`、`wait` 工具执行任务；「设置 → 供应商」添加时先选择 OpenAI、OpenRouter 或自定义供应商；自定义不预填，编辑页固定供应商类型并可选择 API格式。旧 Anthropic、Gemini、Ollama 配置仍可读取，使用当前类型需另行添加供应商。
- 可导入 Markdown/TXT 技能包，按需读取文本；导入不执行脚本。支持会话历史、图片附件、工具审批与手动停止。同一手机的控制任务按整轮排队，结果不确定的动作不自动重放。
- 控制会话持续接收显示流，用 VideoToolbox 解码并缓存最近完整帧。截图工具从该流取得画面、裁去填充区域并编码 JPEG，默认不逐次调用系统独立截图服务。调用时仍会等待新解码帧，或请求开始后的发送端进度报告确认缓存画面完整；最长等待八秒，不能理解为立即返回任意旧缓存。独立 PNG 截图实现保留，但不会自动回退。
- ESP32 路线已有真实截图与测试按钮计数增加的记录；VPN 回环路线在 2026-10-09 的 iPhone 15 Pro 测试中复用配对身份，得到 1179 × 2556 截图、实际点击计数 0 → 1，并确认媒体释放。完整模型任务、拖动及 VPN 回环后台持续执行仍待单独验收。
- 后台提供音频／画中画执行模式，但系统挂起、终止、锁屏或连接故障仍可能停止任务；后台稳定性没有普遍验证。旧 ScreenCaptureKit/PA3 USB HID 与 TLS 实现保留，当前没有旧链路切换开关。

以上依据当前源码与项目内已有验证记录；不同路线、设备和历史阶段的结果不能互相替代。详见 [项目待办与验证](docs/PROJECT-TODOS.md)、[视频几何与帧完整性](docs/ncm-coredevice/VIDEO-GEOMETRY.md)、[VPN 回环使用与验证](docs/ncm-coredevice/LOCALDEVVPN.md)。

## 准备与运行

当前工程最低目标为 **iOS 27**，构建使用 **Xcode 27**。需要为真机配置自己的有效签名；下方无签名构建只生成产物，不能直接安装。模型任务需要自行配置兼容服务商、模型及凭据，截图与显式发送的附件会传给所选模型。

设备控制的前置条件：

1. 开启 iPhone 开发者模式，允许 App 访问本地网络；按 App「配对」入口提示，在系统界面完成信任／PIN 配对。两条路线共用 App 沙盒中的 RemotePairing 身份。
2. 设备须已准备匹配的 Personalized Developer Disk Image（DDI），通常由 Xcode 准备。当前后端只检查开发者模式和镜像是否存在，不下载、个性化或挂载镜像；仓库不包含 Apple 开发者镜像，不能承诺首次准备完全无需 Mac。
3. 在「设置 → 手机操控 → 连接模式」选择路线，再进入「连接与验证」完成连接、截图和实际点击验证：
   - **VPN 回环（默认，免 ESP32）**：在同一 iPhone 启用支持本机数据包回注的 VPN（已使用 [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) 验证）。在控制页编辑接口地址与对端地址，默认分别为 `10.7.1.1`、`10.7.0.1`，需与外部 VPN 配置一致。App 不安装或启停 VPN；详见 [路线说明](docs/ncm-coredevice/LOCALDEVVPN.md)。
   - **ESP32 NCM**：使用支持原生 USB Device 的 ESP32-S3 与数据线，安装当前 NCM 固件并通过原生 USB 接口连接 iPhone。USB 角色、板级接线和供电须按实际硬件核对，见 [固件说明](firmware-device/README.md) 和 [硬件资料](docs/hardware/ESP32-S3-USB.md)。
4. 在设置添加服务商后创建会话。普通聊天不要求设备连接；控制工具执行时仍检查身份、连接和授权。运行中不能切换控制路线。

### 构建

以下命令均在仓库根目录执行。构建脚本复用本机工具链，并非开箱即用的安装器：

- 独立安装 Rust，并运行 `rustup target add aarch64-apple-ios aarch64-apple-ios-sim` 安装 iOS target。脚本从 PATH 或标准 Cargo 安装位置查找 Rust，可用 `NCM_RUST_TOOLCHAIN` 显式选择工具链，不依赖旁边的项目目录。后端使用 `--locked` 和标准 Cargo 缓存（或 `CARGO_HOME` / `NCM_CARGO_HOME`），首次构建可下载依赖；缓存完备后可设置 `NCM_CARGO_OFFLINE=1` 离线构建。包使用 edition 2024，版本见 [Cargo.lock](ncm-dev/rust/Cargo.lock)。
- 固件使用 ESP-IDF 5.5.5，可通过 `IDF_PATH`、`IDF_TOOLS_PATH` 指向已安装环境；组件版本由 [清单](firmware-device/main/idf_component.yml) 和锁文件固定。
- Xcode 项目已提交；应用显示名以 `ios-app/project.yml` 为准。生成脚本依赖 PyYAML（版本锁定在 `ios-app/scripts/requirements-qa.txt`）；未安装时运行 `python3 -m pip install 'PyYAML==6.0.2'`，新增源文件后再运行 `python3 ios-app/scripts/generate_xcode_project.py`。首次构建允许 Swift Package Manager 解析依赖；Xcode 构建阶段会生成当前平台的 Rust 静态库。

```sh
# iPhoneOS 无签名构建；不会安装或修改签名
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO build

# ESP32 路线：仅构建 NCM 固件，不自动刷写
bash tools/build_usb_device.sh ncm
```

真机安装需在 Xcode 中选择签名和设备后运行。App 的更多配置与已缓存依赖的构建命令见 [iOS 说明](ios-app/README.md)；固件产物位于 `.build/device-ncm/`，刷写需自行核对串口与硬件。

### 验证

```sh
CC=clang bash tools/test_usb_device.sh
bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
RUN_UI_TESTS=1 bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
```

协议测试使用回环网络；App 测试使用合成模型与临时存储，不能代替真实设备验收。UI 用例会向指定的独立模拟器添加测试图片和文件。核心协议、单次授权、会话隔离、未知结果不重放、checkpoint 迁移及停止释放覆盖保留在默认 target。

GitHub Actions 在 Linux 上检查工程生成一致性、Swift 源语法和协议夹具；在 Xcode 27 macOS runner 上运行 USB Device 回环、无签名构建及模拟器核心／UI 测试。自动化结果见页面顶部 CI 状态。

## 依赖与来源

| 项目 | 当前使用方式 |
| --- | --- |
| [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit) | Agent 核心与宏的本地源码快照，含 iOS 存储兼容补丁；未引入上游 MCP 模块 |
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) / [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | Swift Package 依赖，分别用于模型调用和消息 Markdown 渲染 |
| [idevice](https://github.com/jkcoxson/idevice) / [Device Hub](https://github.com/JaviSoto/device-hub-ios) | 使用 Device Hub 固定的补丁版 idevice 源码与 PNG validator，并作本地适配；不是集成整个 Device Hub App |
| [ManifoldKit](https://github.com/ManifoldKit/ManifoldKit) | 摘取、适配工具调用展示组件，不是整个框架的包依赖 |
| [ESP-IDF](https://github.com/espressif/esp-idf/tree/v5.5.5)、[esp_tinyusb](https://github.com/espressif/esp-usb)、[TinyUSB](https://github.com/hathach/tinyusb) | ESP32 固件工具链及 USB 组件；固定 ESP-IDF 5.5.5、esp_tinyusb 2.2.0、TinyUSB 0.21.0~2 |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | 协议 schema 参考／选择性转译，固定参考文件用于离线测试；不是手机或 ESP32 上运行的 Python 服务 |
| [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | 已验证的外部 VPN 回环实现；未复制其 Network Extension 实现 |

Rust 其余直接及传递依赖见 [Cargo.toml](ncm-dev/rust/Cargo.toml) 和 [Cargo.lock](ncm-dev/rust/Cargo.lock)，Swift 固定版本见 [Package.resolved](ios-app/PhoneAgent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)。[idevice_pair](https://github.com/jkcoxson/idevice_pair) 和 [rPlayHub](https://github.com/rPlayAI/rPlayHub) 属于协议研究参考，未作为当前运行依赖；历史 USB Host 相关来源也不等于当前 NCM 后端依赖。

现有许可与来源记录见 [LICENSE](LICENSE)、[THIRD_PARTY.md](THIRD_PARTY.md)、[iOS 许可证](ios-app/Licenses/)、[SwiftAgentKit 快照说明](ios-app/Vendor/SwiftAgentKit/README.md)、[ManifoldKit 摘取说明](ios-app/Vendor/ManifoldPresentation/README.md) 和 [CoreDevice 复用边界](docs/ncm-coredevice/REUSE.md)。

## 目录与进一步阅读

| 路径 | 用途 |
| --- | --- |
| `ios-app/` | PhoneAgent App、测试与工程生成脚本 |
| `firmware-device/` | 当前 USB Device NCM 固件及保留的 HID 模式 |
| `ncm-dev/` | 共用 Swift/C/Rust CoreDevice 后端、协议模块及独立 Probe |
| `tests/usb_device/` | USB Device 生产协议的本机测试夹具 |
| `tools/` | 构建与验证脚本 |
| `docs/` | 当前路线说明、诊断和验证记录；历史阶段描述按日期阅读 |
| `archives/` | 历史文档与非核心测试归档 |
| `firmware/` | 保留的旧 USB Host 实验，不是当前默认固件 |

- [主工程整合](docs/ncm-coredevice/MAIN-INTEGRATION.md) · [系统配对记录](docs/ncm-coredevice/PAIRING.md)
- [后台执行诊断](docs/BACKGROUND-RUN-RECOVERY.md) · [会话停止与释放](docs/CONTROL-SESSION-TEARDOWN.md)
- [PA3 协议](docs/usb-device/PROTOCOL.md) · [历史归档入口](archives/README.md)
