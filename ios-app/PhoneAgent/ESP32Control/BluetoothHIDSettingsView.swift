// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import ReplayKit
import UIKit

@MainActor struct BluetoothHIDSettingsView: View {
    @ObservedObject private var bluetooth = BluetoothBoardFlow.shared
    @ObservedObject private var hid = BluetoothHIDTransport.shared
    @ObservedObject private var capture = ReplayKitBroadcastCapture.shared
    @State private var control = PairingFlow.shared
    @State private var showingTest = false
    @State private var showingMouseTest = false
    @State private var error: String?
    var body: some View {
        Form {
            if control.running || control.ready || control.agentReserved {
                Section {
                    Text("先停止当前手机操控连接，再连接或验收蓝牙输入。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(control.route == .ncmDeveloper ? "停止 USB 操控连接" : "停止当前手机操控连接", role: .destructive) {
                        control.cancel()
                    }
                } header: { Text("停止当前操控") }
            }
            Section {
                Label(bluetooth.connected ? "硬件蓝牙已连接" : "硬件蓝牙未连接", systemImage: "antenna.radiowaves.left.and.right")
                if bluetooth.connected { LabeledContent("硬件", value: bluetooth.boardName) }
                Text(bluetooth.message).font(.footnote).foregroundStyle(.secondary)
                if !bluetooth.connected {
                    Button(bluetooth.connecting ? "正在连接" : "连接我的硬件") {
                        if bluetooth.rememberedPeripheralID != nil { bluetooth.reconnectRemembered() }
                        else { bluetooth.scan() }
                    }.disabled(bluetooth.connecting || !control.canChangeRoute)
                    ForEach(bluetooth.devices) { device in
                        Button(device.name) { bluetooth.connect(device) }
                            .disabled(bluetooth.connecting || !control.canChangeRoute)
                    }
                }
                Text(hid.status).font(.footnote).foregroundStyle(.secondary)
            } header: { Text("蓝牙输入连接") } footer: {
                Text("App 通过蓝牙给硬件发命令，硬件通过蓝牙键鼠向手机输入。")
            }
            Section {
                Text("打开系统设置 → 辅助功能 → 触控 → 辅助触控，开启辅助触控，在「设备 → 蓝牙设备」中配对随办硬件。")
                Text("同时开启「显示屏幕键盘」，保留手动打字。App 不会修改你的系统输入法。")
                Text("将鼠标主按钮设为单击。测试时关闭停留控制和拖移锁定，并保持跟踪灵敏度不变。")
                Button("一键检查鼠标") {
                    control.cancel()
                    showingMouseTest = true
                }.disabled(!bluetooth.connected || !hid.supported || !control.canChangeRoute)
                    .accessibilityIdentifier("openBluetoothHIDVerification")
                DisclosureGroup("键盘与手动调试") {
                    Button("打开输入测试页") {
                        control.cancel()
                        showingTest = true
                    }.disabled(!bluetooth.connected || !hid.supported || !control.canChangeRoute)
                }
            } header: { Text("系统键鼠与实际输入") } footer: {
                Text("开始验收会停止当前手机操控连接。指令回执只证明报告发送，实际点击和输入要以测试页结果为准。")
            }
            Section {
                Text(capture.status).font(.footnote).foregroundStyle(.secondary)
                if capture.isSupported {
                    if !capture.active && !capture.busy {
                        Button("准备屏幕广播") {
                            do { try capture.prepareBroadcast(); error = nil }
                            catch { self.error = "无法准备屏幕采集，请检查系统授权" }
                        }
                    } else {
                        if let identifier = capture.broadcastExtensionIdentifier {
                            HIDScreenshotBroadcastPicker(identifier: identifier)
                                .frame(width: 48, height: 48).accessibilityLabel("系统屏幕广播按钮")
                        }
                        Button("停止屏幕采集", role: .destructive) {
                            capture.stop()
                            Task { await hid.stopAll() }
                        }
                    }
                } else {
                    Text("当前安装包未提供可用的屏幕采集扩展，可先验收蓝牙键鼠；跨 App 自动执行暂未启用。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            } header: { Text("手机屏幕采集") } footer: {
                Text("系统广播需你确认开始。画面在手机端采集，按任务需要发送给所选模型，截图不经过硬件蓝牙。保持手机解锁。")
            }
            Section {
                Text("蓝牙键鼠、跨 App 新画面、指针定位和停止释放全部通过后，才启用模型自动点击。当前不会把鼠标相对位移直接当成屏幕坐标。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("自动执行准备") }
        }
        .navigationTitle("蓝牙键鼠")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingTest) { BluetoothHIDVerificationView() }
        .fullScreenCover(isPresented: $showingMouseTest) { BluetoothHIDMouseVerificationView(autoStart: true) }
        .onDisappear { bluetooth.stopScan() }
    }
}

private struct HIDScreenshotBroadcastPicker: UIViewRepresentable {
    let identifier: String
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        view.preferredExtension = identifier; view.showsMicrophoneButton = false
        return view
    }
    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {
        view.preferredExtension = identifier
    }
}

/// This page changes the counter only through the target's actual UI action.
/// Relative motion is intentionally not exposed as a model's absolute tap.
@MainActor struct BluetoothHIDVerificationView: View {
    @ObservedObject private var hid = BluetoothHIDTransport.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var lease: BluetoothHIDSession?
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var clicks = 0
    @State private var text = ""
    @State private var result = "先完成系统蓝牙键鼠配对。测试时不要用手触碰中央目标。"
    @State private var stopping = false
    @State private var showingMouseTest = false
    @FocusState private var textFocused: Bool
    private var canSend: Bool { operation == nil && !stopping && hid.supported }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("这里仅操作随办自己的测试页").font(.footnote).foregroundStyle(.secondary)
                    Button { clicks += 1 } label: {
                        VStack {
                            Text("真实点击目标").font(.headline)
                            Text("收到点击：\(clicks)").monospacedDigit()
                        }.frame(width: 240, height: 116)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("bluetoothHIDClickTarget")
                    Text(result).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("bluetoothHIDTestResult")
                    Button("一键测试鼠标") {
                        stop()
                        showingMouseTest = true
                    }.buttonStyle(.borderedProminent).disabled(!canSend)
                    Text("自动移动、点击两次并释放，无需手动对准目标。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("手动检查鼠标") {
                    HStack {
                        direction("左", dx: -20, dy: 0)
                        direction("上", dx: 0, dy: -20)
                        direction("下", dx: 0, dy: 20)
                        direction("右", dx: 20, dy: 0)
                    }
                    Button("单击当前指针位置") {
                        let baseline = clicks
                        run("正在发送一次单击") { session in
                            try await hid.mouse(session, dx: 0, dy: 0, buttons: 1)
                            try await Task.sleep(for: .milliseconds(60))
                            try await hid.mouse(session, dx: 0, dy: 0)
                            try await Task.sleep(for: .milliseconds(600))
                            return clicks == baseline + 1 ? "本页实际收到且仅收到一次目标点击。" :
                                "报告已发送，但目标计数未恰好增加一次。请检查指针位置；没有自动重试。"
                        }
                    }.disabled(!canSend)
                    HStack {
                        Button("向上滚动") { scroll(1) }
                        Button("向下滚动") { scroll(-1) }
                    }.disabled(!canSend)
                    }
                    TextField("键盘测试结果", text: $text).textFieldStyle(.roundedBorder)
                        .focused($textFocused).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("bluetoothHIDKeyboardField")
                    Button("测试英文键盘：suiban123") {
                        text = ""; textFocused = true
                        run("正在验证英文键盘") { session in
                            try await Task.sleep(for: .milliseconds(250))
                            for key in [22, 24, 12, 5, 4, 17, 30, 31, 32] {
                                try Task.checkCancellation()
                                try await hid.keyboard(session, keys: [key])
                                try await hid.keyboard(session, keys: [])
                                try await Task.sleep(for: .milliseconds(40))
                            }
                            try await Task.sleep(for: .milliseconds(400))
                            return text == "suiban123" ? "编辑框实际收到正确英文测试串。" :
                                "报告已发送，但文字不匹配。请检查英文输入法与大小写锁定；没有自动重试。"
                        }
                    }.disabled(!canSend)
                    Button("复制中文并测试粘贴") {
                        text = ""; textFocused = true
                        UIPasteboard.general.string = "随办蓝牙测试"
                        run("正在验证中文粘贴") { session in
                            try await Task.sleep(for: .milliseconds(250))
                            try await hid.keyboard(session, modifiers: 8, keys: [25])
                            try await hid.keyboard(session, keys: [])
                            try await Task.sleep(for: .milliseconds(600))
                            return text == "随办蓝牙测试" ? "编辑框实际收到完整中文测试串。" :
                                "中文粘贴未确认，请处理系统提示或检查焦点；没有自动重试。"
                        }
                    }.disabled(!canSend)
                    Text("中文测试会把剪贴板替换为非敏感测试文字，不读取原剪贴板。系统可能要求你确认粘贴。英文测试请切换英文输入法并关闭大小写锁定。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(1...12, id: \.self) { index in
                        Text("滚动验证行 \(index)").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                    }
                }.padding()
            }
            .navigationTitle("蓝牙实际输入验收")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(stopping ? "正在释放" : "停止并释放", role: .destructive, action: stop)
                        .disabled(stopping)
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
            .onDisappear(perform: stop)
            .fullScreenCover(isPresented: $showingMouseTest) {
                BluetoothHIDMouseVerificationView(autoStart: false)
            }
        }
    }
    private func direction(_ name: String, dx: Int, dy: Int) -> some View {
        Button(name) {
            run("正在发送\(name)移报告") { session in
                try await hid.mouse(session, dx: dx, dy: dy)
                return "相对移动报告已发送，请观察指针是否向\(name)移动；这不是屏幕像素坐标。"
            }
        }.buttonStyle(.bordered).disabled(!canSend)
    }
    private func scroll(_ wheel: Int) {
        run("正在发送滚轮报告") { session in
            try await hid.mouse(session, dx: 0, dy: 0, wheel: wheel)
            return "滚轮报告已发送，请观察本页内容是否实际滚动。"
        }
    }
    private func run(_ label: String, action: @escaping @MainActor (BluetoothHIDSession) async throws -> String) {
        guard canSend else { return }
        let token = UUID(); generation = token; result = label
        let initialLease = lease
        operation = Task {
            var owned = initialLease
            do {
                let current: BluetoothHIDSession
                if let initialLease { current = initialLease }
                else { current = try await hid.openInputSession() }
                owned = current
                guard generation == token, !Task.isCancelled else { await hid.stopInputs(current); return }
                lease = current
                let message = try await action(current)
                guard generation == token, !Task.isCancelled else { return }
                result = message; operation = nil
            } catch {
                if let owned { await hid.stopInputs(owned) }
                guard generation == token else { return }
                lease = nil; result = (error as? AppError)?.localizedDescription ?? "输入测试已停止，请重新连接后检查"
                operation = nil
            }
        }
    }
    private func stop() {
        guard !stopping else { return }
        let token = UUID(); generation = token; operation?.cancel(); operation = nil
        let old = lease; lease = nil; stopping = true; result = "正在停止并释放所有键鼠按钮"
        Task {
            if let old { await hid.stopInputs(old) }
            else { await hid.stopAll() }
            guard generation == token else { return }
            stopping = false; result = hid.status
        }
    }
}

/// Only actual tap events may update the samples. Relative reports are never
/// converted into screen coordinates, and a missed/unknown click is not retried.
@MainActor struct BluetoothHIDMouseVerificationView: View {
    let autoStart: Bool
    @ObservedObject private var bluetooth = BluetoothBoardFlow.shared
    @ObservedObject private var hid = BluetoothHIDTransport.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var operation: Task<Void, Never>?
    @State private var session: BluetoothHIDSession?
    @State private var generation = UUID()
    @State private var samples: [CGPoint] = []
    @State private var acceptingClick = false
    @State private var unexpectedClicks = 0
    @State private var running = false
    @State private var stopping = false
    @State private var started = false
    @State private var foregroundActive = false
    @State private var showingConnection = false
    @State private var result = "按开始后，请不要用手触碰屏幕。"
    @State private var records: [String] = []

    var body: some View {
        ZStack {
            Color.blue.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    guard running else { return }
                    if acceptingClick {
                        samples.append(point)
                        record(String(format: "ui.tap count=%d x=%.1f y=%.1f", samples.count, point.x, point.y))
                    } else {
                        unexpectedClicks += 1
                        record(String(format: "ui.unexpected_tap count=%d x=%.1f y=%.1f", unexpectedClicks, point.x, point.y))
                    }
                }
            VStack(spacing: 18) {
                Text("鼠标自动测试").font(.title2.bold())
                Text("只操作此测试页").font(.footnote).foregroundStyle(.secondary)
                Label(bluetooth.connected ? "随办硬件已连接" : bluetooth.connecting ? "正在连接随办硬件" : "随办硬件未连接",
                      systemImage: bluetooth.connected ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "cursorarrow.motionlines").font(.system(size: 38)).foregroundStyle(.blue)
                Text("实际收到点击：\(samples.count) / 2").font(.title3).monospacedDigit()
                Text(result).font(.body).multilineTextAlignment(.center)
                Text("自动移动、真实点击、自动释放。\n测试期间请勿触碰屏幕。")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }.padding(28).allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("关闭") { stop(); dismiss() }.disabled(running || stopping)
                Spacer()
                if running || stopping {
                    Button(stopping ? "正在释放" : "停止测试", role: .destructive, action: stop)
                        .disabled(stopping)
                } else {
                    if !bluetooth.connected {
                        Button("连接随办硬件") { showingConnection = true }.buttonStyle(.borderedProminent)
                    } else {
                        Button("开始自动测试", action: start).buttonStyle(.borderedProminent)
                    }
                }
            }.padding().background(.regularMaterial)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // An async task captures its View's Environment values. Keep this
            // foreground gate in State so the task reads subsequent transitions.
            foregroundActive = phase == .active
            if phase != .active { stop() }
            else if autoStart && !started { start() }
        }
        .sheet(isPresented: $showingConnection) { NavigationStack { BluetoothHIDSettingsView() } }
        .onDisappear(perform: stop)
    }

    private func record(_ value: String) {
        records.append(Date().ISO8601Format() + " " + value)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--hardware-hid-auto-verification") {
            let url = URL.documentsDirectory.appending(path: "hardware-hid-mouse-verification.log")
            try? Data((records.joined(separator: "\n") + "\n").utf8)
                .write(to: url, options: [.atomic, .completeFileProtection])
        }
        #endif
    }
    private func requireActive(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw AppError.stopped }
        guard foregroundActive, !showingConnection, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else {
            throw AppError.unavailable("手机未在测试页前台或已锁定，本轮停止")
        }
        guard !PhoneAgentRuntime.shared.model.hasBusySessions, !PairingFlow.shared.agentReserved else {
            throw AppError.unavailable("已有任务占用手机，本轮停止")
        }
        guard unexpectedClicks == 0 else {
            throw AppError.unavailable("测试页收到非测试点击，本轮停止；请检查停留控制或屏幕触碰")
        }
    }
    private func recordReadiness() {
        record("readiness env_phase=\(scenePhase) foreground=\(foregroundActive) app_state=\(UIApplication.shared.applicationState.rawValue) protected=\(UIApplication.shared.isProtectedDataAvailable) model_busy=\(PhoneAgentRuntime.shared.model.hasBusySessions) reserved=\(PairingFlow.shared.agentReserved) connected=\(bluetooth.connected) supported=\(hid.supported) hid_busy=\(hid.busy)")
    }
    private func start() {
        guard operation == nil, !running, !stopping, !PhoneAgentRuntime.shared.model.hasBusySessions,
              !PairingFlow.shared.agentReserved else { return }
        started = true
        let token = UUID(); generation = token
        samples = []; unexpectedClicks = 0; records = []; acceptingClick = false
        running = true; result = "正在准备蓝牙输入"; record("test.begin")
        recordReadiness()
        PairingFlow.shared.cancel()
        operation = Task {
            var owned: BluetoothHIDSession?
            do {
                if !bluetooth.connected && !bluetooth.connecting { bluetooth.reconnectRemembered() }
                let deadline = ContinuousClock.now.advanced(by: .seconds(25))
                while (!bluetooth.connected || !hid.supported || hid.busy || !foregroundActive || UIApplication.shared.applicationState != .active) && ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard generation == token else { throw AppError.stopped }
                    try await Task.sleep(for: .milliseconds(100))
                }
                recordReadiness()
                try requireActive(token)
                guard bluetooth.connected, hid.supported else { throw AppError.unavailable("请连接随办硬件并完成系统键鼠配对") }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--hardware-hid-auto-verification") {
                    let arguments = ProcessInfo.processInfo.arguments
                    guard let index = arguments.firstIndex(of: "--hardware-board-id"), index + 1 < arguments.count,
                          bluetooth.boardID == arguments[index + 1] else { throw AppError.unavailable("测试板子身份不匹配") }
                }
                #endif
                record("connect.verified")
                let lease = try await hid.openInputSession(); owned = lease
                try requireActive(token); session = lease; record("input.begin")
                for sign in [-1, 1] {
                    result = "正在自动移动并点击第 \(samples.count + 1) 个位置"
                    record("motion.corner direction=\(sign)")
                    // Boundary motion is a test gesture, not a coordinate calibration.
                    for _ in 0..<8 {
                        try requireActive(token)
                        try await hid.mouse(lease, dx: sign * 127, dy: sign * 127)
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    for _ in 0..<48 {
                        try requireActive(token)
                        try await hid.mouse(lease, dx: -sign, dy: -sign * 2)
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    try await Task.sleep(for: .milliseconds(250)); try requireActive(token)
                    let baseline = samples.count
                    acceptingClick = true; record("click.begin expected=\(baseline + 1)")
                    try await hid.mouse(lease, dx: 0, dy: 0, buttons: 1)
                    try await Task.sleep(for: .milliseconds(60)); try requireActive(token)
                    try await hid.mouse(lease, dx: 0, dy: 0)
                    try await Task.sleep(for: .milliseconds(600)); try requireActive(token)
                    acceptingClick = false
                    guard samples.count == baseline + 1, unexpectedClicks == 0 else {
                        throw AppError.unavailable("真实点击未确认或次数异常，本轮已停止；没有自动重试")
                    }
                    record("click.confirmed count=\(samples.count)")
                }
                guard samples.count == 2 else { throw AppError.unavailable("实际点击次数不匹配") }
                let distance = hypot(samples[1].x - samples[0].x, samples[1].y - samples[0].y)
                record(String(format: "motion.actual_distance=%.1f", distance))
                guard distance >= 20 else { throw AppError.unavailable("实际点击位置未明显移动，请检查系统鼠标配置") }
                await hid.stopInputs(lease); owned = nil
                try requireActive(token); session = nil
                guard !hid.busy, !hid.inputActive, hid.status == "蓝牙键鼠已释放" else {
                    throw AppError.unavailable("停止回执未确认，请检查硬件")
                }
                record("input.neutral_confirmed")
                try await Task.sleep(for: .milliseconds(500)); try requireActive(token)
                guard samples.count == 2, unexpectedClicks == 0 else { throw AppError.unavailable("释放后出现额外点击") }
                result = "通过：实际移动、两次点击和停止回执均已确认。"
                record("PASS actual_motion actual_clicks=2 stop_neutral no_extra_tap")
            } catch {
                acceptingClick = false
                if let owned { await hid.stopInputs(owned) }
                guard generation == token else { return }
                session = nil
                recordReadiness()
                result = (error as? AppError)?.localizedDescription ?? "测试已停止"
                record("FAIL \(result)")
            }
            guard generation == token else { return }
            acceptingClick = false; running = false; operation = nil
        }
    }
    private func stop() {
        guard !stopping, running || session != nil else { return }
        generation = UUID(); operation?.cancel(); operation = nil
        acceptingClick = false; running = false; stopping = true
        let old = session; session = nil; result = "正在停止并释放"
        record("test.cancelled")
        Task {
            if let old { await hid.stopInputs(old) } else { await hid.stopAll() }
            stopping = false; result = hid.status; record("test.cancelled_release \(hid.status)")
        }
    }
}
