import Foundation
#if DEBUG
import UIKit
#endif
#if DEBUG
import UIKit
#endif

/// There is one app process, one conversation store, and independently lifecycle-managed conversation runners.
@MainActor final class PhoneAgentRuntime {
    static let shared = PhoneAgentRuntime()
    let model: AgentViewModel
    let commands: SessionCommandService
    lazy var scheduledTasks = ScheduledTaskController(model: model, commands: commands)
    private init() {
        model = Self.makeModel()
        commands = SessionCommandService(sessions: model.sessions, runner: model)
        model.createConversationSchedule = { [weak self] proposal, identity, providerID, modelID, endpoint in
            guard let self else { throw AppError.stopped }
            return try self.scheduledTasks.createFromConversation(proposal: proposal, request: proposal.request,
                identity: identity, providerID: providerID, modelID: modelID, providerEndpoint: endpoint)
        }
        model.isScheduledInvocation = { [weak self] commandID, runID in
            self?.scheduledTasks.isScheduledInvocation(commandID: commandID, runID: runID) ?? false
        }
        applyLocalProviderSetupIfNeeded()
    }
    /// The local signer may add this file after CI; credentials never enter the repository.
    private func applyLocalProviderSetupIfNeeded() {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.environment["PHONEAGENT_ISOLATED_TESTS"] != "1",
              let url = Bundle.main.url(forResource: "LocalProviderSetup", withExtension: "json") else { return }
        struct Setup: Decodable {
            let id: UUID
            let name: String
            let baseURL: String
            let model: String
            let apiKey: String
        }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 16 * 1024 else { throw AppError.invalid("本机模型配置过大") }
            let setup = try JSONDecoder().decode(Setup.self, from: data)
            let marker = "localProviderSetup-applied-" + setup.id.uuidString
            guard !UserDefaults.standard.bool(forKey: marker) else { return }
            guard !setup.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !setup.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.invalid("本机模型配置不完整")
            }
            var profile = ProviderProfile(id: setup.id, name: setup.name,
                settings: .init(baseURL: setup.baseURL, model: setup.model))
            profile.protocolKind = .openAI
            profile.inferenceKind = .chatCompletions
            guard model.saveProvider(profile, key: setup.apiKey) else { return }
            try model.providers.rememberSelection(providerID: profile.id, model: setup.model)
            UserDefaults.standard.set(true, forKey: marker)
        } catch {
            // Do not include decoding details: the input contains a credential.
            model.errorMessage = "本机模型配置未保存，请在设置中重新填写"
        }
    }
    #if DEBUG
    private var invokedLiveTaskProbe = false
    private var waitingLiveTaskProbe = false
    /// Explicit real-provider acceptance. It observes only its new command/run;
    /// it never selects a route, supplies credentials or resumes a saved task.
    func runLiveTaskProbeIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--live-task-verification"), !invokedLiveTaskProbe, !waitingLiveTaskProbe else { return }
        waitingLiveTaskProbe = true
        defer { waitingLiveTaskProbe = false }
        let goalIndex = arguments.firstIndex(of: "--live-task-goal")
        let goal = goalIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = URL.documentsDirectory.appending(path: "live-task-verification.log")
        let began = Date()
        var lines: [String] = [], logWritable = true
        func publicText(_ value: String) -> String {
            var safe = goal.isEmpty ? value : value.replacingOccurrences(of: goal, with: "[task text omitted]")
            for pattern in [#"https?://[^\s\"<>]+"#,
                            #"(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/-]+"#,
                            #"(?i)\b(?:api[_ -]?key|token|password|secret|authorization)\s*[:=]\s*[^\s,;]+"#,
                            #"\b[A-Za-z0-9_-]{32,}(?:\.[A-Za-z0-9_-]+)*\b"#] {
                safe = safe.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
            }
            return String(safe.replacingOccurrences(of: "\n", with: " | ").replacingOccurrences(of: "\r", with: " ").prefix(800))
        }
        func record(_ value: String) {
            lines.append(String(format: "%.3f ", Date().timeIntervalSince(began)) + publicText(value))
            lines = Array(lines.suffix(128))
            do { try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: [.atomic, .completeFileProtection]) }
            catch { logWritable = false }
        }
        record("probe.begin goal_bytes=\(goal.utf8.count)")
        guard logWritable else { return }
        guard !goal.isEmpty, !goal.hasPrefix("--"), goal.utf8.count <= 2_000 else { record("probe.rejected invalid_goal"); return }
        guard !arguments.contains("--ui-testing"), !arguments.contains("--task-pip-probe"),
              ProcessInfo.processInfo.environment["PHONEAGENT_ISOLATED_TESTS"] != "1" else {
            record("probe.rejected fixture_runtime"); return
        }
        let foregroundDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while UIApplication.shared.applicationState != .active || !UIApplication.shared.isProtectedDataAvailable || !model.commandCanStart {
            guard !Task.isCancelled, ContinuousClock.now < foregroundDeadline else {
                record("probe.rejected foreground_or_unlock_not_ready"); return
            }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { record("probe.cancelled before_start"); return }
        }
        guard !model.hasBusySessions, !model.isListening, !PairingFlow.shared.running,
              !PairingFlow.shared.agentReserved, !BluetoothHIDTransport.shared.busy else {
            record("probe.rejected existing_operation_busy"); return
        }
        invokedLiveTaskProbe = true
        if let selection = model.providers.defaultSelection {
            record("provider name=\(selection.profile.name) model=\(selection.model)")
        } else { record("provider none_configured") }
        guard logWritable, !Task.isCancelled else { record("probe.cancelled before_command"); return }
        let command = SessionCommand(.execute(goal), source: .app)
        var started = false
        do {
            let result = try commands.perform(command)
            record("command.result=\(String(describing: result))")
            if case .started = result { started = true }
        } catch { record("command.failed public_error=\(error.localizedDescription)") }
        // A handoff that was not started must not execute after this probe exits.
        commands.discardPendingExecution(commandID: command.commandID)
        guard let session = model.sessions.conversations.first(where: { $0.entry?.commandID == command.commandID }),
              let worker = model.existingExecutionModel(for: session.id) else {
            record("probe.end new_session_or_worker_unavailable"); return
        }
        if let profile = model.selectedProvider(in: session.id) {
            record("session.provider name=\(profile.name) model=\(model.selectedModel(in: session.id))")
        }
        if let error = worker.errorMessage { record("session.public_error=\(error)") }
        guard started, let identity = worker.ownedRun, identity.conversationID == session.id else {
            record("probe.end task_not_started phase=\(session.phase.rawValue)"); return
        }
        var lastStatus = "", lastError = "", runChanged = false
        var observedTools: [String: String] = [:], observedReplies: Set<UUID> = []
        func observe() {
            guard let current = model.sessions.conversation(session.id) else { return }
            guard !current.messages.contains(where: { $0.role == .user && $0.runID != identity.runID }) else {
                if !runChanged { record("probe.run_changed"); runChanged = true }
                return
            }
            let status = "run phase=\(current.phase.rawValue) running=\(worker.running) stopping=\(worker.stopping) status=\(worker.status)"
            if status != lastStatus { lastStatus = status; record(status) }
            if let error = worker.errorMessage, error != lastError { lastError = error; record("run.public_error=\(error)") }
            for (index, message) in current.messages.enumerated() where message.runID == identity.runID {
                if let tool = message.tool {
                    var result = "result_bytes=\(tool.result.utf8.count) contents=not_logged"
                    if [.failed, .denied, .cancelled, .interrupted, .outcomeUnknown].contains(tool.state) {
                        result = "public_error=" + publicText(tool.displayResult)
                    } else if ["Command delivery acknowledged.", "Wait completed.", "本轮执行时间已确认：现在；可继续使用设备工具"].contains(tool.result) {
                        result = "public_result=" + tool.result
                    } else if tool.name == "screenshot", let data = tool.result.data(using: .utf8),
                              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let width = frame["width"] as? Int, let height = frame["height"] as? Int {
                        result = "frame=\(width)x\(height) demo=\(frame["is_demo"] as? Bool ?? false)"
                    } else if tool.name == "list_apps", let data = tool.result.data(using: .utf8),
                              let apps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        result = "app_count=\(apps.count) names=not_logged"
                    }
                    let observation = "tool step=\(index) name=\(tool.name) state=\(tool.state.rawValue) \(result)"
                    if observedTools[tool.callID] != observation { observedTools[tool.callID] = observation; record(observation) }
                } else if message.role == .assistant, message.state != .streaming, !observedReplies.contains(message.id) {
                    observedReplies.insert(message.id)
                    record("assistant.public_result state=\(message.state.rawValue) bytes=\(message.text.utf8.count) contents=not_logged")
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while !Task.isCancelled, logWritable, ContinuousClock.now < deadline {
            observe()
            if !worker.running && !worker.stopping { break }
            if runChanged { break }
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { break }
        }
        observe()
        if worker.ownedRun == identity, worker.running {
            record("probe.stop_requested reason=\(Task.isCancelled ? "cancelled" : logWritable ? "deadline" : "log_unavailable")")
            record("probe.stop_accepted=\(model.stop(run: identity))")
        }
        // A fresh cleanup task can still wait when the caller's task was cancelled.
        let released = await Task { @MainActor in
            let stopDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while worker.stopping, ContinuousClock.now < stopDeadline {
                if let current = worker.ownedRun, current != identity { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return !worker.stopping && !worker.running
        }.value
        observe()
        let finalPhase = runChanged ? "superseded" : model.sessions.conversation(session.id)?.phase.rawValue ?? "missing"
        record("probe.end phase=\(finalPhase) release_confirmed=\(released)")
    }

    private var invokedSiriFixture = false
    func invokeSiriFixtureIfNeeded(busy: Bool) async {
        let arguments = ProcessInfo.processInfo.arguments
        let flag = busy ? "--ui-test-siri-busy" : "--ui-test-siri-warm"
        guard arguments.contains("--ui-testing"), arguments.contains(flag), !invokedSiriFixture else { return }
        invokedSiriFixture = true
        let intent = PrepareAgentTaskIntent(); intent.task = "查看演示计数器"
        do { _ = try await intent.perform() }
        catch { model.errorMessage = error.localizedDescription }
    }
    #endif
    #if DEBUG
    private var delayedBackgroundUIRun: RunIdentity?
    func completeBackgroundUIFixtureIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--ui-test-background-completion"),
              let run = model.sessions.activeRun else { return }
        model.sessions.completeAssistantTurn("后台任务最终回复", identity: run)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-background-auto-route") {
            model.openActivityURL(AgentActivityRoute(sessionID: run.conversationID, runID: run.runID).url)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-background-delayed-finish") {
            delayedBackgroundUIRun = run
        } else { model.sessions.finish(run, phase: .completed, summary: "") }
    }
    func finishForegroundUIFixtureIfNeeded() {
        guard let run = delayedBackgroundUIRun else { return }
        delayedBackgroundUIRun = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            model.sessions.finish(run, phase: .completed, summary: "")
        }
    }
    #endif
    private static func makeModel() -> AgentViewModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--task-pip-probe") {
            let sessions = ConversationStore(inMemory: true)
            let id = sessions.create(mode: .demo)
            let streamProbe = ProcessInfo.processInfo.arguments.contains("--background-stream-probe")
            if streamProbe, let run = sessions.begin(in: id, query: "离线后台流式更新验证") {
                for index in 0..<30 {
                    sessions.beginAssistantTurn(run)
                    sessions.completeAssistantTurn("", reasoning: String(repeating: "离线思考内容。", count: 100), identity: run)
                    sessions.updateTool(callID: "seed-\(index)", name: "drag", state: .succeeded, result: "Synthetic receipt.", identity: run)
                }
                sessions.finish(run, phase: .completed, summary: "")
            }
            let primary: any RunBackgroundScheduler = ProcessInfo.processInfo.arguments.contains("--activity-probe-no-system")
                ? ActivityOnlyProbeScheduler() : ContinuedProcessingScheduler()
            let lifecycle = RunLifecycleCoordinator(
                scheduler: streamProbe ? MediaOnlyRunScheduler() : PiPBackedRunScheduler(primary: primary),
                storage: MemoryRunCheckpointStore())
            return AgentViewModel(sessions: sessions, loadPersistentState: false,
                runServices: .init(provider: TaskPiPProbeProvider(), bridge: DemoBridge()),
                lifecycle: lifecycle, liveActivitiesEnabled: true)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.environment["PHONEAGENT_ISOLATED_TESTS"] == "1" {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-test-reasoning-seed") || arguments.contains("--ui-test-reasoning-restore") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentReasoningUITest", isDirectory: true)
                if arguments.contains("--ui-test-reasoning-seed") { try? FileManager.default.removeItem(at: directory) }
                let sessions = ConversationStore(directory: directory)
                if sessions.conversations.isEmpty { sessions.create(mode: .live) }
                let outcome = arguments.contains("--ui-test-reasoning-paused") ? "paused" : (arguments.contains("--ui-test-reasoning-failed") ? "failed" : "completed")
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: ReasoningFixtureProvider(outcome: outcome), bridge: UnavailableBridge()))
            }
            if arguments.contains("--ui-test-images-seed") || arguments.contains("--ui-test-images-restore") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentImageUITest", isDirectory: true)
                if arguments.contains("--ui-test-images-seed") { try? FileManager.default.removeItem(at: directory) }
                let sessions = ConversationStore(directory: directory)
                if sessions.conversations.isEmpty { sessions.create(mode: .demo) }
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()),
                    attachments: AttachmentStore(directory: directory.appendingPathComponent("assets")))
            }
            if arguments.contains("--ui-test-siri-seed") || arguments.contains("--ui-test-siri-restore") {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneAgentSiriUITest", isDirectory: true)
                if arguments.contains("--ui-test-siri-seed") { try? FileManager.default.removeItem(at: directory) }
                let sessions = ConversationStore(directory: directory)
                if arguments.contains("--ui-test-siri-seed") {
                    _ = try? sessions.prepare(SessionCommand(.prepare("查看演示计数器")), task: "查看演示计数器")
                }
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()))
            }
            let sessions = ConversationStore(inMemory: true)
            if arguments.contains("--ui-test-turn-summaries") {
                let id = sessions.create(mode: .live)
                if let run = sessions.begin(in: id, query: "汇总验收") {
                    for index in 1...2 {
                        sessions.beginAssistantTurn(run)
                        sessions.completeAssistantTurn("中间答复\(index)", reasoning: "第\(index)段思考内容", identity: run)
                        sessions.updateTool(callID: "summary-\(index)", name: "wait", state: .succeeded, result: "已等待", identity: run)
                    }
                    sessions.beginAssistantTurn(run)
                    sessions.completeAssistantTurn("汇总后的最终答复", identity: run)
                    sessions.finish(run, phase: .completed, summary: "")
                }
                if let run = sessions.begin(in: id, query: "只有正文") {
                    sessions.beginAssistantTurn(run)
                    sessions.completeAssistantTurn("没有工具和思考的答复", identity: run)
                    sessions.finish(run, phase: .completed, summary: "")
                }
                return AgentViewModel(sessions: sessions, loadPersistentState: false)
            }
            if arguments.contains("--ui-test-provider-key") {
                var keys: [String: String] = [:]
                let model = AgentViewModel(sessions: sessions, loadPersistentState: false,
                    writeProviderKey: { keys[$1] = $0 }, containsProviderKey: { keys[$0] != nil })
                _ = model.saveProvider(ProviderProfile(name: "Key Fixture", settings: .init(baseURL: "https://fixture.invalid/v1", model: "fixture")), key: "UI_TEST_ONLY_NOT_A_REAL_KEY")
                return model
            }
            if arguments.contains("--ui-test-disclosure-scroll") {
                let id = sessions.create(mode: .live)
                for index in 0..<20 { sessions.addNotice("展开滚动验收 \(index)\n本地历史记录", in: id) }
                if let run = sessions.begin(in: id, query: "展开位置验收") {
                    sessions.beginAssistantTurn(run)
                    sessions.completeAssistantTurn("", reasoning: String(repeating: "长思考内容用于验证展开时保留阅读位置。\n", count: 100), identity: run)
                    sessions.updateTool(callID: "disclosure-tool", name: "list_apps", state: .succeeded,
                        result: String(repeating: "长工具结果用于验证展开时保留阅读位置。\n", count: 100) + "工具结果末尾标记", arguments: "{}", identity: run)
                    sessions.finish(run, phase: .completed, summary: "")
                }
                return AgentViewModel(sessions: sessions, loadPersistentState: false)
            }
            if arguments.contains("--ui-test-skill-tools") {
                sessions.create(mode: .live)
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: SkillFixtureProvider(), bridge: UnavailableBridge()))
            }
            if arguments.contains("--ui-test-attachments") {
                let id = sessions.create(mode: .demo)
                let model = AgentViewModel(sessions: sessions, loadPersistentState: false)
                model.selectConversation(id)
                Task { @MainActor in
                    let frame = try? await DemoBridge().screenshot()
                    if let frame { try? await model.importDraftAttachment(data: frame.png, name: "synthetic.png", in: id) }
                    try? await model.importDraftAttachment(data: Data("Synthetic file contents".utf8), name: "synthetic.md", in: id)
                }
                return model
            }
            if arguments.contains("--ui-test-new-conversation") {
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: ReasoningFixtureProvider(), bridge: UnavailableBridge()))
            }
            if arguments.contains("--ui-test-composer-models") {
                let model = AgentViewModel(sessions: sessions, loadPersistentState: false)
                try? model.providers.save(ProviderProfile(name: "Fixture One", settings: .init(baseURL: "https://fixture.invalid/v1", model: "model-a")))
                try? model.providers.save(ProviderProfile(name: "Fixture Two", settings: .init(baseURL: "https://fixture.invalid/v1", model: "model-b"), models: ["model-b-alt"]))
                return model
            }
            if arguments.contains("--ui-test-background-completion") {
                let id = sessions.create(mode: .live)
                if let run = sessions.begin(in: id, query: "后台完成刷新验收") {
                    for index in 0..<30 {
                        sessions.beginAssistantTurn(run)
                        sessions.completeAssistantTurn("中间回复 \(index)", reasoning: String(repeating: "合成思考内容。", count: 60), identity: run)
                        sessions.updateTool(callID: "background-\(index)", name: "wait", state: .succeeded, result: "Synthetic receipt.", identity: run)
                    }
                    sessions.beginAssistantTurn(run)
                    sessions.appendText("等待后台完成", identity: run)
                }
                return AgentViewModel(sessions: sessions, loadPersistentState: false)
            }
            if arguments.contains("--ui-test-composer-history") {
                let id = sessions.create(mode: .live)
                if arguments.contains("--ui-test-conversation-navigation"), let run = sessions.begin(in: id, query: "新会话") {
                    sessions.finish(run, phase: .completed, summary: "")
                }
                for index in 0..<30 {
                    sessions.addNotice("滚动验收 \(index)\n保持键盘开合前后的底部可见内容\n这是仅用于 UI 验收的本地记录", in: id)
                }
                sessions.addNotice("滚动验收最后一条消息", in: id)
                return AgentViewModel(sessions: sessions, loadPersistentState: false)
            }
            if arguments.contains("--ui-test-model-catalog") {
                let model = AgentViewModel(sessions: sessions, loadPersistentState: false)
                try? model.providers.save(ProviderProfile(name: "Catalog Fixture", settings: .init(baseURL: "https://catalog-fixture.invalid/v1", model: "")))
                return model
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-tool-error") {
                sessions.create(mode: .live)
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: ToolErrorFixtureProvider(), bridge: UnavailableBridge()))
            }
            // Existing demo history keeps UI regression tests offline without
            // exposing a demo-creation route in the production conversation UI.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               (arguments.contains("--ui-test-demo-history") || arguments.contains("--ui-test-siri-busy")) {
                sessions.create(mode: .demo)
            }
            if arguments.contains("--ui-test-siri-warm") || arguments.contains("--ui-test-siri-busy") {
                return AgentViewModel(sessions: sessions, loadPersistentState: false,
                    runServices: AgentRunServices(provider: DemoProvider(), bridge: DemoBridge()))
            }
            return AgentViewModel(sessions: sessions, loadPersistentState: false,
                liveActivitiesEnabled: arguments.contains("--ui-test-live-activity"))
        }
        #endif
        return AgentViewModel()
    }
}

#if DEBUG
/// Finite UIKit handoff only; intentionally creates no system progress card.
/// Used with the offline fixture to test the custom WidgetKit presentation alone.
@MainActor private final class ActivityOnlyProbeScheduler: RunBackgroundScheduler {
    private var leases: [String: ExecutionTransitionLease] = [:]
    func submit(identifier: String, launched: @escaping @MainActor (any RunBackgroundLease) -> Void) throws {
        let lease = ExecutionTransitionLease()
        lease.begin()
        guard lease.valid else { throw AppError.unavailable("诊断任务未获得有限后台时间") }
        leases[identifier] = lease
        BackgroundExecutionTrace.record("activity.probeUIKitOnly")
        launched(lease)
    }
    func cancel(identifier: String) { leases.removeValue(forKey: identifier)?.complete(success: false) }
}
#endif
