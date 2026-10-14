# PhoneAgent iOS

最低 iOS 26.5，Bundle ID 保持 `com.ja1chen.PhoneAgent`。截图与输入工具默认经 VPN 回环调用 CoreDevice 开发者服务执行；连接只在实际工具调用时校验，普通聊天不要求连接。手机操控支持在“设置 → 手机操控 → 连接模式”选择 VPN 回环（默认，免 ESP32）或 ESP32 NCM，在“连接与验证”中操作；首页和消息页不再显示设备入口。原 ScreenCaptureKit/PA3 HID 和 TLS 实现保留，暂未提供切换开关；ScreenCaptureKit 全屏采集仅在 iOS 27 或以上可用。NCM 任务在系统后台资格有效时可继续，无需启动录屏；各会话独立运行，同一手机控制按整轮排队。服务商管理位于“设置 → 服务商”，支持添加、编辑、确认移除及恢复。会话选择服务商/模型，当前运行不允许切换配置。现有单服务商配置与 Keychain 引用自动保留；修改服务地址不会转发旧地址的密钥。已保存的 API 密钥在编辑页以正常文字色的圆点显示，仅查询存在状态，不回填真实值；不输入替换值时保留原密钥。

真实模型使用 screenshot / tap / drag / wait 设备工具，最终文字回复结束本轮。启用用户导入的技能后，系统提示词包含已启用技能的名称、描述、id 和 revision；额外提供 load_skill，只按需读取该技能包的文本。同一响应可含多个工具，按返回顺序串行执行；每个动作仍须经过原有授权、截图与故障检查，ID 不得重复或重用。模型调用数、输入数、累计 token 与固定运行时长不再作为产品预算。图像/协议大小、网络故障、系统后台资格、锁屏、手动停止、未知动作不重放仍然生效。App 不保证系统无限后台执行。

输入区支持系统照片／文件选择、预览与移除；仅显式发送时传给所选模型。截图与消息图片可保存原图并在重启后查看；历史资源不恢复设备授权。设置内可管理用户主动导入的 SKILL.md／文本技能包，导入不执行脚本。服务商支持模型发现、能力缓存和每模型参数；添加时先选择 OpenAI、OpenRouter 或自定义供应商，预设填入名称和地址、自定义留空；编辑页固定供应商类型并可选择 Chat Completions 或 Responses API。未设置默认模型时，自动选用列表中首个模型；已有默认选择保留。模型行仅以小图标展示明确支持的图片输入、工具调用、思考和文本生成能力，未知或不支持时隐藏；图标保留辅助功能说明。旧 Anthropic、Gemini、Ollama 配置仍可读取，使用当前类型需另行添加供应商。供应商、模型和思考强度统一在“设置 → 模型”中选择，聊天输入区仅保留附件、文字输入和发送。设置中的选择会在本机保存，新会话默认使用该选择，已有会话保留自己的选择。新建会话在首条消息发送前仅作为临时草稿，不进入列表或磁盘历史；返回列表会丢弃未发送草稿。详细范围和验收见 [本次证据](../docs/PROJECT-TODOS.md)。

服务商明确返回的可读思考内容／摘要会在消息中单独折叠展示，支持流式状态、取消／失败后保留以及历史恢复。Chat Completions 解析 reasoning_content、reasoning 和可读 reasoning_details；Responses 展示明确返回的 summary 或 reasoning_text content（包括 DeepSeek 思考流事件），并将 encrypted_content 仅用于同域回放；不生成思考正文，不解释加密块，不从普通回复抽取，也不自动把历史思考发送到新任务。

## 构建

使用已安装 Xcode 27，不更改本机签名。显示名以 `project.yml` 的 `settings.base.APP_DISPLAY_NAME` 为准；生成脚本依赖 PyYAML（版本锁定在 `scripts/requirements-qa.txt`），缺少时执行 `python3 -m pip install 'PyYAML==6.0.2'`，新增源文件后从仓库根目录运行 `python3 ios-app/scripts/generate_xcode_project.py`。构建缓存放 `.build/`，可使用已解析依赖的独立副本。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -destination 'generic/platform=iOS' -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions 在真机构建后导出 `ios-device-unsigned` 产物（`PhoneAgent-unsigned.tar.gz`），便于下载到本机签名。安装包中的主 App 和每个扩展都必须有匹配的描述文件；只有单 App ID 的描述文件时，可生成不包含 Live Activity 扩展的安装测试包，该包不提供实时活动展示。证书、私钥和密码不进入代码仓库。

## 测试

```sh
CC=clang bash tools/test_usb_device.sh
bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
RUN_UI_TESTS=1 bash ios-app/scripts/test_core.sh <隔离模拟器-UDID>
```

测试使用合成模型、临时持久化目录和回环 USB peer；无真实凭据/设备动作。UI 模式会向指定的独立模拟器添加一张合成图片及 `ProjectTodosFixtures` 文件，用于系统选择器；只运行定向 UI 用例前可先执行 `python3 ios-app/scripts/prepare_ui_fixtures.py <UDID>`。默认 target 保留所有核心协议、审批、隔离、迁移、捕获和停止释放用例。可选归档用例与恢复方式见 [归档入口](../archives/README.md)。历史日期、旧测试计数不代表本次验收，最新结果见 [本次证据](../docs/PROJECT-TODOS.md)。

## 手机操控设置子页面

“随办硬件v1”提供 USB 接线与操控检查、纯蓝牙键鼠输入验收及最近 20 条连接记录。硬件 Wi-Fi 配网、热点和路由器通道已按用户要求移除；手机自身的 Wi-Fi／蜂窝网络继续用于模型联网。

首页和会话列表顶部提供统一的「连接随办硬件」入口，可查看 USB／蓝牙的实时状态并进入原硬件页面。USB 已验证时优先显示有线操控状态；蓝牙单独连接只显示输入检查状态。点击入口仅打开页面，不自动连接、切换通道或发送动作；USB 用户无需先完成蓝牙配对。

蓝牙输入需在系统辅助触控中配对键鼠，再由 App 验证硬件身份和双向通信。BH1 使用有限租约、回执去重及共享输入门，未知动作不重发。蓝牙键鼠页面提供“一键检查鼠标”，自动进入随办自己的非滚动测试画布，执行有限的相对移动、两次单击和停止；保持手机解锁，测试期间不要用手触碰屏幕，可随时停止。键盘与手动鼠标检查收起在高级调试入口中。

板子被系统识别为外接键盘时，屏幕键盘可能不再自动显示。需要同时手动打字时，在「设置 → 辅助功能 → 触控 → 辅助触控」开启「显示屏幕键盘」；这是系统选项，App 不修改或锁定输入法。参见 [Apple 官方说明](https://support.apple.com/zh-cn/111775)。

鼠标验收条件为：画布的实际 UI 事件恰好收到两次点击，两个事件的本地坐标距离至少为 20 个界面点，随后收到 BH1 STOP 的 `neutral_sent` 回执，并在 500 毫秒观察期内未收到额外画布点击。点击位置只取自实际 UI 事件，不由发送报告推算；相对鼠标报告不视为屏幕像素坐标。回执仅证明报告发送，不能代替真实点击证据，也不直接证明系统全部输入状态。未命中、次数异常或结果未知时停止，本轮不自动重试动作；切到后台或离开测试页也停止并释放。

开发侧可在 DEBUG 构建中用 `--hardware-hid-auto-verification --hardware-board-id <12位硬件ID>` 启动独立根测试页，连接已记住的指定板子并核对身份后自动执行；普通用户入口不要求启动参数。开发者可由 Mac 启动并读取页面、`hardware-hid-mouse-verification.log` 的实际事件及结果、`hardware-hid-verification.log` 的 BH1 回执完成真机取证。完整纯蓝牙 AI 闭环仍需跨 App 屏幕采集签名与指针定位验收；当前签名不足时显示不可用。实际设备结果见 [本次证据](../docs/PROJECT-TODOS.md)。

两种模式共用 App 内的系统配对身份；切换释放旧连接并重新认证，运行中禁止切换。VPN 回环在建立连接阶段需要处于 Wi-Fi 环境，需由用户先启用支持本机数据包回注的外部 VPN，控制页可编辑接口与对端 IPv4 地址（默认 10.7.1.1、10.7.0.1）；接口地址支持从下拉菜单选择 10.7.1.1 或 198.18.0.1，对端地址候选为 10.7.0.1；两个菜单均提供「自定义」，点击会激活对应输入框，也可直接编辑，有修改时导航栏右上角显示「保存」；App 不管理外部 VPN，已在 iPhone 15 Pro 验证复用身份、截图和实际点击，拖动/后台仍待单独验收，见 [使用与验证](../docs/ncm-coredevice/LOCALDEVVPN.md)。

页面提供系统配对、连接/停止、截图和真实点击计数验证；文件位于 `PhoneAgent/ESP32Control`。主 App 编译复用 `../ncm-dev/PhoneAgentNCM` 的 Swift/C ABI 和 Rust 后端，构建阶段自动生成当前平台的静态库，支持 arm64 真机和 arm64 模拟器。Probe 共用同一界面。

配对使用独立 `.pairing` 系统持续任务；设置 → 后台执行可选音频（默认）、画中画或系统后台任务；选择系统后台任务后，普通任务申请系统持续执行，并用系统短时后台任务衔接申请过程，无需启动录屏。系统会显示自己的进度活动，可能占用灵动岛；不会只因请求提交成功就视为已授予资格。后台常驻仍以音频等待新任务，不为空闲状态反复申请系统持续任务。有效任务保留认证连接；后台资格到期、受保护数据不可用或连接故障时停止。空闲连接进入后台时关闭。主 App 沙盒中的身份随更新保留，不读取或导出 Probe 的身份。切换或退出会话页面不取消执行；各会话独立保存 Agent、模型请求、审批、检查点与实时活动。同一台手机的 NCM 控制任务按整轮排队，等待任务取消不撤销当前设备所有者。截图复用已有认证会话，状态维持“已连接”，仅截图按钮显示操作进度。

固件使用 `bash tools/build_usb_device.sh ncm`；主任务 screenshot/tap/drag 已切换到新开发者后端，旧链路保留在统一路由选择入口。详见 [主工程整合](../docs/ncm-coredevice/MAIN-INTEGRATION.md)。Siri 与旧系统集成历史见 [归档文档](../archives/history/ios-app/docs/SIRI-ENTRY.md)。

## Siri 执行任务

“执行任务” App Intent 收到任务文本后直接调用现有任务启动路径，不再等待 App 内确认。启动失败在 App 中显示具体原因，并保留草稿供检查；相同命令 ID 的已提交任务不会重放。设备授权、锁屏和停止机制继续生效。

该入口采用 `LiveActivityIntent`，支持后台执行并在需要时请求前台继续，为新会话绑定默认服务商。App 曾进入前台、保护数据可用且实际媒体保活有效时，可以直接在后台提交任务；否则请求前台继续。任务成功提交后，Intent 等待已排队的实时活动请求处理完再返回，以在 Intent 执行期间申请后台实时活动。实时活动创建失败不重复执行任务，也不提供额外后台执行时间或 PiP 启动权限。当前进程内的交接队列可在前台就绪后自动启动，不要求再次确认；重启不会自动启动旧草稿。Apple App Shortcut 的调用短语不支持任意自由文本参数，因此“用随办执行任务”缺少参数时仍由 Siri 询问任务内容。需要一句话执行固定任务时，可在系统“快捷指令”中新建快捷指令，添加随办的“执行任务”操作、预填任务文本，再通过该快捷指令名称唤起 Siri。

## Provider 边界

已用自有 ProviderCore 与远程 SPM MacPaw/OpenAI 0.5.2 替换旧 Kit。SDK 源码未复制入工程。设置可选择 Chat Completions 或 Responses；原配置保持 Chat 默认。Responses 默认本地回放/store=false，明确选择服务端响应链后才使用 store=true/previous_response_id；续接仅限当前任务，每轮重发 instructions。旧截图不再上传不等于远端历史已删除。OpenRouter 保留 Chat 默认，也可显式使用无状态 Responses；其 store=true/previous_response_id 在本地拒绝。服务商类型与 wire 协议独立。其他原生协议推理、Conversations、background、compaction 和 hosted tools 尚未启用。细节与验证边界见 [Provider 模块](ProviderKit/README.md)。

## ChatGPT 订阅配置与思考强度

新增供应商预设顺序为 OpenAI、OpenRouter、ChatGPT 订阅、自定义。订阅配置固定官方地址与无状态 Responses，不接收 API Key。Continue with ChatGPT 使用系统认证浏览器与 HTTP 回环授权，校验官方 JWKS 身份后保存账号隔离的本机 Keychain 凭据。仅获套餐授权的账号模型使用独立订阅流式 Responses；退出尝试官方 discovery 撤销端点并清理本地 token。全部开发验证只用本地 mock，真实账号授权、实体设备与订阅计费尚未验证。完整官方能力与验证边界见 [订阅整合说明](../docs/CHATGPT-SUBSCRIPTION.md)。

每服务商／模型可保存思考强度；仅显示明确报告或官方文档确认的档位，未知模型使用默认、不猜档位。Responses 映射 reasoning.effort，Chat Completions 映射 reasoning_effort。GPT-6.1 Sol 的文档档位只用于官方地址的 Responses 配置，不推广到代理或未知模型。
