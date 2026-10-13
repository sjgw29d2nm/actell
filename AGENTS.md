# 阅读与验证入口

当前 App 最低 iOS 26.5，使用 Xcode 27 构建；默认通过 VPN 回环开发者服务截图/触控（免 ESP32）。可在设置选择 ESP32 NCM 模式，复用系统配对身份与 CoreDevice 后端。ScreenCaptureKit + PA3 USB Device NCM/HID 和 TLS 实现保留；ScreenCaptureKit 需要 iOS 27，旧链路暂未提供切换开关。先读 `README.md` 和本次改动涉及的源码；项目待办重评/证据在 `docs/PROJECT-TODOS.md`。

默认检索范围：`ios-app/PhoneAgent`、`ios-app/PhoneAgentTests`、`ios-app/PhoneAgentUITests`、`firmware-device/main`、`tests/usb_device`。不要默认递归读取 `.build/`、`archives/`、`ios-app/Vendor/` 或旧 Host `firmware/`、`tests/usb_host_sim/`；当问题涉及相应实现、上游兼容或历史证据时再按需查看。许可证与来源清单保留。

默认验证：

- PA3 协议/停止释放：`CC=clang bash tools/test_usb_device.sh`（仅回环网络）。
- App 改动：`bash ios-app/scripts/test_core.sh <隔离模拟器 UDID>`；加 `RUN_UI_TESTS=1` 跑现行 UI 用例。
- 最终无签名 iPhoneOS build：参见 `ios-app/README.md`。
- 核心协议、单次授权、会话隔离、未知结果、不重放、checkpoint 迁移和停止释放测试始终保留在默认 target。不能为缩短验证删除这些覆盖。

归档入口见 `archives/README.md`。非核心 PiP 状态展示和 Siri UI 测试可通过 `INCLUDE_ARCHIVED_TESTS=1 python3 ios-app/scripts/generate_xcode_project.py` 临时加入；结束后不带该变量重新生成默认工程。旧控制调试 UI 用例是历史证据，不代表当前导航验收。固件 Host 测试的原目录和脚本继续保留，按涉及范围显式运行。
