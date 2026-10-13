// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ESP32ControlSettingsView: View {
    @State private var flow = PairingFlow.shared
    @State private var showingTouchTest = false
    @State private var localAddress = PairingFlow.shared.vpnConfiguration.localAddress
    @State private var peerAddress = PairingFlow.shared.vpnConfiguration.peerAddress
    @State private var error: String?
    private enum AddressField: Hashable { case local, peer }
    @FocusState private var editing: AddressField?
    var body: some View {
        if flow.route == .ncmDeveloper {
            HardwareWirelessSettingsView()
        } else {
            vpnForm
        }
    }
    private var vpnForm: some View {
        Form {
            if flow.route == .vpnLoopback {
                vpnConfigurationSection
            }
            PairingSection { showingTouchTest = true }
        }
            .navigationTitle(flow.route.controlTitle)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showingTouchTest) {
                TouchVerificationView(flow: PairingFlow.shared)
            }
            .toolbar {
                ToolbarItem(id: "vpnLoopbackSave", placement: .confirmationAction) {
                    if flow.route == .vpnLoopback && changed {
                        Button("保存", action: save)
                            .accessibilityIdentifier("saveVPNLoopbackConfiguration")
                            .disabled(!flow.canChangeRoute)
                    }
                }
            }
            .task { PairingFlow.shared.resume() }
    }
    private var changed: Bool {
        localAddress != flow.vpnConfiguration.localAddress || peerAddress != flow.vpnConfiguration.peerAddress
    }
    private var vpnConfigurationSection: some View {
        Section {
            addressRow("接口地址", text: $localAddress,
                defaultAddress: VPNLoopbackConfiguration.defaults.localAddress,
                candidates: [VPNLoopbackConfiguration.defaults.localAddress, "198.18.0.1"],
                field: .local, identifier: "vpnLoopbackInterfaceAddress")
            addressRow("对端地址", text: $peerAddress,
                defaultAddress: VPNLoopbackConfiguration.defaults.peerAddress,
                candidates: [VPNLoopbackConfiguration.defaults.peerAddress],
                field: .peer, identifier: "vpnLoopbackPeerAddress")
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: { Text("手机内的 VPN 回环") } footer: {
            Text("这条方式不使用随办硬件。它需要另外安装并启用支持回环的 LocalDevVPN，以及系统开发者配对；这里的地址必须与该 VPN 配置一致。普通上网 VPN 不能代替。")
            Text("如果使用随办硬件，请返回设置，选择「随办硬件v1」，再进入「硬件设置」。建立回环连接阶段还需要处于 Wi-Fi 环境。")
        }
        .keyboardType(.numbersAndPunctuation)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .disabled(!flow.canChangeRoute)
        .onSubmit(save)
    }
    private func addressRow(_ title: String, text: Binding<String>, defaultAddress: String,
                            candidates: [String], field: AddressField, identifier: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(defaultAddress, text: text)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifier)
                    .focused($editing, equals: field)
                Menu {
                    ForEach(candidates, id: \.self) { address in
                        Button(address) {
                            text.wrappedValue = address
                            error = nil
                            editing = nil
                        }
                    }
                    Divider()
                    Button("自定义") { editing = field }
                        .accessibilityIdentifier(identifier + "Custom")
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title + "选项")
                .accessibilityIdentifier(identifier + "Presets")
            }
        }
    }
    private func save() {
        do {
            try flow.saveVPNConfiguration(localAddress: localAddress, peerAddress: peerAddress)
            localAddress = flow.vpnConfiguration.localAddress
            peerAddress = flow.vpnConfiguration.peerAddress
            error = nil; editing = nil
        } catch let failure as NCMControlError {
            if case .unavailable(let message) = failure { error = message }
        } catch {
            self.error = "请输入不同的有效 IPv4 地址"
        }
    }
}
