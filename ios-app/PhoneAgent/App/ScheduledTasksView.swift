import SwiftUI
import UIKit

struct ScheduledTasksView: View {
    @ObservedObject var controller: ScheduledTaskController
    let openConversation: (UUID) -> Void
    let startConversation: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editingTask: ScheduledPhoneTask?
    @State private var settingsHint: String?
    private let sameAppExample = "每天晚上8点在提醒事项中整理当天到期与逾期待办，按截止时间排序并给我汇总，不修改原待办"
    private let crossAppExample = "每周五晚上6点在Safari查上海周末天气，在备忘录创建注明日期的出行清单并核对保存"

    init(controller: ScheduledTaskController, openConversation: @escaping (UUID) -> Void,
         startConversation: @escaping (String?) -> Void) {
        self.controller = controller
        self.openConversation = openConversation
        self.startConversation = startConversation
    }

    var body: some View {
        List {
            Section {
                Toggle("自动执行模式", isOn: Binding(get: { controller.isArmed }, set: { controller.setArmed($0) }))
                    .accessibilityIdentifier("scheduledAutomaticMode")
                Text(controller.statusText).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("scheduledModeStatus")
            } footer: {
                Text("开启后，随办会在运行条件满足时执行到期任务。关闭、锁屏、断电或进入低电量模式后会暂停自动执行；恢复条件或重新启动随办后，需要重新开启。")
            }
            readinessSection
            Section {
                if controller.tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("在对话里安排任务").font(.headline)
                        Text("直接在对话里说明目标和时间，随办会生成安排；这里查看、修改和停用。同一个 App 内的多步操作和跨 App 办事都可以安排。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("去对话安排") { startConversation(nil) }.padding(.top, 4)
                            .accessibilityIdentifier("scheduledStartConversation")
                    }.padding(.vertical, 8)
                }
                ForEach(controller.tasks, id: \.id) { task in
                    NavigationLink {
                        ScheduledTaskDetailView(controller: controller, taskID: task.id,
                                                openConversation: openConversation) { edit($0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(task.name).font(.headline)
                                if !task.isEnabled { Text("已停用").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(task.goal).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Text(nextRunDescription(task)).font(.caption)
                            Text("\(task.repetition.title) · \(task.timeZoneIdentifier)")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let run = task.runs.first {
                                Text(run.state.title).font(.caption)
                                    .foregroundStyle(run.state.isActive ? Color.accentColor : Color.secondary)
                                if !run.detail.isEmpty { Text(run.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("scheduledTask-" + task.id.uuidString)
                }
                if !controller.tasks.isEmpty {
                    Button("去对话安排新任务") { startConversation(nil) }
                        .accessibilityIdentifier("scheduledStartConversation")
                }
            } header: { Text("任务安排") }
            if controller.tasks.isEmpty {
                Section {
                    Button { startConversation(sameAppExample) } label: {
                        Text(sameAppExample).multilineTextAlignment(.leading)
                    }.accessibilityIdentifier("scheduledExampleSameApp")
                    Button { startConversation(crossAppExample) } label: {
                        Text(crossAppExample).multilineTextAlignment(.leading)
                    }.accessibilityIdentifier("scheduledExampleCrossApp")
                } header: { Text("试着这样说") } footer: {
                    Text("示例只会填入对话；发送后随办再根据你的目标和时间生成安排。")
                }
            }
        }
        .navigationTitle("任务安排").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        }
        .sheet(item: $editingTask) { task in
            ScheduledTaskEditor(controller: controller, task: task)
        }
        .alert("未能完成操作", isPresented: Binding(
            get: { controller.errorMessage != nil && editingTask == nil },
            set: { if !$0 { controller.clearError() } }
        )) { Button("好") { controller.clearError() } } message: { Text(controller.errorMessage ?? "请稍后重试。") }
    }

    private var readinessSection: some View {
        Section {
            Label("手机需插电并保持解锁", systemImage: "iphone")
                .font(.subheadline.weight(.semibold))
            Text("设置 → 显示与亮度 → 自动锁定 → 永不")
                .font(.subheadline).accessibilityIdentifier("scheduledAutoLockInstructions")
            Text("自动执行模式会在随办内保持亮屏。任务切换到其他 App 后，仍需要系统的“永不”设置。锁屏后页面操作会暂停，解锁后需核对再继续。")
                .font(.caption).foregroundStyle(.secondary)
            Text("请关闭低电量模式，它会限制自动锁定设置。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("随办权限设置", systemImage: "gear") { openSettings() }
                    .accessibilityIdentifier("scheduledOpenSettings")
                Spacer()
                Button("复制路径", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = "设置 → 显示与亮度 → 自动锁定 → 永不"
                    settingsHint = "设置路径已复制。"
                }.accessibilityIdentifier("scheduledCopySettingsPath")
            }.buttonStyle(.borderless)
            if let settingsHint { Text(settingsHint).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("执行前准备") } footer: {
            Text("“随办权限设置”打开随办的专属设置页。调整自动锁定请返回设置首页，进入“显示与亮度 → 自动锁定 → 永不”，完成后回到随办开启自动执行。")
        }
    }

    private func edit(_ task: ScheduledPhoneTask) { editingTask = task }
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            Task { @MainActor in
                settingsHint = success ? nil : "未能打开设置，请从手机桌面进入设置并按上述路径调整。"
            }
        }
    }
}

private struct ScheduledTaskDetailView: View {
    @ObservedObject var controller: ScheduledTaskController
    let taskID: UUID
    let openConversation: (UUID) -> Void
    let edit: (ScheduledPhoneTask) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var confirmingReview = false
    private var task: ScheduledPhoneTask? { controller.tasks.first { $0.id == taskID } }

    var body: some View {
        List {
            if let task {
                let active = task.runs.contains { $0.state.isActive }
                Section("任务内容") {
                    Text(task.goal).textSelection(.enabled)
                    if !task.requirements.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("要求与结果").font(.caption).foregroundStyle(.secondary)
                            Text(task.requirements).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    Toggle("启用后续执行", isOn: Binding(get: { task.isEnabled }, set: { controller.setEnabled($0, id: task.id) }))
                        .accessibilityIdentifier("scheduledTaskEnabled")
                    LabeledContent("重复", value: task.repetition.title)
                    LabeledContent("时区", value: task.timeZoneIdentifier)
                    Text(nextRunDescription(task)).font(.subheadline)
                    Button("编辑任务") { edit(task) }.disabled(active).accessibilityIdentifier("scheduledEdit")
                    if active {
                        Button("停止当前执行", role: .destructive) { controller.stopCurrentTask(id: task.id) }
                            .accessibilityIdentifier("scheduledStop")
                    } else {
                        Button("立即执行") { _ = controller.executeNow(id: task.id) }
                            .disabled(task.needsReview).accessibilityIdentifier("scheduledExecuteNow")
                    }
                } header: { Text("执行安排") } footer: { Text("停用后续执行不会停止已经开始的任务；需要停止时请点“停止当前执行”。") }
                if task.needsReview {
                    Section {
                        Text("上次执行需要核对").font(.headline)
                        Text("请查看已有会话和手机当前页面，确认哪些操作已经发生，再允许新的执行。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let conversationID = task.runs.first?.conversationID {
                            Button("查看上次会话") {
                                openConversation(conversationID)
                            }.accessibilityIdentifier("scheduledReviewConversation")
                        }
                        Button("我已核对，允许后续执行") { confirmingReview = true }
                            .accessibilityIdentifier("scheduledAcknowledgeReview")
                            .confirmationDialog("已核对上次会话与手机当前页面？", isPresented: $confirmingReview, titleVisibility: .visible) {
                                Button("已核对，允许后续执行") { controller.acknowledgeReview(id: task.id) }
                                Button("取消", role: .cancel) {}
                            } message: { Text("确认后允许新的执行。请先确认上次操作的实际结果，避免重复办理。") }
                    } header: { Text("继续前确认") }
                }
                Section("执行记录") {
                    if task.runs.isEmpty { Text("尚未执行").foregroundStyle(.secondary) }
                    ForEach(Array(task.runs.prefix(20)), id: \.id) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(run.state.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(scheduledDate(run.plannedAt, timeZone: task.timeZoneIdentifier))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !run.detail.isEmpty { Text(run.detail).font(.subheadline).foregroundStyle(.secondary) }
                            if let date = run.startedAt {
                                Text("开始：" + scheduledDate(date, timeZone: task.timeZoneIdentifier))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let date = run.completedAt {
                                Text("结束：" + scheduledDate(date, timeZone: task.timeZoneIdentifier))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let conversationID = run.conversationID {
                                Button("查看会话与结果") { openConversation(conversationID) }
                                    .accessibilityIdentifier("scheduledRunConversation-" + run.id.uuidString)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    Button("删除任务安排", role: .destructive) { confirmingDelete = true }
                        .disabled(active).accessibilityIdentifier("scheduledDelete")
                }
            } else { Text("此任务安排已删除。") }
        }
        .navigationTitle(task?.name ?? "任务详情").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除这个任务安排？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除任务", role: .destructive) {
                controller.delete(id: taskID)
                if task == nil { dismiss() }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("删除安排和本页执行记录，已有会话与结果仍保留。") }
    }
}

private struct ScheduledTaskEditor: View {
    @ObservedObject var controller: ScheduledTaskController
    let task: ScheduledPhoneTask
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var goal: String
    @State private var requirements: String
    @State private var firstRunAt: Date
    @State private var repetition: TaskScheduleRepeat

    init(controller: ScheduledTaskController, task: ScheduledPhoneTask) {
        self.controller = controller; self.task = task
        _name = State(initialValue: task.name)
        _goal = State(initialValue: task.goal)
        _requirements = State(initialValue: task.requirements)
        _firstRunAt = State(initialValue: max(task.nextRunAt ?? Date().addingTimeInterval(300), Date().addingTimeInterval(60)))
        _repetition = State(initialValue: task.repetition)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("任务名称", text: $name).accessibilityIdentifier("scheduledName")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("想完成什么").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $goal).frame(minHeight: 108).accessibilityIdentifier("scheduledGoal")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("要求与结果").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $requirements).frame(minHeight: 82).accessibilityIdentifier("scheduledRequirements")
                    }
                } header: { Text("任务内容") } footer: { Text("写清使用哪个 App、要处理哪些内容，以及结果是什么。同 App 内和跨 App 的多步任务都支持这样描述。") }
                Section("执行时间") {
                    DatePicker("下次执行", selection: $firstRunAt, displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("scheduledFirstRunAt")
                    Picker("重复", selection: $repetition) {
                        ForEach(TaskScheduleRepeat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("scheduledRepeat")
                    Text("保存时区：\(TimeZone.current.identifier)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Label("手机需插电并保持解锁", systemImage: "iphone")
                    Text("设置 → 显示与亮度 → 自动锁定 → 永不")
                        .font(.subheadline).foregroundStyle(.secondary)
                } footer: {
                    Text("保存即授权随办到时将任务和相关截图发送给已选择的模型执行。所选供应商与模型会随任务保存。受阻时会记录原因，中断后需要核对再执行。错过时间超过 5 分钟不会自动补跑。")
                }
            }
            .navigationTitle("编辑任务安排")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if controller.save(name: name, goal: goal, requirements: requirements,
                                           firstRunAt: firstRunAt, repetition: repetition, replacingID: task.id) { dismiss() }
                    }.accessibilityIdentifier("scheduledSave")
                }
            }
            .alert("未能保存任务", isPresented: Binding(
                get: { controller.errorMessage != nil }, set: { if !$0 { controller.clearError() } }
            )) { Button("好") { controller.clearError() } } message: { Text(controller.errorMessage ?? "请检查任务内容与执行时间。") }
        }
    }
}

private func nextRunDescription(_ task: ScheduledPhoneTask) -> String {
    if task.needsReview { return "等待核对上次执行结果" }
    if !task.isEnabled { return "后续执行已停用" }
    guard let date = task.nextRunAt else { return "暂无后续执行" }
    return "下次：" + scheduledDate(date, timeZone: task.timeZoneIdentifier)
}

private func scheduledDate(_ date: Date, timeZone: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
    formatter.dateStyle = .medium; formatter.timeStyle = .short
    return formatter.string(from: date)
}
