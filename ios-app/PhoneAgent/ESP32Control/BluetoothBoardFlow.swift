// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI
@preconcurrency import CoreBluetooth

struct BluetoothBoardDevice: Identifiable {
    let id: UUID
    let name: String
    let signal: Int
}
struct BluetoothRouterState: Decodable, Sendable {
    let version: Int
    let id: String
    let ssid: String
    let state: String
    let board_ip: String?
    let netmask: String?
    let error: String?
    var failureCode: String? {
        guard let error, !error.isEmpty else { return nil }
        let publicCodes = ["usb_address_conflict", "network_unsupported", "network_changed", "lost_ip",
                           "connect_timeout", "connect_failed", "connection_lost", "storage_or_ap_failed", "saved_configuration_invalid"]
        if publicCodes.contains(error) { return error }
        if error.hasPrefix("wifi_"), let reason = UInt16(error.dropFirst(5)), error == "wifi_\(reason)" { return error }
        return nil
    }
    var failureMessage: String {
        let message: String
        switch failureCode {
        case "wifi_201": message = "硬件未找到该 Wi-Fi，请确认名称及 2.4GHz 网络"
        case "wifi_202": message = "路由器认证失败，请核对密码或网络认证方式"
        case "wifi_15", "wifi_204": message = "Wi-Fi 握手超时，请核对密码并检查路由器"
        case "wifi_210", "wifi_211": message = "未找到认证方式兼容的 Wi-Fi，请检查路由器加密方式"
        case "usb_address_conflict": message = "路由器分配的硬件地址与 USB 地址冲突"
        case "network_unsupported": message = "硬件取得的网络地址不在支持的私网 IPv4 范围"
        case "lost_ip", "connection_lost", "network_changed": message = "硬件网络地址丢失或变化，请重新检查网络"
        case "connect_timeout": message = "硬件等待入网超时，请检查 Wi-Fi 信号、名称与认证方式"
        case "connect_failed": message = "硬件未能启动本次 Wi-Fi 入网"
        case "storage_or_ap_failed": message = "硬件保存配置或更新备用热点失败"
        case "saved_configuration_invalid": message = "硬件保存的路由器配置无效，请重新配网"
        default: message = "硬件连接路由器失败，请检查名称、密码与 2.4GHz 网络"
        }
        return "\(message)（\(failureCode ?? "unknown")）；原配置保留"
    }
}

@MainActor final class BluetoothBoardFlow: NSObject, ObservableObject,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = BluetoothBoardFlow()
    private static let service = CBUUID(string: "AD51B100-2A4B-4C6D-8E90-102030405060")
    private static let informationID = CBUUID(string: "AD51B101-2A4B-4C6D-8E90-102030405060")
    private static let commandID = CBUUID(string: "AD51B102-2A4B-4C6D-8E90-102030405060")
    private static let responseID = CBUUID(string: "AD51B103-2A4B-4C6D-8E90-102030405060")
    private static let wifiConfigurationID = CBUUID(string: "AD51B104-2A4B-4C6D-8E90-102030405060")
    private static let routerConfigurationID = CBUUID(string: "AD51B105-2A4B-4C6D-8E90-102030405060")
    private static let routerStateID = CBUUID(string: "AD51B106-2A4B-4C6D-8E90-102030405060")
    private static let rememberedDeviceKey = "suibanHardware.lastBluetoothPeripheral"
    private struct Information: Decodable {
        let version: Int
        let id: String
        let name: String
        let chip: String
        let usb_connected: Bool
        let uptime_ms: Int64
        let capabilities: Set<String>
    }
    private struct Pending {
        let id: UInt32
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct PendingWiFiRead {
        let id: UUID
        let epoch: UUID
        let peerID: UUID
        let boardID: String
        let characteristic: CBCharacteristic
        let continuation: CheckedContinuation<HardwareWiFiProfile, Error>
    }
    private struct PendingRouterWrite {
        let id: UUID, epoch: UUID, peerID: UUID
        let characteristic: CBCharacteristic
        let continuation: CheckedContinuation<Void, Error>
    }
    private struct PendingRouterRead {
        let id: UUID, epoch: UUID, peerID: UUID
        let boardID: String
        let characteristic: CBCharacteristic
        let continuation: CheckedContinuation<BluetoothRouterState, Error>
    }
    @Published private(set) var devices: [BluetoothBoardDevice] = []
    @Published private(set) var message = "查找随办硬件v1，验证蓝牙连接"
    @Published private(set) var scanning = false
    @Published private(set) var connecting = false
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var boardName = ""
    @Published private(set) var boardID = ""
    @Published private(set) var usbConnected = false
    @Published private(set) var supportsWiFiConfiguration = false
    @Published private(set) var supportsRouterConfiguration = false
    @Published private(set) var rememberedPeripheralID = UserDefaults.standard.string(forKey: "suibanHardware.lastBluetoothPeripheral").flatMap(UUID.init(uuidString:))
    private var manager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var selected: CBPeripheral?
    private var information: Information?
    private var command: CBCharacteristic?
    private var response: CBCharacteristic?
    private var informationCharacteristic: CBCharacteristic?
    private var wifiConfiguration: CBCharacteristic?
    private var pendingWiFiRead: PendingWiFiRead?
    private var routerConfiguration: CBCharacteristic?
    private var routerState: CBCharacteristic?
    private var pendingRouterWrite: PendingRouterWrite?
    private var pendingRouterRead: PendingRouterRead?
    private var routerTimer: Task<Void, Never>?
    private var wifiReadTimer: Task<Void, Never>?
    private var reconnectRequested = false
    private var handshaking = false
    private var sequence: UInt32 = 0
    private var epoch = UUID()
    private var pending: Pending?
    private var connectionTimer: Task<Void, Never>?
    private var commandTimer: Task<Void, Never>?
    private var scanTimer: Task<Void, Never>?
    private var scanRequested = false
    private var retiringDevices: Set<UUID> = []
    #if DEBUG
    private var diagnosticProbeStarted = false
    private var diagnosticWiFiErrorCode: Int?
    private var diagnosticWiFiErrorDomain: String?
    #endif

    /// Explicit CLI diagnostic only: one remembered peer, one configuration
    /// read, no phone actions. An explicit open-router flag uses the normal
    /// App provisioning flow once; it never changes the phone's Wi-Fi.
    func runDiagnosticProbeIfRequested() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--hardware-bluetooth-probe"), !diagnosticProbeStarted,
              let index = arguments.firstIndex(of: "--hardware-board-id"), index + 1 < arguments.count else { return }
        let expected = arguments[index + 1]
        guard expected.utf8.count == 12,
              expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return }
        diagnosticProbeStarted = true
        let began = Date(), url = URL.documentsDirectory.appending(path: "hardware-bluetooth-probe.txt")
        var lines: [String] = []
        func record(_ stage: String) {
            lines.append(String(format: "%.3f ", Date().timeIntervalSince(began)) + stage)
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: [.atomic, .completeFileProtection])
        }
        record("probe.begin")
        guard !busy, PairingFlow.shared.canChangeRoute, !HardwareWiFiFlow.shared.busy else { record("probe.busy"); return }
        guard let remembered = rememberedPeripheralID else { record("probe.no_remembered_peer"); return }
        if let selected, selected.identifier != remembered { record("probe.other_peer_selected"); return }
        if !connected && !connecting { reconnectRemembered() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !connected && ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { record("probe.cancelled"); return }
            if !connecting && !reconnectRequested && selected == nil { record("connect.failed"); return }
        }
        guard !Task.isCancelled, connected, selected?.identifier == remembered else { record("connect.timeout"); return }
        guard boardID == expected else { record("connect.board_id_mismatch"); return }
        record("connect.verified_board_id_match")
        guard supportsWiFiConfiguration else { record("read.characteristic_missing"); return }
        do {
            record("read.start")
            if arguments.contains("--hardware-configure-open-router") {
                guard let index = arguments.firstIndex(of: "--hardware-router-ssid"), index + 1 < arguments.count else { record("configure.missing_ssid"); return }
                let target = arguments[index + 1]
                guard !target.isEmpty, target.utf8.count <= 32, !target.utf8.contains(0) else { record("configure.invalid_ssid"); return }
                let wifi = HardwareWiFiFlow.shared
                record("configure.open_router.begin one_request_only=true")
                wifi.configureRouter(ssid: target, passphrase: "")
                let deadline = ContinuousClock.now.advanced(by: .seconds(80))
                while wifi.busy && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                if wifi.busy { wifi.cancelConfiguration(); record("configure.wait_stopped no_resend=true") }
                record("configure.open_router.end saved=\(wifi.hasRouterConfiguration && wifi.boardID == expected && wifi.ssid == target) joined=\(wifi.joined)")
                if connected, !busy {
                    let state = try await fetchRouterState()
                    record("router.read.success state=\(state.state) error=\(state.failureCode ?? "none") board_id_match=\(state.id == expected)")
                }
            } else if arguments.contains("--hardware-configure-wifi") {
                let wifi = HardwareWiFiFlow.shared
                wifi.readConfiguration(joinAfterSave: true)
                let deadline = ContinuousClock.now.advanced(by: .seconds(65))
                while wifi.busy && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                record("configure.end saved=\(wifi.hasConfiguration && wifi.boardID == expected) joined=\(wifi.joined)")
            } else {
                _ = try await fetchWiFiConfiguration()
                record("read.success credentials_discarded=true")
                if supportsRouterConfiguration {
                    let state = try await fetchRouterState()
                    record("router.read.success state=\(state.state) error=\(state.failureCode ?? "none") board_id_match=\(state.id == expected)")
                }
            }
        } catch {
            let code = diagnosticWiFiErrorCode.map { String($0) } ?? "none"
            record("read.failed att_domain=\(diagnosticWiFiErrorDomain ?? "none") att_code=\(code)")
        }
        do {
            let network = try NCMProbeClient.currentWiFiNetwork()
            let connectedWiFi = try await NCMProbeClient.hasConnectedWiFi()
            record("network.read wifi_connected=\(connectedWiFi) ipv4_available=\(network != nil) network_changed_by_probe=false")
        } catch {
            record("network.read unavailable network_changed_by_probe=false")
        }
            record("hid.firmware.capability supported=\(BluetoothHIDTransport.shared.supported)")
            record("probe.end bluetooth_connected=\(connected)")
        #endif
    }

    func scan() {
        guard selected == nil else { return }
        scanRequested = true
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if manager?.state == .poweredOn { beginScan() }
        else { updateAvailability() }
    }
    func stopScan() {
        scanRequested = false; scanning = false
        scanTimer?.cancel(); scanTimer = nil
        manager?.stopScan()
    }
    /// User initiated only. CoreBluetooth's remembered peripheral is retrieved
    /// once; failure asks for a bounded scan rather than repeatedly reconnecting.
    func reconnectRemembered() {
        guard selected == nil, !connecting, rememberedPeripheralID != nil else { return }
        reconnectRequested = true
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if manager?.state == .poweredOn { performRememberedReconnect() }
        else { updateAvailability() }
    }
    private func performRememberedReconnect() {
        reconnectRequested = false
        guard let id = rememberedPeripheralID, let manager,
              let peripheral = manager.retrievePeripherals(withIdentifiers: [id]).first else {
            message = "未找到保存的蓝牙设备，请查找板子"
            return
        }
        peripherals[id] = peripheral
        connect(BluetoothBoardDevice(id: id, name: peripheral.name ?? "随办硬件v1", signal: 0))
    }
    private func beginScan() {
        guard scanRequested, selected == nil, manager?.state == .poweredOn else { return }
        peripherals = [:]; devices = []; scanning = true
        message = "正在查找附近的随办板子"
        manager?.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimer?.cancel()
        scanTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.scanning else { return }
            self.stopScan()
            self.message = self.devices.isEmpty ? "未发现板子，请检查供电和蓝牙固件" : "请选择要连接的板子"
        }
    }
    func connect(_ device: BluetoothBoardDevice) {
        guard !connecting, selected == nil, manager?.state == .poweredOn, !retiringDevices.contains(device.id),
              let peripheral = peripherals[device.id] else { return }
        stopScan(); epoch = UUID(); let current = epoch
        selected = peripheral; peripheral.delegate = self
        connecting = true; connected = false; boardName = device.name
        message = "正在连接板子；如系统提示蓝牙配对，请确认"
        manager?.connect(peripheral)
        connectionTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.epoch == current, !self.connected else { return }
            self.disconnect(message: "蓝牙连接或配对超时，请重新连接")
        }
    }
    func disconnect() { disconnect(message: "蓝牙连接已断开") }
    private func disconnect(message: String) {
        BluetoothHIDTransport.shared.invalidate(message)
        stopScan(); reconnectRequested = false; epoch = UUID()
        connectionTimer?.cancel(); connectionTimer = nil
        finishCommand(.failure(AppError.unavailable("蓝牙连接已断开")))
        finishWiFiRead(.failure(AppError.unavailable("蓝牙连接已断开，请重新连接后在 App 重试配网")))
        finishRouterWrite(.failure(AppError.unavailable("蓝牙已断开，配置接收结果未确认；不会自动重发")))
        finishRouterRead(.failure(AppError.unavailable("蓝牙已断开，请重新连接后检查硬件网络状态")))
        if let selected {
            if selected.state != .disconnected { retiringDevices.insert(selected.identifier) }
            manager?.cancelPeripheralConnection(selected); selected.delegate = nil
        }
        selected = nil; command = nil; response = nil; information = nil; informationCharacteristic = nil
        wifiConfiguration = nil; supportsWiFiConfiguration = false; handshaking = false
        routerConfiguration = nil; routerState = nil; supportsRouterConfiguration = false
        connected = false; connecting = false; boardName = ""; boardID = ""; usbConnected = false
        self.message = message
    }
    func verify() {
        guard connected, !busy else { return }
        let current = epoch
        Task { [weak self] in
            guard let self, self.epoch == current, self.connected, !self.busy else { return }
            do {
                try await self.ping()
                guard self.epoch == current else { return }
                self.message = "板子已回应，双向通信正常"
                if let characteristic = self.selected?.services?.first?.characteristics?.first(where: { $0.uuid == Self.informationID }) {
                    self.selected?.readValue(for: characteristic)
                }
            } catch {
                guard self.epoch == current else { return }
                self.disconnect(message: "板子未确认指令，请重新连接")
            }
        }
    }
    private func ping() async throws {
        guard !busy, let selected, let command, response?.isNotifying == true else {
            throw AppError.unavailable("蓝牙服务尚未就绪")
        }
        guard sequence < UInt32.max else { throw AppError.unavailable("请重新连接板子") }
        sequence += 1; let id = sequence, current = epoch
        let data = Data("SB1 PING \(id)".utf8)
        guard data.count <= selected.maximumWriteValueLength(for: .withResponse) else { throw AppError.invalid("蓝牙写入长度不支持") }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pending = Pending(id: id, continuation: continuation); busy = true
                commandTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard let self, self.epoch == current, self.pending?.id == id else { return }
                    self.finishCommand(.failure(AppError.unavailable("板子回应超时")))
                }
                selected.writeValue(data, for: command, type: .withResponse)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == current, self.pending?.id == id else { return }
                self.finishCommand(.failure(CancellationError()))
            }
        }
    }
    private func finishCommand(_ result: Result<Void, Error>) {
        commandTimer?.cancel(); commandTimer = nil
        let previous = pending; pending = nil; refreshBusy()
        previous?.continuation.resume(with: result)
    }
    func fetchWiFiConfiguration() async throws -> HardwareWiFiProfile {
        guard connected, !busy,
              let selected, let characteristic = wifiConfiguration else {
            throw AppError.unavailable("请先连接蓝牙；未提供 Wi-Fi 配置的板子需要更新固件")
        }
        #if DEBUG
        diagnosticWiFiErrorCode = nil; diagnosticWiFiErrorDomain = nil
        #endif
        let id = UUID(), current = epoch, peerID = selected.identifier, expectedBoardID = boardID
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pendingWiFiRead = PendingWiFiRead(id: id, epoch: current, peerID: peerID,
                    boardID: expectedBoardID, characteristic: characteristic, continuation: continuation)
                busy = true
                wifiReadTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, self.epoch == current, self.pendingWiFiRead?.id == id else { return }
                    self.finishWiFiRead(.failure(AppError.unavailable("读取超时，请检查板子供电并重新连接蓝牙后重试")))
                    self.disconnect(message: "Wi-Fi 配置读取超时，蓝牙已停止；请重新连接后在 App 重试")
                }
                selected.readValue(for: characteristic)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == current, self.pendingWiFiRead?.id == id else { return }
                self.finishWiFiRead(.failure(CancellationError()))
                // A GATT read has no request identifier. Retire this connection
                // so a late response cannot satisfy a later configuration read.
                self.disconnect(message: "已停止读取配置，请重新连接后重试")
            }
        }
    }
    private func finishWiFiRead(_ result: Result<HardwareWiFiProfile, Error>) {
        wifiReadTimer?.cancel(); wifiReadTimer = nil
        let previous = pendingWiFiRead; pendingWiFiRead = nil; refreshBusy()
        previous?.continuation.resume(with: result)
    }
    private func refreshBusy() {
        busy = pending != nil || pendingWiFiRead != nil || pendingRouterWrite != nil || pendingRouterRead != nil || BluetoothHIDTransport.shared.busy
    }
    func configureRouter(ssid: String, passphrase: String) async throws {
        guard connected, !busy, let selected, let characteristic = routerConfiguration else {
            throw AppError.unavailable("请先连接支持路由器配网的硬件蓝牙")
        }
        guard !ssid.isEmpty, ssid.utf8.count <= 32, !ssid.utf8.contains(0),
              passphrase.isEmpty || ((8...63).contains(passphrase.utf8.count) && passphrase.utf8.allSatisfy({ (32...126).contains($0) })) else {
            throw AppError.invalid("Wi-Fi 名称最多 32 字节；加密网络密码须为 8～63 个英文字符，开放网络留空")
        }
        struct Request: Encodable { let version: Int; let id: String; let ssid: String; let passphrase: String }
        let data = try JSONEncoder().encode(Request(version: 1, id: boardID, ssid: ssid, passphrase: passphrase))
        guard data.count <= 512, data.count <= selected.maximumWriteValueLength(for: .withResponse) else { throw AppError.invalid("当前蓝牙写入长度不足，请重新连接硬件") }
        let id = UUID(), current = epoch
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingRouterWrite = PendingRouterWrite(id: id, epoch: current, peerID: selected.identifier, characteristic: characteristic, continuation: continuation)
                refreshBusy()
                routerTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, self.epoch == current, self.pendingRouterWrite?.id == id else { return }
                    self.finishRouterWrite(.failure(AppError.unavailable("配置接收结果未确认，没有自动重发；重新连接后检查硬件状态")))
                    self.disconnect(message: "配置发送超时，蓝牙已停止；不会自动重发")
                }
                selected.writeValue(data, for: characteristic, type: .withResponse)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == current, self.pendingRouterWrite?.id == id else { return }
                self.finishRouterWrite(.failure(CancellationError()))
                self.disconnect(message: "已停止等待配置确认；硬件可能已接收，不会自动重发")
            }
        }
    }
    func fetchRouterState() async throws -> BluetoothRouterState {
        guard connected, !busy, let selected, let characteristic = routerState else { throw AppError.unavailable("路由器状态服务尚未就绪，请重新连接硬件") }
        let id = UUID(), current = epoch, expectedBoardID = boardID
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pendingRouterRead = PendingRouterRead(id: id, epoch: current, peerID: selected.identifier, boardID: expectedBoardID, characteristic: characteristic, continuation: continuation)
                refreshBusy()
                routerTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard let self, self.epoch == current, self.pendingRouterRead?.id == id else { return }
                    self.finishRouterRead(.failure(AppError.unavailable("读取路由器状态超时，请重新连接后检查")))
                    self.disconnect(message: "读取状态超时，蓝牙已停止")
                }
                selected.readValue(for: characteristic)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == current, self.pendingRouterRead?.id == id else { return }
                self.finishRouterRead(.failure(CancellationError()))
                self.disconnect(message: "已停止读取网络状态")
            }
        }
    }
    private func finishRouterWrite(_ result: Result<Void, Error>) {
        guard let previous = pendingRouterWrite else { return }
        routerTimer?.cancel(); routerTimer = nil; pendingRouterWrite = nil; refreshBusy()
        previous.continuation.resume(with: result)
    }
    private func finishRouterRead(_ result: Result<BluetoothRouterState, Error>) {
        guard let previous = pendingRouterRead else { return }
        routerTimer?.cancel(); routerTimer = nil; pendingRouterRead = nil; refreshBusy()
        previous.continuation.resume(with: result)
    }
    private func finishDiscoveryIfReady() {
        guard !handshaking, connecting, let information, command != nil, response?.isNotifying == true else { return }
        handshaking = true; let current = epoch
        Task { [weak self] in
            guard let self, self.epoch == current, self.connecting,
                  self.handshaking, !self.connected else { return }
            do {
                try await self.ping()
                guard self.epoch == current else { return }
                self.connectionTimer?.cancel(); self.connectionTimer = nil
                self.connecting = false; self.connected = true
                self.boardName = information.name; self.boardID = information.id
                self.usbConnected = information.usb_connected
                self.rememberedPeripheralID = self.selected?.identifier
                if let id = self.rememberedPeripheralID { UserDefaults.standard.set(id.uuidString, forKey: Self.rememberedDeviceKey) }
                self.message = "蓝牙诊断已连接，双向通信验证通过"
                BluetoothHIDTransport.shared.confirmBoard(id: information.id, capability: information.capabilities.contains("ble_hid_v1"))
            } catch {
                guard self.epoch == current else { return }
                self.disconnect(message: "蓝牙配对或通信验证失败，请重新连接")
            }
        }
    }
    private func updateAvailability() {
        switch manager?.state {
        case .poweredOff: message = "请开启手机蓝牙"
        case .unauthorized: message = "请在 iPhone 设置中允许随办使用蓝牙"
        case .unsupported: message = "此设备不支持蓝牙连接"
        case .resetting: message = "蓝牙正在重置，请稍后查找"
        default: message = "正在检查蓝牙状态"
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if reconnectRequested { performRememberedReconnect() }
            else if scanRequested { beginScan() }
        } else {
            disconnect(message: "蓝牙不可用"); updateAvailability()
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning, RSSI.intValue != 127, peripherals.count < 16 || peripherals[peripheral.identifier] != nil else { return }
        peripherals[peripheral.identifier] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "随办板子"
        let device = BluetoothBoardDevice(id: peripheral.identifier, name: String(name.prefix(40)), signal: RSSI.intValue)
        devices.removeAll { $0.id == device.id }; devices.append(device)
        devices.sort { $0.signal > $1.signal }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if retiringDevices.contains(peripheral.identifier) { central.cancelPeripheralConnection(peripheral); return }
        guard selected === peripheral else { return }
        peripheral.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if retiringDevices.remove(peripheral.identifier) != nil { return }
        guard selected === peripheral else { return }
        disconnect(message: "无法连接板子，请靠近板子并重试")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if retiringDevices.remove(peripheral.identifier) != nil { return }
        guard selected === peripheral else { return }
        disconnect(message: "板子蓝牙连接已断开")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard selected === peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            disconnect(message: "板子未提供随办蓝牙服务，请更新固件"); return
        }
        peripheral.discoverCharacteristics([Self.informationID, Self.commandID, Self.responseID, Self.wifiConfigurationID, Self.routerConfigurationID, Self.routerStateID,
            BluetoothHIDTransport.commandID, BluetoothHIDTransport.responseID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard selected === peripheral, invalidatedServices.contains(where: { $0.uuid == Self.service }) else { return }
        BluetoothHIDTransport.shared.invalidate("蓝牙服务已变化，旧输入会话已停止")
        epoch = UUID(); let current = epoch
        connectionTimer?.cancel(); connectionTimer = nil
        finishCommand(.failure(AppError.unavailable("硬件服务已更新，请等待重新发现")))
        finishWiFiRead(.failure(AppError.unavailable("硬件服务已更新，请等待蓝牙重新连接后在 App 重试")))
        finishRouterWrite(.failure(AppError.unavailable("硬件服务已更新，配置接收结果未确认；不会自动重发")))
        finishRouterRead(.failure(AppError.unavailable("硬件服务已更新，请重新检查网络状态")))
        command = nil; response = nil; information = nil; informationCharacteristic = nil
        wifiConfiguration = nil; supportsWiFiConfiguration = false; handshaking = false
        routerConfiguration = nil; routerState = nil; supportsRouterConfiguration = false
        connected = false; connecting = true; boardID = ""; usbConnected = false
        message = "硬件服务已更新，正在重新发现蓝牙服务"
        connectionTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.epoch == current, !self.connected else { return }
            self.disconnect(message: "重新发现服务超时，请手动重连硬件")
        }
        peripheral.discoverServices([Self.service])
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard selected === peripheral, service.uuid == Self.service,
              peripheral.services?.contains(where: { $0 === service }) == true else { return }
        guard error == nil, let chars = service.characteristics,
              let info = chars.first(where: { $0.uuid == Self.informationID }),
              let write = chars.first(where: { $0.uuid == Self.commandID && $0.properties.contains(.write) }),
              let reply = chars.first(where: { $0.uuid == Self.responseID && $0.properties.contains(.notify) }) else {
            disconnect(message: "板子蓝牙协议不完整，请更新固件"); return
        }
        command = write; response = reply; informationCharacteristic = info
        wifiConfiguration = chars.first(where: { $0.uuid == Self.wifiConfigurationID && $0.properties.contains(.read) })
        supportsWiFiConfiguration = wifiConfiguration != nil
        routerConfiguration = chars.first(where: { $0.uuid == Self.routerConfigurationID && $0.properties.contains(.write) })
        routerState = chars.first(where: { $0.uuid == Self.routerStateID && $0.properties.contains(.read) })
        supportsRouterConfiguration = routerConfiguration != nil && routerState != nil
        let hid = BluetoothHIDTransport.shared
        hid.onBusyChanged = { [weak self] in self?.refreshBusy() }
        hid.onFatalError = { [weak self] in self?.disconnect(message: "蓝牙输入已停止，请重新连接硬件") }
        hid.bind(peripheral,
            command: chars.first(where: { $0.uuid == BluetoothHIDTransport.commandID && $0.properties.contains(.write) }),
            response: chars.first(where: { $0.uuid == BluetoothHIDTransport.responseID && $0.properties.contains(.notify) && $0.properties.contains(.read) }))
        peripheral.setNotifyValue(true, for: reply)
        peripheral.readValue(for: info)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if selected === peripheral, BluetoothHIDTransport.shared.notificationChanged(peripheral, characteristic: characteristic, error: error) { return }
        guard selected === peripheral, characteristic === response else { return }
        guard error == nil, characteristic.isNotifying else { disconnect(message: "无法接收板子回应"); return }
        finishDiscoveryIfReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if selected === peripheral, BluetoothHIDTransport.shared.writeCompleted(peripheral, characteristic: characteristic, error: error) { return }
        if selected === peripheral, let pending = pendingRouterWrite, pending.epoch == epoch,
           pending.peerID == peripheral.identifier, pending.characteristic === characteristic, characteristic === routerConfiguration {
            finishRouterWrite(error == nil ? .success(Void()) : .failure(AppError.unavailable("硬件未接收配网请求，请检查设备是否忙碌；未自动重发")))
            return
        }
        guard selected === peripheral, characteristic === command, error != nil else { return }
        finishCommand(.failure(AppError.unavailable("蓝牙指令写入失败")))
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard selected === peripheral else { return }
        if BluetoothHIDTransport.shared.valueUpdated(peripheral, characteristic: characteristic, error: error) { return }
        if characteristic.uuid == Self.routerStateID {
            guard let pending = pendingRouterRead, pending.epoch == epoch, pending.peerID == peripheral.identifier,
                  pending.characteristic === characteristic, characteristic === routerState else { return }
            guard error == nil, let data = characteristic.value, !data.isEmpty, data.count <= 2048,
                  let state = try? JSONDecoder().decode(BluetoothRouterState.self, from: data),
                  state.version == 1, state.id == pending.boardID, state.ssid.utf8.count <= 32,
                  ["unconfigured", "connecting", "ready", "failed"].contains(state.state) else {
                finishRouterRead(.failure(AppError.unavailable("硬件网络状态无效，请重新连接后检查"))); return
            }
            finishRouterRead(.success(state)); return
        }
        if characteristic.uuid == Self.wifiConfigurationID {
            guard let pending = pendingWiFiRead, pending.epoch == epoch,
                  pending.peerID == peripheral.identifier, pending.characteristic === characteristic,
                  characteristic === wifiConfiguration else { return }
            #if DEBUG
            if let failure = error as NSError? {
                diagnosticWiFiErrorCode = failure.code
                diagnosticWiFiErrorDomain = failure.domain == CBATTErrorDomain ? "CBATTErrorDomain" : "other"
            }
            #endif
            guard error == nil, let data = characteristic.value, !data.isEmpty, data.count <= 2048 else {
                finishWiFiRead(.failure(AppError.unavailable("读取 Wi-Fi 配置失败，请确认系统蓝牙配对已完成、板子 Wi-Fi 已启动")))
                return
            }
            do {
                let profile = try JSONDecoder().decode(HardwareWiFiProfile.self, from: data)
                try profile.validate(expectedBoardID: pending.boardID)
                finishWiFiRead(.success(profile))
            } catch {
                finishWiFiRead(.failure(AppError.invalid("板子的 Wi-Fi 配置不匹配，请确认所选硬件后重试")))
            }
            return
        }
        guard characteristic === informationCharacteristic || characteristic === response else { return }
        guard error == nil, let data = characteristic.value, data.count <= 512 else {
            disconnect(message: "板子回应无效，请重新连接"); return
        }
        if characteristic === informationCharacteristic {
            guard let info = try? JSONDecoder().decode(Information.self, from: data),
                  info.version == 1, info.chip == "esp32s3", info.id.count == 12,
                  info.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  info.capabilities.isSuperset(of: ["status", "ping"]) else {
                disconnect(message: "板子固件版本不兼容"); return
            }
            information = info; usbConnected = info.usb_connected
            finishDiscoveryIfReady()
        } else if characteristic === response, let pending,
                  String(data: data, encoding: .utf8) == "SB1 OK \(pending.id)" {
            finishCommand(.success(Void()))
        }
    }
}
