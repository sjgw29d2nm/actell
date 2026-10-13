// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import NetworkExtension

/// The complete configuration is stored only in this app's protected Keychain.
/// Public UI and connection history never contain the passphrase or relay token.
struct HardwareWiFiProfile: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let version: Int
    let id: String
    let ssid: String
    let passphrase: String
    let relay_token: String
    let local_ip: String
    let board_ip: String

    func validate(expectedBoardID: String) throws {
        guard version == 1, id == expectedBoardID, id.utf8.count == 12,
              id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              ssid == "Suiban-v1-\(id.suffix(6))",
              (8...63).contains(passphrase.utf8.count),
              passphrase.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw AppError.invalid("硬件 Wi-Fi 配置不匹配，请重新连接正确的板子")
        }
        _ = try WirelessRelayConfiguration(localAddress: local_ip, boardAddress: board_ip, relayToken: relay_token)
    }
    var relayConfiguration: WirelessRelayConfiguration? {
        try? WirelessRelayConfiguration(localAddress: local_ip, boardAddress: board_ip, relayToken: relay_token)
    }
    var description: String { "HardwareWiFiProfile(id: \(id), ssid: \(ssid), credentials: [REDACTED])" }
    var debugDescription: String { description }
}

@MainActor final class HardwareWiFiFlow: ObservableObject {
    static let shared = HardwareWiFiFlow()
    private static let secretAccount = "suiban-hardware-wifi-v1"
    private static let historyKey = "suibanHardware.connectionHistory.v1"
    struct ConnectionRecord: Codable, Identifiable {
        let id: UUID
        let date: Date
        let boardID: String?
        let transport: String
        let success: Bool
        let message: String
    }
    private struct PendingHotspot {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    @Published private(set) var statusText = "尚未保存硬件 Wi-Fi 配置"
    @Published private(set) var busy = false
    @Published private(set) var joined = false
    @Published private(set) var ssid = ""
    @Published private(set) var boardID = ""
    @Published private(set) var history: [ConnectionRecord] = []
    private var profile: HardwareWiFiProfile?
    private var operationID: UUID?
    private var operation: Task<Void, Never>?
    private var pendingHotspot: PendingHotspot?
    private var hotspotTimer: Task<Void, Never>?
    private var joiningSSID: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey), data.count <= 64 * 1024,
           let records = try? JSONDecoder().decode([ConnectionRecord].self, from: data) {
            history = Array(records.filter { $0.message.count <= 240 && ["USB", "Wi-Fi"].contains($0.transport) }.prefix(20))
        }
        reload()
    }
    var relayConfiguration: WirelessRelayConfiguration? {
        if profile == nil { reload() }
        return profile?.relayConfiguration
    }
    var hasConfiguration: Bool { profile != nil }
    var lastConnectedAt: Date? { history.first(where: \.success)?.date }
    var canConfigure: Bool {
        guard !busy, PairingFlow.shared.canChangeRoute, !BluetoothBoardFlow.shared.busy else { return false }
        do {
            _ = try NCMProbeClient.selectHardwareTransport(wifi: nil)
            return false
        } catch NCMError.interfaceUnavailable {
            return true
        } catch {
            return false
        }
    }
    func reload() {
        guard !busy else { return }
        do {
            guard let value = try SecretStore.load(Self.secretAccount) else {
                profile = nil; ssid = ""; boardID = ""
                return
            }
            guard value.utf8.count <= 2048 else { throw AppError.invalid("保存的硬件配置无效") }
            let saved = try JSONDecoder().decode(HardwareWiFiProfile.self, from: Data(value.utf8))
            try saved.validate(expectedBoardID: saved.id)
            profile = saved; ssid = saved.ssid; boardID = saved.id
            if statusText == "尚未保存硬件 Wi-Fi 配置" { statusText = "配置已保存，可以直接加入硬件 Wi-Fi" }
        } catch {
            profile = nil; ssid = ""; boardID = ""
            statusText = "暂时无法读取硬件配置，请解锁手机；仍失败时重新连接蓝牙读取"
        }
    }
    private func requireConfigurationChangeAllowed() throws {
        guard PairingFlow.shared.canChangeRoute else {
            throw AppError.unavailable("请先停止当前操控或任务，再修改硬件配置")
        }
        do {
            _ = try NCMProbeClient.selectHardwareTransport(wifi: nil)
        } catch NCMError.interfaceUnavailable {
            return
        } catch {
            throw AppError.unavailable("USB 接口状态无效，请拔下手机与硬件之间的 USB 线后重试")
        }
        throw AppError.unavailable("USB 当前优先，请先拔下手机与硬件之间的 USB 线，再配置无线连接")
    }
    func readConfiguration() {
        guard !busy else { return }
        do { try requireConfigurationChangeAllowed() }
        catch { statusText = safeMessage(error); return }
        let bluetooth = BluetoothBoardFlow.shared
        guard bluetooth.connected, !bluetooth.busy else { statusText = "请先连接蓝牙"; return }
        PairingFlow.shared.cancel()
        let id = UUID(); operationID = id; busy = true
        statusText = "读取配置前，请按下板子的 BOOT；按下后 60 秒内读取"
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(id) }
            do {
                let received = try await bluetooth.fetchWiFiConfiguration()
                try Task.checkCancellation()
                guard self.operationID == id else { return }
                try self.requireConfigurationChangeAllowed()
                guard bluetooth.connected, bluetooth.boardID == received.id else { throw CancellationError() }
                try received.validate(expectedBoardID: bluetooth.boardID)
                let data = try JSONEncoder().encode(received)
                guard data.count <= 2048, let value = String(data: data, encoding: .utf8) else { throw AppError.invalid("硬件配置长度无效") }
                try SecretStore.save(value, account: Self.secretAccount)
                self.profile = received; self.ssid = received.ssid; self.boardID = received.id; self.joined = false
                self.statusText = "配置已保存到本机，可以加入硬件 Wi-Fi；之后不必持续连接蓝牙"
            } catch is CancellationError {
                if self.operationID == id { self.statusText = "读取已停止，原配置保留" }
            } catch {
                if self.operationID == id { self.statusText = self.safeMessage(error) }
            }
        }
    }
    func join() {
        guard !busy else { return }
        do { try requireConfigurationChangeAllowed() }
        catch { statusText = safeMessage(error); return }
        reload()
        guard let profile, let configuration = profile.relayConfiguration else {
            statusText = "请先通过蓝牙读取并保存 Wi-Fi 配置"; return
        }
        PairingFlow.shared.cancel()
        let id = UUID(); operationID = id; busy = true; joined = false; joiningSSID = profile.ssid
        statusText = "请在 iPhone 系统提示中确认加入 \(profile.ssid)"
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(id) }
            do {
                try await self.applyHotspot(profile, operationID: id)
                try Task.checkCancellation()
                guard self.operationID == id else { return }
                self.statusText = "正在确认硬件 Wi-Fi 接口"
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                var confirmed = false
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard self.operationID == id else { return }
                    try self.requireConfigurationChangeAllowed()
                    do {
                        let transport = try NCMProbeClient.selectHardwareTransport(wifi: configuration)
                        if case .wifi = transport { confirmed = true; break }
                    } catch NCMError.interfaceUnavailable {
                        // The DHCP/interface may still be appearing after system approval.
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard confirmed else { throw AppError.unavailable("未确认硬件 Wi-Fi 接口，请检查板子供电、手机 Wi-Fi，再重新加入") }
                guard self.operationID == id else { return }
                self.joined = true
                self.statusText = "已确认硬件 Wi-Fi 接口，请点击连接验证；尚未验证手机操控服务"
                self.joiningSSID = nil
            } catch is CancellationError {
                if self.operationID == id { self.statusText = "入网操作已停止；硬件配置仍保存在本机" }
            } catch {
                if self.operationID == id { self.statusText = self.safeMessage(error) }
            }
        }
    }
    private func applyHotspot(_ profile: HardwareWiFiProfile, operationID id: UUID) async throws {
        let configuration = NEHotspotConfiguration(ssid: profile.ssid, passphrase: profile.passphrase, isWEP: false)
        configuration.joinOnce = false
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingHotspot = PendingHotspot(id: id, continuation: continuation)
                hotspotTimer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(45)) } catch { return }
                    self?.finishHotspot(id, .failure(AppError.unavailable("等待系统入网确认超时，请完成或关闭系统提示后重试")))
                }
                NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == id, self.pendingHotspot?.id == id else { return }
                        if let error = error as NSError? {
                            if error.domain == NEHotspotConfigurationErrorDomain,
                               error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                                self.finishHotspot(id, .success(Void()))
                            } else if error.domain == NEHotspotConfigurationErrorDomain,
                                      error.code == NEHotspotConfigurationError.userDenied.rawValue {
                                self.finishHotspot(id, .failure(AppError.unavailable("你取消了加入 Wi-Fi，配置仍保存在本机")))
                            } else {
                                self.finishHotspot(id, .failure(AppError.unavailable("系统未完成入网，请保持随办在前台，并检查板子热点和 Wi-Fi 权限")))
                            }
                        } else { self.finishHotspot(id, .success(Void())) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishHotspot(id, .failure(CancellationError())) }
        }
    }
    private func finishHotspot(_ id: UUID, _ result: Result<Void, Error>) {
        guard let pending = pendingHotspot, pending.id == id else { return }
        pendingHotspot = nil; hotspotTimer?.cancel(); hotspotTimer = nil
        pending.continuation.resume(with: result)
    }
    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        if let ssid = joiningSSID { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) }
        joiningSSID = nil; operationID = nil; busy = false; operation = nil
    }
    func cancelConfiguration() {
        guard busy, let id = operationID else { return }
        operation?.cancel(); finishHotspot(id, .failure(CancellationError()))
        finishOperation(id)
        statusText = "配置操作已停止；已保存的硬件凭据保留。若系统入网提示仍显示，请关闭提示"
    }
    func clearConfiguration() {
        guard !busy else { return }
        do {
            try requireConfigurationChangeAllowed()
            PairingFlow.shared.cancel()
            try SecretStore.delete(Self.secretAccount)
            if let profile { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: profile.ssid) }
            profile = nil; ssid = ""; boardID = ""; joined = false
            history = []; UserDefaults.standard.removeObject(forKey: Self.historyKey)
            statusText = "本机硬件配置与连接记录已清除；板子的蓝牙配对和系统开发者配对保留"
        } catch { statusText = safeMessage(error) }
    }
    func recordConnection(transport: HardwareRelayTransport, success: Bool, message: String) {
        let name: String
        let recordBoardID: String?
        switch transport {
        case .usb: name = "USB"; recordBoardID = nil
        case .wifi: name = "Wi-Fi"; recordBoardID = profile?.id
        }
        var safe = message
        if let profile {
            safe = safe.replacingOccurrences(of: profile.passphrase, with: "[已隐藏]")
                .replacingOccurrences(of: profile.relay_token, with: "[已隐藏]")
        }
        safe = String(safe.prefix(240))
        history.insert(ConnectionRecord(id: UUID(), date: Date(), boardID: recordBoardID, transport: name,
            success: success, message: safe), at: 0)
        history = Array(history.prefix(20))
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: Self.historyKey) }
        statusText = safe == "连接已停止" ? "\(name) 连接已停止" : "\(name)：\(safe)"
    }
    private func safeMessage(_ error: Error) -> String {
        if let error = error as? AppError { return error.localizedDescription }
        return "硬件配置未完成，请检查蓝牙连接、BOOT 授权窗口和 Wi-Fi 状态后重试"
    }
}

struct HardwareWirelessSettingsView: View {
    @ObservedObject private var bluetooth = BluetoothBoardFlow.shared
    @ObservedObject private var wifi = HardwareWiFiFlow.shared
    @State private var control = PairingFlow.shared
    @State private var showingTouchTest = false
    @State private var clearConfirmation = false
    private var canChangeBluetooth: Bool { control.canChangeRoute && !wifi.busy }
    var body: some View {
        Form {
            Section {
                LabeledContent("当前操控模式", value: control.route.title)
                if control.route == .ncmDeveloper {
                    LabeledContent("实际操控通道", value: control.ready ? control.hardwareConnectionLabel : "未连接")
                } else {
                    Button("使用随办硬件v1操控") { _ = control.selectRoute(.ncmDeveloper) }
                        .disabled(!canChangeBluetooth)
                }
            } header: { Text("连接方式") } footer: {
                Text("首次无线配置：连接蓝牙 → 按 BOOT 读取配置 → 加入硬件 Wi-Fi → 完成系统配对并连接验证。配置保存后可只用 Wi-Fi，蓝牙无需持续连接。")
                Text("USB 优先。同一次操控固定使用一种通道；拔线或网络断开后会停止，请重新连接，不会自动重发动作。")
            }
            bluetoothSection
            if !bluetooth.connected && !bluetooth.connecting && !bluetooth.devices.isEmpty {
                Section("附近的硬件") {
                    ForEach(bluetooth.devices) { device in
                        Button { bluetooth.connect(device) } label: {
                            HStack { Text(device.name); Spacer(); Text("\(device.signal) dBm").font(.caption).foregroundStyle(.secondary) }
                        }.disabled(!canChangeBluetooth)
                    }
                }
            }
            wifiSection
            if control.route == .ncmDeveloper {
                PairingSection { showingTouchTest = true }
            }
            if !wifi.history.isEmpty {
                Section("连接记录") {
                    if let date = wifi.lastConnectedAt { LabeledContent("最近成功", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    ForEach(wifi.history) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(record.transport, systemImage: record.message == "连接已停止" ? "stop.circle" : (record.success ? "checkmark.circle" : "exclamationmark.circle"))
                                Spacer()
                                Text(record.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(record.message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("随办硬件v1")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingTouchTest) { TouchVerificationView(flow: control) }
        .confirmationDialog("清除本机硬件 Wi-Fi 配置和连接记录？", isPresented: $clearConfirmation, titleVisibility: .visible) {
            Button("清除", role: .destructive) { wifi.clearConfiguration() }
        } message: { Text("下次无线使用需重新连接蓝牙并按 BOOT 读取配置。系统开发者配对身份会保留。") }
        .onAppear { wifi.reload(); control.resume() }
        .onDisappear { bluetooth.stopScan() }
    }
    private var bluetoothSection: some View {
        Section {
            Label(bluetooth.message, systemImage: bluetooth.connected ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
            if bluetooth.connecting { ProgressView("正在连接蓝牙") }
            if bluetooth.connected {
                LabeledContent("设备", value: bluetooth.boardName)
                LabeledContent("设备编号", value: bluetooth.boardID)
                Button("断开蓝牙", role: .destructive) { bluetooth.disconnect() }.disabled(bluetooth.busy || !canChangeBluetooth)
            } else if !bluetooth.connecting {
                if bluetooth.rememberedPeripheralID != nil {
                    Button("重连已保存的蓝牙设备") { bluetooth.reconnectRemembered() }.disabled(!canChangeBluetooth)
                }
                Button(bluetooth.scanning ? "停止查找" : "查找硬件") {
                    if bluetooth.scanning { bluetooth.stopScan() } else { bluetooth.scan() }
                }.disabled(!canChangeBluetooth)
                if bluetooth.scanning { ProgressView() }
            } else {
                Button("停止蓝牙连接") { bluetooth.disconnect() }
            }
        } header: { Text("1 · 蓝牙与设备") } footer: {
            Text("连接蓝牙时会自动检查双向通信，用于首次配网与识别硬件。手机操控还需完成下方的连接检查，无需重复测试蓝牙。")
        }
    }
    private var wifiSection: some View {
        Section {
            Text(wifi.statusText).font(.footnote).foregroundStyle(.secondary)
            if wifi.hasConfiguration {
                LabeledContent("硬件热点", value: wifi.ssid)
                LabeledContent("已保存的设备", value: wifi.boardID)
                Text("密码和连接凭据已保存在本机钥匙串").font(.caption).foregroundStyle(.secondary)
                Button(wifi.joined ? "重新确认硬件 Wi-Fi" : "加入硬件 Wi-Fi") { wifi.join() }
                    .disabled(!wifi.canConfigure)
                    .accessibilityIdentifier("joinHardwareWiFi")
            }
            Button(wifi.hasConfiguration ? "重新读取并保存 Wi-Fi 配置" : "读取并保存 Wi-Fi 配置") { wifi.readConfiguration() }
                .disabled(!wifi.canConfigure || !bluetooth.connected || !bluetooth.supportsWiFiConfiguration)
                .accessibilityIdentifier("readHardwareWiFiConfiguration")
            if wifi.busy {
                ProgressView("正在配置")
                Button("停止配置") { wifi.cancelConfiguration() }
            }
            if wifi.hasConfiguration {
                Button("清除本机硬件配置与连接记录", role: .destructive) { clearConfirmation = true }
                    .disabled(!wifi.canConfigure)
            }
        } header: { Text("2 · Wi-Fi 配置") } footer: {
            Text("先连接蓝牙，再按板子的 BOOT 按钮，在 60 秒内读取。正在使用 USB 或执行任务时，请先停止并拔下手机与硬件之间的 USB 线再配网；编程 USB 供电可保留。")
            if bluetooth.connected && !bluetooth.supportsWiFiConfiguration { Text("当前固件未提供 Wi-Fi 配置，需要先更新硬件固件。") }
            Text("手机直接连接硬件热点，无需让手机和板子加入同一个家用 Wi-Fi。硬件需在附近；异地远程连接仍需后续服务。")
            Text("硬件热点不提供互联网。随办调用智谱等模型时，手机还需可用的蜂窝网络或其他独立上网路径，实际联网情况需在手机上验证。")
        }
    }
}
