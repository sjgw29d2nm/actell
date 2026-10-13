import Foundation

struct RunIdentity: Hashable, Sendable {
    let conversationID: UUID
    let runID: UUID
}

struct StepIdentity: Hashable, Sendable {
    let run: RunIdentity
    let stepID: String
}

struct PresentedFrame: Sendable {
    let step: StepIdentity
    let image: FrameImage
}

enum ChatRole: String, Codable, Sendable { case user, assistant, tool, notice }
enum MessageState: String, Codable, Sendable { case complete, streaming, interrupted, failed }
enum ToolStepState: String, Codable, Sendable {
    case requested, running, awaitingApproval, approved, executing, succeeded, failed, denied, cancelled, interrupted, outcomeUnknown
    var isTerminal: Bool { [.succeeded, .failed, .denied, .cancelled, .interrupted, .outcomeUnknown].contains(self) }
    var label: String {
        switch self {
        case .requested: return "已请求"
        case .running, .executing: return "执行中"
        case .awaitingApproval: return "等待确认"
        case .approved: return "已批准"
        case .succeeded: return "已返回"
        case .failed: return "失败"
        case .denied: return "已拒绝"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        case .outcomeUnknown: return "结果未知"
        }
    }
}
struct ToolStep: Codable, Sendable, Equatable {
    var callID: String
    var name: String
    var state: ToolStepState
    var detail: String
    var result: String = ""
    // Optional keeps version-1 archives without parameter previews readable.
    // Only bounded public fields from our five registered tools are stored.
    var arguments: String?
    var skillName: String?
    var displayArguments: String? { Self.nonemptyArguments(arguments) }
    var displayResult: String {
        if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return result }
        switch state {
        case .cancelled: return "本次调用已取消，未保存调用结果。"
        case .interrupted: return "执行已中断，未保存调用结果。"
        case .outcomeUnknown: return "未保存送达确认；结果未知，未自动重发。"
        default: return ""
        }
    }
    static func nonemptyArguments(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) {
            if json is NSNull { return nil }
            if let object = json as? [String: Any], object.isEmpty { return nil }
            if let array = json as? [Any], array.isEmpty { return nil }
            if let string = json as? String, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        }
        return value
    }
    var symbol: String {
        if name == "schedule_task" || name == "run_task_now" { return "clock" }
        let operation = AgentActivityAttributes.Operation.tool(name)
        return operation == .processing ? "wrench.and.screwdriver" : operation.symbol
    }
    var title: String {
        switch name {
        case "screenshot": return "查看屏幕"
        case "tap": return "点击"
        case "drag": return "拖动"
        case "home": return "返回主屏幕"
        case "list_apps": return "查询 App"
        case "launch_app": return "启动 App"
        case "type_text": return "输入文本"
        case "wait": return "等待"
        case "schedule_task": return "安排任务"
        case "run_task_now": return "确认执行时间"
        case "finish": return "结束本轮"
        case "load_skill": return "加载技能" + (skillName.map { " · " + $0 } ?? "")
        default: return name
        }
    }
}
struct ReasoningMessage: Codable, Sendable, Equatable {
    var text: String
    var state: MessageState = .streaming
}
struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var runID: UUID?
    var role: ChatRole
    var text: String
    var date = Date()
    var state: MessageState = .complete
    var tool: ToolStep?
    var attachments: [StoredAttachment]?
    var reasoning: ReasoningMessage?
}
struct AgentConversation: Identifiable, Codable, Sendable {
    var id = UUID()
    var title = "新会话"
    var mode: RunMode
    var createdAt = Date()
    var updatedAt = Date()
    var entry: SessionEntry?
    var draft = ""
    var draftAttachments: [StoredAttachment]?
    var providerID: UUID?
    var modelID: String?
    var recoveryNotices: [String: String]?
    var phase: RunPhase = .idle
    var messages: [ChatMessage] = []
    var preview: String {
        if entry?.state == .pendingConfirmation { return "Siri · 待确认：" + draft }
        return messages.last(where: { $0.role == .user || $0.role == .assistant })?.text ?? "开始一个新的任务或问题"
    }
}

/// Presentation-only grouping; archives and model replay keep their original messages.
struct ConversationTurn: Identifiable {
    var messages: [ChatMessage]
    var id: UUID { messages[0].id }
    var runID: UUID? { messages.compactMap(\.runID).first }
    var tools: [ChatMessage] { messages.filter { $0.role == .tool && $0.tool != nil } }
    var thoughts: [ChatMessage] {
        messages.filter { $0.role == .assistant && $0.reasoning?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
    private func hasActivity(_ message: ChatMessage) -> Bool {
        message.tool != nil || (message.role == .assistant && message.reasoning?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
    var firstActivityID: UUID? { messages.first(where: hasActivity)?.id }
    var foldedMessages: [ChatMessage] {
        guard let first = messages.firstIndex(where: hasActivity), let last = messages.lastIndex(where: hasActivity) else { return [] }
        // Preserve interleaved replies and notices as well as tools and thoughts.
        return Array(messages[first...last])
    }
    var summaryLabel: String {
        var counts: [String] = []
        if !tools.isEmpty { counts.append("\(tools.count) 次工具调用") }
        if !thoughts.isEmpty { counts.append("\(thoughts.count) 段思考") }
        return counts.joined(separator: " · ")
    }
    static func group(_ messages: [ChatMessage]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        for message in messages {
            let differentRun = message.runID.map { run in turns.last?.runID.map { $0 != run } ?? false } ?? false
            if turns.isEmpty || message.role == .user || differentRun {
                turns.append(ConversationTurn(messages: [message]))
            } else { turns[turns.count - 1].messages.append(message) }
        }
        return turns
    }
}
extension RunPhase {
    var label: String {
        switch self {
        case .idle: return "准备就绪"
        case .running: return "正在执行"
        case .awaitingApproval: return "等待确认"
        case .stopped: return "已停止"
        case .interrupted: return "已中断"
        case .completed: return "已结束"
        case .blocked: return "需要处理"
        }
    }
}
