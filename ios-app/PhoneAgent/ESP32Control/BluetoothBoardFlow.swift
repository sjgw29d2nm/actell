// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI
@preconcurrency import CoreBluetooth

struct BluetoothBoardDevice: Identifiable {
    let id: UUID
    let name: String
    let signal: Int
}

@MainActor final class BluetoothBoardFlow: NSObject, ObservableObject,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = BluetoothBoardFlow()
    private static let service = CBUUID(string: "AD51B100-2A4B-4C6D-8E90-102030405060")
    private static let informationID = CBUUID(string: "AD51B101-2A4B-4C6D-8E90-102030405060")
    private static let commandID = CBUUID(string: "AD51B102-2A4B-4C6D-8E90-102030405060")
    private static let responseID = CBUUID(string: "AD51B103-2A4B-4C6D-8E90-102030405060")
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
    @Published private(set) var devices: [BluetoothBoardDevice] = []
    @Published private(set) var message = "查找随办硬件v1，验证蓝牙连接"
    @Published private(set) var scanning = false
    @Published private(set) var connecting = false
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var boardName = ""
    @Published private(set) var boardID = ""
    @Published private(set) var usbConnected = false
    private var manager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var selected: CBPeripheral?
    private var information: Information?
    private var command: CBCharacteristic?
    private var response: CBCharacteristic?
    private var handshaking = false
    private var sequence: UInt32 = 0
    private var epoch = UUID()
    private var pending: Pending?
    private var connectionTimer: Task<Void, Never>?
    private var commandTimer: Task<Void, Never>?
    private var scanTimer: Task<Void, Never>?
    private var scanRequested = false
    private var retiringDevices: Set<UUID> = []

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
        stopScan(); epoch = UUID()
        connectionTimer?.cancel(); connectionTimer = nil
        finishCommand(.failure(AppError.unavailable("蓝牙连接已断开")))
        if let selected {
            if selected.state != .disconnected { retiringDevices.insert(selected.identifier) }
            manager?.cancelPeripheralConnection(selected); selected.delegate = nil
        }
        selected = nil; command = nil; response = nil; information = nil; handshaking = false
        connected = false; connecting = false; boardName = ""; boardID = ""; usbConnected = false
        self.message = message
    }
    func verify() {
        guard connected, !busy else { return }
        let current = epoch
        Task { [weak self] in
            guard let self else { return }
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
        guard pending == nil, let selected, let command, response?.isNotifying == true else {
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
        let previous = pending; pending = nil; busy = false
        previous?.continuation.resume(with: result)
    }
    private func finishDiscoveryIfReady() {
        guard !handshaking, connecting, let information, command != nil, response?.isNotifying == true else { return }
        handshaking = true; let current = epoch
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ping()
                guard self.epoch == current else { return }
                self.connectionTimer?.cancel(); self.connectionTimer = nil
                self.connecting = false; self.connected = true
                self.boardName = information.name; self.boardID = information.id
                self.usbConnected = information.usb_connected
                self.message = "蓝牙诊断已连接，双向通信验证通过"
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
            if scanRequested { beginScan() }
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
        guard selected?.identifier == peripheral.identifier else { return }
        peripheral.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if retiringDevices.remove(peripheral.identifier) != nil { return }
        guard selected?.identifier == peripheral.identifier else { return }
        disconnect(message: "无法连接板子，请靠近板子并重试")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if retiringDevices.remove(peripheral.identifier) != nil { return }
        guard selected?.identifier == peripheral.identifier else { return }
        disconnect(message: "板子蓝牙连接已断开")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            disconnect(message: "板子未提供随办蓝牙服务，请更新固件"); return
        }
        peripheral.discoverCharacteristics([Self.informationID, Self.commandID, Self.responseID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        guard error == nil, let chars = service.characteristics,
              let info = chars.first(where: { $0.uuid == Self.informationID }),
              let write = chars.first(where: { $0.uuid == Self.commandID && $0.properties.contains(.write) }),
              let reply = chars.first(where: { $0.uuid == Self.responseID && $0.properties.contains(.notify) }) else {
            disconnect(message: "板子蓝牙协议不完整，请更新固件"); return
        }
        command = write; response = reply
        peripheral.setNotifyValue(true, for: reply)
        peripheral.readValue(for: info)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard selected?.identifier == peripheral.identifier, characteristic.uuid == Self.responseID else { return }
        guard error == nil, characteristic.isNotifying else { disconnect(message: "无法接收板子回应"); return }
        finishDiscoveryIfReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard selected?.identifier == peripheral.identifier, characteristic === command, error != nil else { return }
        finishCommand(.failure(AppError.unavailable("蓝牙指令写入失败")))
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard selected?.identifier == peripheral.identifier else { return }
        guard error == nil, let data = characteristic.value, data.count <= 512 else {
            disconnect(message: "板子回应无效，请重新连接"); return
        }
        if characteristic.uuid == Self.informationID {
            guard let info = try? JSONDecoder().decode(Information.self, from: data),
                  info.version == 1, info.chip == "esp32s3", info.id.count == 12,
                  info.id.allSatisfy({ $0.isHexDigit }), info.capabilities.isSuperset(of: ["status", "ping"]) else {
                disconnect(message: "板子固件版本不兼容"); return
            }
            information = info; usbConnected = info.usb_connected
            finishDiscoveryIfReady()
        } else if characteristic.uuid == Self.responseID, let pending,
                  String(data: data, encoding: .utf8) == "SB1 OK \(pending.id)" {
            finishCommand(.success(Void()))
        }
    }
}

struct BluetoothBoardSettingsView: View {
    @ObservedObject private var flow = BluetoothBoardFlow.shared
    var body: some View {
        List {
            Section {
                Label(flow.message, systemImage: flow.connected ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                if flow.connecting { ProgressView("正在连接") }
                if flow.connected {
                    LabeledContent("板子", value: flow.boardName)
                    LabeledContent("设备编号", value: flow.boardID)
                    LabeledContent("USB", value: flow.usbConnected ? "已连接" : "未连接")
                    Button("验证双向通信") { flow.verify() }.disabled(flow.busy)
                    Button("断开连接", role: .destructive) { flow.disconnect() }
                } else if !flow.connecting {
                    Button(flow.scanning ? "停止查找" : "查找板子") {
                        if flow.scanning { flow.stopScan() } else { flow.scan() }
                    }
                    if flow.scanning { ProgressView() }
                }
            } header: { Text("蓝牙连接") } footer: {
                Text("当前蓝牙用于查找硬件、读取状态与验证通信。此连接不会切换或接管正在使用的 USB／VPN 操控通道；无线截图与手机操控还需后续 Wi-Fi 通道。")
            }
            if !flow.connected && !flow.connecting && !flow.devices.isEmpty {
                Section("附近的板子") {
                    ForEach(flow.devices) { device in
                        Button { flow.connect(device) } label: {
                            HStack { Text(device.name); Spacer(); Text("\(device.signal) dBm").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("随办硬件v1 蓝牙")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { flow.stopScan() }
    }
}
