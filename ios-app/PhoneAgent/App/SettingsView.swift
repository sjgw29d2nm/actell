import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject private var providers: ProviderStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BackgroundPlaybackMode.defaultsKey) private var backgroundMode = BackgroundPlaybackMode.defaultMode.rawValue
    @AppStorage(BackgroundPlaybackMode.residentDefaultsKey) private var backgroundResident = false
    @State private var control = PairingFlow.shared
    @State private var clear = false
    @State private var clearAssets = false
    @State private var assetStatus = ""
    @State private var browsingModels = false
    @State private var selectionFailure: String?
    init(model: AgentViewModel) { self.model = model; providers = model.providers }
    private var selection: (profile: ProviderProfile, model: String)? { providers.defaultSelection }
    private var selectedModelName: String {
        guard let name = selection?.model, !name.isEmpty else { return "未选择" }
        return name
    }
    private var modelMenuOptions: [String] {
        var models = Array((selection?.profile.availableModels ?? []).prefix(12))
        if let selected = selection?.model, !selected.isEmpty, !models.contains(selected) { models.append(selected) }
        return models
    }
    private var reasoningMetadata: DiscoveredModel? { selection.flatMap { $0.profile.metadata(for: $0.model) } }
    private var reasoningEffort: String? { selection.flatMap { $0.profile.parameters(for: $0.model).reasoningEffort } }
    private var reasoningDefaultLabel: String {
        reasoningMetadata?.defaultReasoningEffort.map { "服务商默认（\($0)）" } ?? "服务商默认"
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image("BrandLogo").renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 82, height: 28).foregroundStyle(.primary).accessibilityLabel("随办")
                        Text("说出目标，一起把事情办好").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section {
                    Menu {
                        ForEach(providers.profiles) { profile in
                            Button { rememberSelection(profile.settings.model, providerID: profile.id) } label: {
                                Text(profile.name + (profile.id == selection?.profile.id ? "  ✓" : ""))
                            }
                        }
                    } label: {
                        modelSettingRow("供应商", value: selection?.profile.name ?? "未配置")
                    }.disabled(model.hasBusySessions || providers.profiles.isEmpty)
                        .accessibilityIdentifier("settingsProviderRow")
                        .accessibilityLabel("供应商").accessibilityValue(selection?.profile.name ?? "未配置")
                    Menu {
                        ForEach(modelMenuOptions, id: \.self) { name in
                            Button { if let profile = selection?.profile { rememberSelection(name, providerID: profile.id) } } label: {
                                Text(name + (name == selection?.model ? "  ✓" : ""))
                            }
                        }
                        Button("浏览全部模型") { browsingModels = true }
                    } label: {
                        modelSettingRow("模型", value: selectedModelName)
                    }.disabled(model.hasBusySessions || selection == nil)
                        .accessibilityIdentifier("settingsModelRow")
                        .accessibilityLabel("模型").accessibilityValue(selectedModelName)
                    Menu {
                        Button(reasoningDefaultLabel) { selectReasoningEffort(nil) }
                        ForEach(reasoningMetadata?.reasoningEfforts ?? [], id: \.self) { effort in
                            Button { selectReasoningEffort(effort) } label: {
                                Text(effort + (effort == reasoningEffort ? "  ✓" : ""))
                            }
                        }
                    } label: {
                        modelSettingRow("思考强度", value: reasoningEffort ?? reasoningDefaultLabel)
                    }.disabled(model.hasBusySessions || selection == nil)
                        .accessibilityIdentifier("settingsReasoningEffort")
                        .accessibilityLabel("思考强度").accessibilityValue(reasoningEffort ?? reasoningDefaultLabel)
                    NavigationLink { ProvidersView(model: model) } label: {
                        Label("管理供应商", systemImage: "cpu")
                    }.accessibilityIdentifier("openProviders")
                    if let selectionFailure { Text(selectionFailure).font(.caption).foregroundStyle(.orange) }
                } header: {
                    Text("模型")
                } footer: {
                    Text("新会话会自动使用这里选择的模型。")
                }.menuOrder(.fixed)
                Section("手机操控") {
                    Picker("连接模式", selection: Binding(get: { control.route }, set: { _ = control.selectRoute($0) })) {
                        Text(DeviceControlRoute.vpnLoopback.title).tag(DeviceControlRoute.vpnLoopback)
                        Text(DeviceControlRoute.ncmDeveloper.title).tag(DeviceControlRoute.ncmDeveloper)
                    }.disabled(model.hasBusySessions || !control.canChangeRoute)
                        .accessibilityIdentifier("deviceControlMode")
                    if control.route == .vpnLoopback {
                        NavigationLink { ESP32ControlSettingsView() } label: {
                            Label("VPN 回环配置与验证", systemImage: "iphone")
                        }.accessibilityIdentifier("esp32ControlSettings")
                    }
                    NavigationLink { HardwareWirelessSettingsView() } label: {
                        Label("硬件设置", systemImage: "cable.connector")
                    }.accessibilityIdentifier("suibanHardwareSettings")
                }
                Section {
                    Picker("后台运行方式", selection: $backgroundMode) {
                        ForEach(BackgroundPlaybackMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }.accessibilityIdentifier("backgroundPlaybackMode")
                    Toggle("后台常驻", isOn: $backgroundResident)
                        .accessibilityIdentifier("backgroundResidentEnabled")
                } header: {
                    Text("后台执行")
                } footer: {
                    Text(backgroundMode == BackgroundPlaybackMode.systemTask.rawValue
                         ? "系统任务会显示系统进度。开启常驻后，空闲时用音频等待新任务。"
                         : "开启后，无任务时也保持所选后台模式。")
                    Text("自动执行模式开启期间也会保持待命；系统挂起或锁屏仍可能中断任务。")
                    Text("这里选择后台待命方式。发起任务请在对话输入，或通过 Siri／快捷指令；定时任务到点由随办启动。")
                }
                Section("扩展能力") {
                    NavigationLink { SkillsView(model: model, store: model.skills) } label: {
                        Label("技能", systemImage: "sparkles")
                    }.accessibilityIdentifier("manageSkills")
                }
                Section("本地记录") {
                    Button("清空本地会话与任务记录", role: .destructive) { clear = true }
                        .disabled(model.hasBusySessions)
                    Button("清理未引用附件", role: .destructive) { clearAssets = true }
                        .disabled(model.hasBusySessions).accessibilityIdentifier("clearUnusedAttachments")
                    if !assetStatus.isEmpty { Text(assetStatus).font(.caption) }
                }
                if let warning = model.storageWarning { Text(warning).foregroundStyle(.orange) }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: $browsingModels) {
                if let profile = selection?.profile {
                    ProviderModelPicker(profile: profile) { rememberSelection($0, providerID: profile.id) }
                }
            }
            .confirmationDialog("删除本机保存的任务和结果？无法在 App 内恢复。", isPresented: $clear, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) { model.clearHistory() }
            }
            .alert("清理未引用附件？", isPresented: $clearAssets) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    Task {
                        do { assetStatus = "已清理 \(try await model.clearUnreferencedAttachments()) 个未引用文件" }
                        catch { assetStatus = "未能清理附件；原文件保留" }
                    }
                }
            } message: { Text("现有消息与草稿引用的原图和文件会保留。未引用文件删除后无法恢复。") }
        }
    }
    private func modelSettingRow(_ title: String, value: String) -> some View {
        HStack(spacing: 16) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
    private func rememberSelection(_ name: String, providerID: UUID) {
        guard !model.hasBusySessions else { return }
        do {
            try providers.rememberSelection(providerID: providerID, model: name)
            selectionFailure = nil
        } catch { selectionFailure = error.localizedDescription }
    }
    private func selectReasoningEffort(_ effort: String?) {
        guard !model.hasBusySessions, let selection else { return }
        var profile = selection.profile
        var parameters = profile.parameters(for: selection.model)
        parameters.reasoningEffort = effort
        if profile.modelParameters == nil { profile.modelParameters = [:] }
        profile.modelParameters?[selection.model] = parameters
        selectionFailure = model.saveProvider(profile, key: "") ? nil : model.errorMessage
    }
}
