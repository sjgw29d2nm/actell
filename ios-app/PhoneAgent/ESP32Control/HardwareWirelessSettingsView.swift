// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI

/// Connection evidence only. No hardware network credentials are read or stored.
@MainActor final class HardwareConnectionHistory: ObservableObject {
    static let shared = HardwareConnectionHistory()
    private static let historyKey = "suibanHardware.connectionHistory.v1"
    struct ConnectionRecord: Codable, Identifiable {
        let id: UUID
        let date: Date
        let boardID: String?
        let transport: String
        let success: Bool
        let message: String
    }
    @Published private(set) var history: [ConnectionRecord] = []
    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey), data.count <= 64 * 1024,
           let records = try? JSONDecoder().decode([ConnectionRecord].self, from: data) {
            history = Array(records.filter { $0.message.count <= 240 && ["USB", "Wi-Fi", "BLE"].contains($0.transport) }.prefix(20))
        }
    }
    func recordConnection(transport: HardwareRelayTransport, success: Bool, message: String) {
        append(transport: "USB", boardID: nil, success: success, message: message)
    }
    func recordBluetooth(boardID: String, success: Bool, message: String) {
        guard boardID.utf8.count == 12,
              boardID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return }
        append(transport: "BLE", boardID: boardID, success: success, message: message)
    }
    private func append(transport: String, boardID: String?, success: Bool, message: String) {
        let safe = String(message.replacingOccurrences(of: #"\b[0-9a-fA-F]{32,}\b"#, with: "[已隐藏]", options: .regularExpression).prefix(240))
        history.insert(ConnectionRecord(id: UUID(), date: Date(), boardID: boardID, transport: transport,
            success: success, message: safe), at: 0)
        history = Array(history.prefix(20))
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: Self.historyKey) }
    }
}

struct HardwareWirelessSettingsView: View {
    @ObservedObject private var bluetooth = BluetoothBoardFlow.shared
    @ObservedObject private var history = HardwareConnectionHistory.shared
    @State private var control = PairingFlow.shared
    @State private var showingTouchTest = false
    var body: some View {
        Form {
            usbConnectionSection
            if control.route == .ncmDeveloper {
                PairingSection { showingTouchTest = true }
            } else {
                Section {
                    Text("当前操控模式：\(control.route.title)").foregroundStyle(.secondary)
                    Button("使用随办硬件v1操控手机") { _ = control.selectRoute(.ncmDeveloper) }
                        .disabled(!control.canChangeRoute)
                } header: { Text("手机操控连接") } footer: {
                    Text("选择随办硬件后，通过 USB 连接手机与硬件。")
                }
            }
            Section {
                Label(bluetooth.connected ? "硬件蓝牙已连接" : "硬件蓝牙未连接", systemImage: "antenna.radiowaves.left.and.right")
                NavigationLink { BluetoothHIDSettingsView() } label: {
                    Label("蓝牙键鼠与输入验收", systemImage: "keyboard")
                }.accessibilityIdentifier("openBluetoothHIDSettings")
            } header: { Text("纯蓝牙输入") } footer: {
                Text("可单独验证蓝牙键盘和鼠标。跨 App 自动执行还需手机屏幕采集及指针定位验收。")
            }
            if !history.history.isEmpty { historySection }
        }
        .navigationTitle("随办硬件v1")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingTouchTest) { TouchVerificationView(flow: control) }
        .onDisappear { bluetooth.stopScan() }
    }
    private var usbConnectionSection: some View {
        Section {
            Label("USB 有线连接", systemImage: "cable.connector")
            LabeledContent("实际操控通道", value: control.route == .ncmDeveloper && control.ready ? control.hardwareConnectionLabel : "尚未验证")
                .accessibilityIdentifier("hardwareControlTransport")
            Text("USB 可独立连接手机与硬件，无需先连接蓝牙。接好后在下方完成手机操控连接。")
                .font(.footnote).foregroundStyle(.secondary)
            DisclosureGroup("USB 接线与网络设置") {
                Text("手机需要接到板子的原生 USB／OTG 数据口。仅把编程口（COM）接到 Mac，不能建立手机与板子的 USB 操控连接。")
                Text("Lightning 接口的手机需要支持 USB 外设的相机转换器，再通过 USB 数据线连接板子；普通 Lightning 充电线不能直接代替。供电不足时，使用转换器的辅助供电口。")
                Text("若手机已识别 USB 以太网，将其设为手动：IP 192.168.7.2，子网掩码 255.255.255.0；路由器和 DNS 留空。")
            }.font(.footnote)
        } header: { Text("硬件连接") } footer: {
            Text("每次任务固定使用已验证的通道，断线后停止，不会自动切换或重发动作。")
        }
    }
    private var historySection: some View {
        Section {
            ForEach(history.history) { record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.transport == "Wi-Fi" ? "Wi-Fi（旧记录）" : (record.transport == "BLE" ? "蓝牙" : record.transport)).font(.subheadline)
                        Spacer()
                        Text(record.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(record.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(record.message).font(.footnote).foregroundStyle(record.success ? Color.secondary : Color.orange)
                }
            }
        } header: { Text("连接记录") } footer: {
            Text("保留最近 20 条历史记录；记录不表示当前连接状态。")
        }
    }
}
