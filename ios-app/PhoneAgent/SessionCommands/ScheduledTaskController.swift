import Foundation
import Combine
import UIKit

/// A user-armed, process-local timer. It never claims a system wakeup grant.
@MainActor final class ScheduledTaskController: ObservableObject {
    @Published private(set) var tasks: [ScheduledPhoneTask] = []
    @Published private(set) var isArmed = false
    @Published private(set) var statusText = "自动执行已暂停"
    @Published private(set) var errorMessage: String?
    private let model: AgentViewModel
    private let commands: SessionCommandService
    private let store: TaskScheduleStore?
    private var timer: Task<Void, Never>?
    private var foreground = false
    private var protectedDataAvailable = false
    private var pauseReason: String?
    private let lateWindow: TimeInterval = 5 * 60

    init(model: AgentViewModel, commands: SessionCommandService) {
        self.model = model; self.commands = commands
        do {
            let isolated = ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.environment["PHONEAGENT_ISOLATED_TESTS"] == "1"
            let directory = isolated ? FileManager.default.temporaryDirectory.appendingPathComponent("ScheduledTasks-" + UUID().uuidString) : nil
            let storage = try TaskScheduleStore(directory: directory)
            let saved = try storage.load()
            try storage.save(saved)
            store = storage; tasks = saved
        } catch {
            store = nil
            errorMessage = "定时记录无法读取或保存；原文件已保留，自动执行不可用"
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }
    func clearError() { errorMessage = nil }
    func setForeground(_ active: Bool) {
        foreground = active
        updateIdleTimer()
        tick()
    }
    func setProtectedDataAvailable(_ available: Bool) {
        protectedDataAvailable = available
        if !available {
            stopOwnedRuns(reason: "手机已锁定，已请求停止；请核对本轮结果")
            if isArmed {
                isArmed = false; pauseReason = "手机已锁定，自动执行已暂停；解锁后请重新开启"
                updateIdleTimer()
            }
        }
        tick()
    }
    func setArmed(_ enabled: Bool) {
        guard enabled != isArmed else { return }
        if enabled {
            guard store != nil else { errorMessage = "定时记录不可用，请先处理存储问题"; return }
            guard foreground, protectedDataAvailable else { errorMessage = "请解锁手机并打开随办，再开启自动执行"; return }
            guard powerConnected else { errorMessage = "请接通电源，再开启自动执行"; return }
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { errorMessage = "请先关闭低电量模式，避免自动锁定限制"; return }
            var next = tasks
            let now = Date()
            for index in next.indices where next[index].isEnabled {
                if let due = next[index].nextRunAt, due <= now {
                    recordBlocked(in: &next[index], plannedAt: due, now: now,
                                  reason: "开启自动执行前已到期；没有补跑，请确认后手动执行")
                }
            }
            guard commit(next) else { return }
        }
        pauseReason = nil; isArmed = enabled
        updateIdleTimer(); tick()
    }
    @discardableResult func save(name: String, goal: String, requirements: String, firstRunAt: Date,
                                repetition: TaskScheduleRepeat, replacingID: UUID? = nil) -> Bool {
        guard let selection = model.providers.defaultSelection else { errorMessage = "请先在设置里选择供应商和模型"; return false }
        guard firstRunAt > Date() else { errorMessage = "请选择未来的执行时间"; return false }
        if let replacingID, let saved = tasks.first(where: { $0.id == replacingID }), saved.runs.contains(where: { $0.state.isActive }) {
            errorMessage = "请等待本轮结束后修改任务"; return false
        }
        do {
            try selection.profile.requireInference(model: selection.model)
            var value = ScheduledPhoneTask(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                requirements: requirements.trimmingCharacters(in: .whitespacesAndNewlines),
                firstRunAt: firstRunAt, timeZoneIdentifier: TimeZone.current.identifier,
                repetition: repetition, providerID: selection.profile.id, modelID: selection.model,
                providerEndpoint: try selection.profile.catalogEndpoint())
            try value.validate()
            guard let due = value.nextRunAt, due > Date() else { errorMessage = "请选择至少下一分钟的执行时间"; return false }
            var next = tasks
            if let replacingID {
                guard let index = next.firstIndex(where: { $0.id == replacingID }) else { errorMessage = "任务已不存在"; return false }
                value.id = replacingID; value.runs = next[index].runs
                value.isEnabled = next[index].isEnabled; value.needsReview = next[index].needsReview
                value.sourceConversationID = next[index].sourceConversationID
                value.sourceRunID = next[index].sourceRunID
                next[index] = value
            } else { next.insert(value, at: 0) }
            return commit(next)
        } catch {
            errorMessage = (error as? AppError)?.localizedDescription ?? "任务未保存，请检查目标、执行时间及设置中的模型"; return false
        }
    }
    /// Only exact human messages can authorize a plan. A reply supplying the
    /// missing time may continue the immediately previous human message; model
    /// goals, assistant text, attachments and observed instructions are excluded.
    func createFromConversation(proposal: ScheduleTaskProposal, request: String, identity: RunIdentity,
                                providerID: UUID, modelID: String, providerEndpoint: String) throws -> String {
        guard protectedDataAvailable,
              model.sessions.accepts(identity),
              let worker = model.existingExecutionModel(for: identity.conversationID),
              worker.ownedRun == identity, worker.running, !worker.stopping,
              let session = model.sessions.conversation(identity.conversationID),
              let currentIndex = session.messages.firstIndex(where: { $0.runID == identity.runID && $0.role == .user }) else {
            throw AppError.unavailable("当前用户请求已结束或手机已锁定，定时任务未创建")
        }
        let current = session.messages[currentIndex]
        guard (current.attachments ?? []).isEmpty else {
            throw AppError.invalid("定时任务暂不保存附件，请在消息中写明完整任务内容或手机内资料的位置")
        }
        let previous = session.messages[..<currentIndex].last(where: { $0.role == .user })
        let continuation = previous.flatMap { message -> String? in
            guard (message.attachments ?? []).isEmpty,
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let combined = message.text + "\n\n用户补充：\n" + current.text
            return combined.count <= 2_000 ? combined : nil
        }
        guard request == proposal.request, request.count <= 2_000,
              request == current.text || request == continuation else {
            throw AppError.invalid("任务内容只能使用这条完整用户消息，或无附件的上一条用户任务加本次时间补充；不能改写或引用其他内容")
        }
        if let saved = tasks.first(where: { $0.sourceRunID == identity.runID }) {
            guard saved.sourceConversationID == identity.conversationID else {
                throw AppError.invalid("任务来源不一致，定时任务未创建")
            }
            return try conversationReceipt(for: saved)
        }
        guard store != nil else { throw AppError.unavailable("定时记录不可用，任务未创建；请先处理存储问题") }
        let evidence = proposal.timeEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty, evidence.count <= 120, current.text.contains(evidence) else {
            throw AppError.invalid("执行时间必须来自你这条消息的原文；请补充明确的时间")
        }
        guard let profile = model.providers.profile(providerID),
              (try? profile.catalogEndpoint()) == providerEndpoint else {
            throw AppError.unavailable("本轮模型供应商已改变，任务未创建；请检查设置后重新发起")
        }
        try profile.requireInference(model: modelID)
        guard proposal.firstRunAt > Date() else { throw AppError.invalid("执行时间已经过去，请补充未来的明确时间") }
        var value = ScheduledPhoneTask(name: proposal.name, goal: request, requirements: "",
            firstRunAt: proposal.firstRunAt, timeZoneIdentifier: proposal.timeZoneIdentifier,
            repetition: proposal.repetition, providerID: providerID, modelID: modelID,
            providerEndpoint: providerEndpoint)
        value.sourceConversationID = identity.conversationID
        value.sourceRunID = identity.runID
        try value.validate()
        guard let due = value.nextRunAt, due > Date() else {
            throw AppError.invalid("执行时间需要至少到下一分钟，任务未创建；请补充未来的明确时间")
        }
        // Build the bounded public receipt before the durable write, so a
        // serialization error cannot make a successful creation look failed.
        let receipt = try conversationReceipt(for: value)
        guard commit([value] + tasks) else {
            throw AppError.unavailable(errorMessage ?? "定时任务未保存，请解锁手机后重试")
        }
        return receipt // No cancellation check after a successful durable write.
    }
    func isScheduledInvocation(commandID: UUID, runID: UUID) -> Bool {
        tasks.contains { task in
            task.runs.contains { run in
                guard run.id == commandID else { return false }
                if let savedRunID = run.runID { return savedRunID == runID }
                // Tool registration occurs inside execute(), before dispatch()
                // receives and persists the newly-started run's identity.
                guard run.dispatchAttempted, let sessionID = run.conversationID,
                      let entry = model.sessions.conversation(sessionID)?.entry else { return false }
                return entry.commandID == commandID && entry.runID == runID
            }
        }
    }
    private func conversationReceipt(for task: ScheduledPhoneTask) throws -> String {
        guard let zone = TimeZone(identifier: task.timeZoneIdentifier) else {
            throw AppError.invalid("任务时区不可用，请查看定时任务页面")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = zone
        let nextTime: Any = task.nextRunAt.map { formatter.string(from: $0) as Any } ?? NSNull()
        let receipt: [String: Any] = [
            "saved": true, "task_id": task.id.uuidString, "name": task.name,
            "next_run_at": nextTime, "repeat": task.repetition.rawValue,
            "time_zone": task.timeZoneIdentifier, "automatic_execution_enabled": isArmed,
            "notice": isArmed ? "计划已保存。到点会检查解锁、供电和操控连接；执行结果请查看定时任务。" :
                "计划已保存，自动执行模式尚未开启。请保持手机解锁，将系统自动锁定设为“永不”，接通电源后开启自动执行。"
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]), as: UTF8.self)
    }
    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var next = tasks
        if enabled, !next[index].isEnabled {
            guard let due = next[index].occurrence(after: Date()) else { errorMessage = "单次任务的时间已过，请编辑执行时间"; return }
            next[index].nextRunAt = due
        }
        next[index].isEnabled = enabled
        _ = commit(next); tick()
    }
    func acknowledgeReview(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].runs.contains(where: { $0.state.isActive }) else { return }
        var next = tasks; next[index].needsReview = false
        // Acknowledging old effects does not dispatch an overdue occurrence.
        if let due = next[index].nextRunAt, due <= Date() { next[index].nextRunAt = next[index].occurrence(after: Date()) }
        _ = commit(next)
    }
    func delete(id: UUID) {
        guard let value = tasks.first(where: { $0.id == id }) else { return }
        guard !value.runs.contains(where: { $0.state.isActive }) else { errorMessage = "请先停止当前运行，再删除计划"; return }
        _ = commit(tasks.filter { $0.id != id })
    }
    func reportMissingConversation() { errorMessage = "关联会话已清理，请查看本页执行记录并核对手机上的实际结果" }
    @discardableResult func executeNow(id: UUID) -> Bool {
        guard isArmed else { errorMessage = "请先开启自动执行模式"; return false }
        guard let task = tasks.first(where: { $0.id == id }) else { return false }
        guard !task.needsReview else { errorMessage = "请先查看并核对上一次运行的结果"; return false }
        guard !model.commandBusy else { errorMessage = "请等待当前任务或连接操作结束"; return false }
        guard let reason = readiness(for: task) else { return dispatch(id: id, plannedAt: Date(), scheduled: false) }
        errorMessage = reason; return false
    }
    func stopCurrentTask(id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        for run in task.runs where run.state.isActive {
            if let sessionID = run.conversationID, let runID = run.runID {
                _ = model.stop(run: RunIdentity(conversationID: sessionID, runID: runID))
            }
        }
    }
    private var powerConnected: Bool {
        UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isArmed && foreground
    }
    private func readiness(for task: ScheduledPhoneTask? = nil) -> String? {
        guard protectedDataAvailable else { return "等待手机解锁" }
        guard powerConnected else { return "等待接通电源" }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return "请关闭低电量模式" }
        guard !model.commandNeedsForeground else { return "请打开随办待命；系统未授予后台执行资格" }
        guard PairingFlow.shared.ready, !PairingFlow.shared.running, PairingFlow.shared.lastFailure == nil else {
            return "操控连接尚未验证，请在设置里的“连接与验证”完成验证"
        }
        if let task {
            guard let profile = model.providers.profile(task.providerID),
                  (try? profile.catalogEndpoint()) == task.providerEndpoint else { return "原模型供应商已移除或地址已改变，请重新编辑保存任务" }
            do { try profile.requireInference(model: task.modelID) }
            catch { return "保存的模型配置不可用，请在设置中检查后重新保存任务" }
        }
        return nil
    }
    private func tick() {
        if protectedDataAvailable { updateExecutions() }
        if isArmed, (!powerConnected || ProcessInfo.processInfo.isLowPowerModeEnabled) {
            stopOwnedRuns(reason: "供电或低电量条件已改变，已请求停止；请核对本轮结果")
            isArmed = false; pauseReason = "供电或低电量条件已改变，自动执行已暂停；恢复后请重新开启"
            updateIdleTimer()
        }
        let text = !isArmed ? (pauseReason ?? "自动执行已暂停；开启后在随办待命") :
            (readiness() ?? (model.commandBusy ? "等待当前任务结束" : "正在待命 · 到点自动执行"))
        if statusText != text { statusText = text }
        guard isArmed, protectedDataAvailable else { return }
        let now = Date()
        let due = tasks.filter { $0.isEnabled && !$0.needsReview && ($0.nextRunAt.map { $0 <= now } ?? false) }
            .sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
        for task in due {
            guard let planned = task.nextRunAt, let index = tasks.firstIndex(where: { $0.id == task.id }) else { continue }
            if task.runs.contains(where: { $0.plannedAt == planned }) {
                var next = tasks; next[index].nextRunAt = task.occurrence(after: now)
                _ = commit(next); continue
            }
            if now.timeIntervalSince(planned) > lateWindow {
                var next = tasks
                recordBlocked(in: &next[index], plannedAt: planned, now: now, reason: "已错过执行时间超过 5 分钟；未补跑，可确认后手动执行")
                _ = commit(next); continue
            }
            if model.commandBusy { return }
            if let reason = readiness(for: task) {
                var next = tasks
                recordBlocked(in: &next[index], plannedAt: planned, now: now, reason: reason + "；本轮未开始，可就绪后手动执行")
                _ = commit(next); continue
            }
            _ = dispatch(id: task.id, plannedAt: planned, scheduled: true)
            return // One phone, one complete run at a time.
        }
    }
    private func recordBlocked(in task: inout ScheduledPhoneTask, plannedAt: Date, now: Date, reason: String) {
        var run = ScheduledTaskRun(plannedAt: plannedAt)
        run.state = .blocked; run.completedAt = now; run.detail = reason
        task.runs.insert(run, at: 0); task.runs = Array(task.runs.prefix(20))
        task.nextRunAt = task.occurrence(after: now)
    }
    @discardableResult private func dispatch(id: UUID, plannedAt: Date, scheduled: Bool) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let definition = tasks[index]
        guard !definition.runs.contains(where: { $0.state.isActive }), !definition.needsReview,
              !model.commandBusy, readiness(for: definition) == nil else { return false }
        var next = tasks
        var run = ScheduledTaskRun(plannedAt: plannedAt)
        if scheduled { next[index].nextRunAt = definition.occurrence(after: Date()) }
        else if definition.repetition == .once { next[index].nextRunAt = nil }
        next[index].runs.insert(run, at: 0); next[index].runs = Array(next[index].runs.prefix(20))
        guard commit(next) else { return false } // Claim the occurrence before any submission.
        let command = SessionCommand(.prepare(definition.taskText), commandID: run.id, source: .app)
        do {
            guard case .prepared(let sessionID) = try commands.perform(command) else { throw SessionCommandError.startFailed }
            model.sessions.selectProvider(definition.providerID, model: definition.modelID, in: sessionID)
            model.sessions.saveNow()
            run.conversationID = sessionID
            run.dispatchAttempted = true
            next = tasks; next[index].runs[0] = run
            guard commit(next) else {
                try? model.sessions.dismissPreparedTask(in: sessionID)
                return false
            } // An uncertain submission cannot be retried after a crash.
            let execute = SessionCommand(.execute(definition.taskText), commandID: run.id, source: .app)
            guard case .started = try commands.perform(execute),
                  let identity = model.sessions.activeRuns[sessionID] else {
                // Readiness was checked synchronously; deferred commands are not an accepted schedule.
                commands.discardPendingExecution(commandID: run.id)
                throw SessionCommandError.startFailed
            }
            run.runID = identity.runID; run.startedAt = Date(); run.state = .running
            next = tasks; next[index].runs[0] = run
            guard commit(next) else { _ = model.stop(run: identity); return false }
            return true
        } catch {
            commands.discardPendingExecution(commandID: run.id)
            if let sessionID = run.conversationID { try? model.sessions.dismissPreparedTask(in: sessionID) }
            run.state = run.dispatchAttempted ? .interrupted : .blocked
            run.completedAt = Date()
            run.detail = (error as? SessionCommandError)?.localizedDescription ?? "任务未能提交，请查看连接、模型和会话记录"
            next = tasks; next[index].runs[0] = run
            if run.dispatchAttempted { next[index].needsReview = true }
            _ = commit(next)
            errorMessage = run.detail
            return false
        }
    }
    private func updateExecutions() {
        var next = tasks
        for index in next.indices {
            for position in next[index].runs.indices where next[index].runs[position].state.isActive {
                var run = next[index].runs[position]
                guard let sessionID = run.conversationID, let runID = run.runID,
                      let session = model.sessions.conversation(sessionID) else {
                    run.state = .interrupted; run.completedAt = Date()
                    run.detail = "关联会话或运行身份不可用；请核对实际结果，不会自动重放"
                    next[index].needsReview = true; next[index].runs[position] = run
                    continue
                }
                let identity = RunIdentity(conversationID: sessionID, runID: runID)
                if model.sessions.activeRuns[sessionID] == identity {
                    run.state = session.phase == .awaitingApproval ? .awaitingApproval : .running
                } else {
                    let uncertain = session.messages.contains { $0.runID == runID && $0.tool?.state == .outcomeUnknown }
                    run.state = session.phase == .completed && !uncertain ? .finished : (session.phase == .stopped ? .stopped : .interrupted)
                    run.completedAt = Date()
                    let outcome = session.messages.last(where: { $0.runID == runID && $0.role == .assistant && !$0.text.isEmpty })?.text ??
                        session.messages.last(where: { $0.runID == runID && $0.role == .notice })?.text ?? "请查看会话核对本轮实际结果"
                    run.detail = String(outcome.prefix(2_000))
                    if run.state != .finished { next[index].needsReview = true }
                }
                next[index].runs[position] = run
            }
        }
        if next != tasks { _ = commit(next) }
    }
    private func stopOwnedRuns(reason: String) {
        for task in tasks {
            for run in task.runs where run.state.isActive {
                if let sessionID = run.conversationID, let runID = run.runID {
                    let identity = RunIdentity(conversationID: sessionID, runID: runID)
                    if model.stop(run: identity) { model.sessions.addNotice(reason, in: sessionID) }
                }
            }
        }
    }
    @discardableResult private func commit(_ next: [ScheduledPhoneTask]) -> Bool {
        guard let store else { return false }
        do { try store.save(next); tasks = next; return true }
        catch {
            if let error = error as? AppError, case .invalid = error {
                errorMessage = error.localizedDescription; return false
            }
            isArmed = false; updateIdleTimer()
            stopOwnedRuns(reason: "定时记录未能保存，自动执行已暂停；请核对当前结果")
            errorMessage = "定时记录无法保存；原文件已保留，自动执行已暂停"
            return false
        }
    }
}
