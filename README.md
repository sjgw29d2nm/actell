# Suiban (随办) · iPhone Agent

English | [简体中文](README.zh-CN.md)

[![CI](https://github.com/sjgw29d2nm/actell/actions/workflows/ios-ci.yml/badge.svg?branch=main)](https://github.com/sjgw29d2nm/actell/actions/workflows/ios-ci.yml)

**An early technical prototype for exploring iPhone agent control.** Suiban (随办) explores how an agent running on an iPhone can call CoreDevice services to capture the screen and perform taps and drags. The current default uses an external VPN loopback route without an ESP32; ESP32-S3 USB NCM forwarding is also available. Production readiness and reliable long-running background execution are not guaranteed.

https://github.com/user-attachments/assets/2aefc1a7-bdf1-42e7-83b9-51bd879256c8

The app uses [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit), [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI), and [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui). Its developer-services backend reuses the patched version of [idevice](https://github.com/jkcoxson/idevice) used by [Device Hub](https://github.com/JaviSoto/device-hub-ios), with protocol references from [pymobiledevice3](https://github.com/doronz88/pymobiledevice3). The reuse boundaries are described below.

## From ESP32 peripherals to CoreDevice

The initial idea was to emulate peripherals such as keyboards and mice with an ESP32, control the iPhone through its standard peripheral support, and eventually expose a standard MCP interface for other agents. Exploration revealed limitations: inefficient Chinese text entry through keyboard/mouse input, demanding hardware requirements for USB-C DP Alt Mode capture, and app-based screen recording occupying the recording channel. The current approach therefore uses CoreDevice services for screen capture and touch input.

The ESP32-S3 currently provides USB NCM networking, discovery, and restricted bidirectional data forwarding. The app handles pairing identities, authentication, and control protocols; iPhone system services provide the screen content and execute touch input. CoreDevice access also allows exploration of a local connection through Network Extension, so an ESP32 is not required for that route. The app now supports VPN loopback, verified with LocalDevVPN, sharing the same pairing identity and CoreDevice backend. This repository does not implement or manage its own Network Extension. A standard MCP interface remains planned and is not implemented.

## Current capabilities and limits

- Supports OpenAI Chat Completions-compatible providers and an explicitly selectable native Responses path, using the `screenshot`, `tap`, `drag`, and `wait` tools to execute tasks. Settings → Suppliers starts with OpenAI and OpenRouter presets, followed by a custom supplier with blank fields. The supplier type is fixed in the editor; API format is selectable. Legacy Anthropic, Gemini and Ollama configurations remain readable, but a replacement must be added to use a current supplier.
- Imports Markdown/TXT skill packages and reads their text on demand; importing does not execute scripts. Supports conversation history, image attachments, tool approval, and manual stopping. Control tasks for the same phone are queued by whole agent turn, and actions with uncertain outcomes are not automatically replayed.
- Control sessions continuously receive a display stream, decode it with VideoToolbox, and cache the latest complete frame. The screenshot tool takes an image from that stream, removes padding, and encodes it as JPEG; it does not call the system's separate screenshot service for each request by default. Each call still waits for a newly decoded frame or a sender progress report received after the request begins to confirm that the cached image is complete. The wait can take up to eight seconds; this does not mean immediately returning any old cached frame. The standalone PNG screenshot implementation remains available in the source, but is not an automatic fallback.
- The ESP32 route has recorded real screenshots and increases in a test button's tap counter. In an iPhone 15 Pro test on 2026-10-09, the VPN loopback route reused the pairing identity, produced a 1179 × 2556 screenshot, increased the actual tap counter from 0 to 1, and confirmed media release. Complete model-driven tasks, dragging, and sustained background execution over VPN loopback still require separate acceptance testing.
- Audio and picture-in-picture modes are available for background execution, but system suspension, termination, screen locking, or connection failures can still stop tasks. Background reliability has not been broadly validated. The older ScreenCaptureKit/PA3 USB HID and TLS implementations remain in the repository; there is currently no switch to select the older route.

These statements reflect the current source and validation records in the project. Results from different routes, devices, and historical stages are not interchangeable. See [project tasks and validation](docs/PROJECT-TODOS.md), [video geometry and frame completeness](docs/ncm-coredevice/VIDEO-GEOMETRY.md), and [VPN loopback setup and validation](docs/ncm-coredevice/LOCALDEVVPN.md).

## Setup and running

The current minimum deployment target is **iOS 26.5**, and builds use **Xcode 27**. The CoreDevice routes are available on iOS 26.5; the older ScreenCaptureKit route requires iOS 27. Configure your own valid signing for a physical device; the unsigned build below only produces artifacts and cannot be installed directly. Model-driven tasks require your own compatible provider, model, and credentials. Screenshots and explicitly sent attachments are transmitted to the selected model.

Prerequisites for device control:

1. Enable Developer Mode on the iPhone and allow local network access for the app. Follow the app's pairing flow and complete trust/PIN pairing in the system UI. Both routes share the RemotePairing identity stored in the app sandbox.
2. Prepare a matching Personalized Developer Disk Image (DDI), usually through Xcode. The current backend only checks Developer Mode and image availability; it does not download, personalize, or mount the image. This repository does not include Apple developer images, and initial setup cannot be guaranteed to work entirely without a Mac.
3. Choose a route under Settings → Phone Control → Connection Mode, then open Connection & Validation to connect, capture a screenshot, and verify an actual tap:
   - **VPN loopback (default, no ESP32 required):** Enable a VPN on the same iPhone that supports reinjecting local packets; this has been verified with [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN). Edit the interface and peer addresses on the control screen. Their defaults are `10.7.1.1` and `10.7.0.1`, respectively, and must match the external VPN configuration. The app does not install, start, or stop the VPN. See the [route documentation](docs/ncm-coredevice/LOCALDEVVPN.md).
   - **ESP32 NCM:** Use an ESP32-S3 with native USB Device support and a data cable. Install the current NCM firmware and connect its native USB port to the iPhone. Verify USB roles, board wiring, and power against the actual hardware. See the [firmware documentation](firmware-device/README.md) and [hardware notes](docs/hardware/ESP32-S3-USB.md).
4. Add a provider in Settings and create a conversation. Regular chat does not require a device connection; control tools still check identity, connection, and authorization when executing. The control route cannot be switched during execution.

### Build

Run all commands below from the repository root. The scripts reuse a local toolchain and are not ready-to-use installers:

- Install Rust with the `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`). The script discovers Rust through PATH or the standard Cargo installation; `NCM_RUST_TOOLCHAIN` optionally selects an installed toolchain. It does not depend on a sibling project. Backend builds use `--locked` and the standard Cargo cache (or `CARGO_HOME` / `NCM_CARGO_HOME`); the first build can download dependencies. Set `NCM_CARGO_OFFLINE=1` for cached offline builds. The package uses edition 2024; versions are in [Cargo.lock](ncm-dev/rust/Cargo.lock).
- Firmware uses ESP-IDF 5.5.5. Set `IDF_PATH` and `IDF_TOOLS_PATH` to an installed environment as needed. Component versions are pinned by the [manifest](firmware-device/main/idf_component.yml) and lockfile.
- The Xcode project is checked in; `ios-app/project.yml` is the source of truth for the app display name. The generator requires PyYAML (pinned in `ios-app/scripts/requirements-qa.txt`); if it is missing, install it with `python3 -m pip install 'PyYAML==6.0.2'`, then run `python3 ios-app/scripts/generate_xcode_project.py` after adding source files. Swift Package Manager may resolve dependencies on the first build; Xcode builds the Rust static library for the selected platform.

```sh
# Unsigned iPhoneOS build; does not install or change signing
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO build

# ESP32 route: build NCM firmware only; does not flash automatically
bash tools/build_usb_device.sh ncm
```

To install on a physical device, select signing and the device in Xcode, then run. See the [iOS documentation](ios-app/README.md) for additional app configuration and build commands using cached dependencies. Firmware artifacts are under `.build/device-ncm/`; verify the serial port and hardware before flashing.

### Validation

```sh
CC=clang bash tools/test_usb_device.sh
bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
RUN_UI_TESTS=1 bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
```

Protocol tests use loopback networking. App tests use synthetic models and temporary storage, and do not replace physical-device acceptance testing. UI tests add test images and files to the specified isolated simulator. Coverage for core protocols, one-time authorization, session isolation, no replay of uncertain outcomes, checkpoint migration, and stop/release behavior remains in the default target.

GitHub Actions checks project generation, Swift source grammar, and protocol fixtures on Linux; the Xcode 27 macOS runner runs USB Device loopback, the unsigned build, and core plus UI simulator tests. The current result is shown by the CI badge above.

## Dependencies and sources

| Project | Current usage |
| --- | --- |
| [SwiftAgentKit](https://github.com/ayman3000/SwiftAgentKit) | Local source snapshot of the agent core and macros, with iOS storage compatibility patches; does not include the upstream MCP module |
| [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) / [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | Swift Package dependencies for model calls and Markdown message rendering, respectively |
| [idevice](https://github.com/jkcoxson/idevice) / [Device Hub](https://github.com/JaviSoto/device-hub-ios) | Reuses the patched idevice source and PNG validator pinned by Device Hub, with local adaptations; does not integrate the entire Device Hub app |
| [ManifoldKit](https://github.com/ManifoldKit/ManifoldKit) | Selected and adapted tool-call presentation components, not a package dependency on the entire framework |
| [ESP-IDF](https://github.com/espressif/esp-idf/tree/v5.5.5), [esp_tinyusb](https://github.com/espressif/esp-usb), [TinyUSB](https://github.com/hathach/tinyusb) | ESP32 firmware toolchain and USB components; pinned to ESP-IDF 5.5.5, esp_tinyusb 2.2.0, and TinyUSB 0.21.0~2 |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | Protocol schema reference and selective translation; pinned reference files support offline tests. It is not a Python service running on the phone or ESP32 |
| [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | Verified external VPN loopback implementation; its Network Extension implementation is not copied into this repository |

Other direct and transitive Rust dependencies are listed in [Cargo.toml](ncm-dev/rust/Cargo.toml) and [Cargo.lock](ncm-dev/rust/Cargo.lock). Pinned Swift versions are in [Package.resolved](ios-app/PhoneAgent.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved). [idevice_pair](https://github.com/jkcoxson/idevice_pair) and [rPlayHub](https://github.com/rPlayAI/rPlayHub) are protocol research references, not current runtime dependencies. Historical USB Host sources likewise do not imply dependencies of the current NCM backend.

Existing license and attribution records are in [LICENSE](LICENSE), [THIRD_PARTY.md](THIRD_PARTY.md), [iOS licenses](ios-app/Licenses/), [SwiftAgentKit snapshot notes](ios-app/Vendor/SwiftAgentKit/README.md), [ManifoldKit extraction notes](ios-app/Vendor/ManifoldPresentation/README.md), and [CoreDevice reuse boundaries](docs/ncm-coredevice/REUSE.md).

## Repository layout and further reading

| Path | Purpose |
| --- | --- |
| `ios-app/` | PhoneAgent app, tests, and project generation scripts |
| `firmware-device/` | Current USB Device NCM firmware and retained HID mode |
| `ncm-dev/` | Shared Swift/C/Rust CoreDevice backend, protocol modules, and standalone probes |
| `tests/usb_device/` | Local test fixtures for the production USB Device protocol |
| `tools/` | Build and validation scripts |
| `docs/` | Current route documentation, diagnostics, and validation records; read historical descriptions in their dated context |
| `archives/` | Historical documentation and archived non-core tests |
| `firmware/` | Retained older USB Host experiments, not the current default firmware |

- [Main project integration](docs/ncm-coredevice/MAIN-INTEGRATION.md) · [System pairing records](docs/ncm-coredevice/PAIRING.md)
- [Background execution diagnostics](docs/BACKGROUND-RUN-RECOVERY.md) · [Control session stop and release](docs/CONTROL-SESSION-TEARDOWN.md)
- [PA3 protocol](docs/usb-device/PROTOCOL.md) · [Historical archive index](archives/README.md)
