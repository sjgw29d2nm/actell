// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation
import UIKit

private enum NotesConfirmationStep: String, CaseIterable {
    case newNote = "new_note"
    case paste
    case finish
}

/// This diagnostic accepts only a matching run and a fixed, ordered step.
/// An old file or an already consumed step cannot replay an input action.
private enum NotesConfirmationParser {
    static let maximumBytes = 512

    static func parse(_ data: Data, runID: String, expected: NotesConfirmationStep) throws -> NotesConfirmationStep? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any],
              let fileRunID = object["run_id"] as? String,
              fileRunID == runID else { return nil }
        guard Set(object.keys) == Set(["run_id", "step"]),
              let rawStep = object["step"] as? String,
              let step = NotesConfirmationStep(rawValue: rawStep) else {
            throw AppError.protocolViolation("备忘录验收确认格式无效")
        }
        let order = NotesConfirmationStep.allCases
        guard let received = order.firstIndex(of: step), let requested = order.firstIndex(of: expected) else {
            throw AppError.protocolViolation("备忘录验收确认顺序无效")
        }
        if received < requested { return nil }
        guard received == requested else { throw AppError.protocolViolation("备忘录验收确认顺序不匹配") }
        return step
    }
}

/// Mac observes the real Notes page before allowing each fixed action.
/// This is a bounded development diagnostic, not a production device bridge.
@MainActor enum BluetoothNotesTaskVerification {
    static let title = "随办真实任务验收"
    static let body = "任务：新建备忘录并保存中文内容。\n结果：蓝牙键鼠跨 App 输入验证。\n标记：SU-BLE-TASK-20261014"
    private static var started = false

    static func run(status: @escaping @MainActor (String) -> Void) async {
        guard ProcessInfo.processInfo.arguments.contains("--hardware-notes-task-verification"), !started else { return }
        started = true
        let run = NotesTaskRun(status: status)
        run.record("task.begin")
        do {
            try run.requirePreflight()
            // Replace only the clipboard with the explicitly fixed test text.
            // Never read or preserve the user's previous clipboard contents.
            UIPasteboard.general.string = title + "\n" + body
            run.record("clipboard.fixture_written")
            try run.requireLogWritable()
            run.transition.begin()
            guard run.transition.valid else { throw AppError.unavailable("系统未授予本次有限后台时间") }
            run.record("background.granted")
        } catch {
            run.fail(error)
            run.transition.complete(success: false)
            return
        }

        let operation = Task { await perform(run) }
        run.transition.expirationHandler = {
            run.expired = true
            run.record("background.expired")
            operation.cancel()
        }
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private static func perform(_ run: NotesTaskRun) async {
        let hid = BluetoothHIDTransport.shared
        var owned: BluetoothHIDSession?
        var succeeded = false
        defer { run.transition.complete(success: succeeded) }
        do {
            try run.requireLive()
            let session = try await hid.openInputSession()
            owned = session
            try run.requireLive(session)
            run.record("input.begin")

            try await run.waitForConfirmation(.newNote, session: session)
            try await sendKey(17, modifiers: 8, session: session, run: run)
            run.record("command.sent step=new_note")

            // The matching paste confirmation means Mac has observed a new,
            // empty editor. Reports alone never authorize typing into a note.
            try await run.waitForConfirmation(.paste, session: session)
            run.record("mac.empty_note_confirmed")
            try await sendKey(25, modifiers: 8, session: session, run: run)
            run.record("command.sent step=paste")

            // Mac confirms visible title and body before this final command.
            try await run.waitForConfirmation(.finish, session: session)
            run.record("mac.content_confirmed")
            try await sendKey(41, modifiers: 0, session: session, run: run)
            run.record("command.sent step=finish")
            await hid.stopInputs(session)
            owned = nil
            guard !run.expired, !Task.isCancelled,
                  run.transition.valid, UIApplication.shared.isProtectedDataAvailable,
                  !hid.busy, !hid.inputActive, hid.status == "蓝牙键鼠已释放" else {
                throw AppError.unavailable("停止回执未确认或本轮已到期")
            }
            run.record("input.neutral_confirmed")
            try run.requireLogWritable()
            run.record("PASS mac_content_confirmed stop_neutral persistence_pending")
            try run.requireLogWritable()
            succeeded = true
            run.status("Mac 已确认实际内容，蓝牙输入已释放；重新打开备忘录后再确认保存。")
        } catch {
            if let owned {
                await hid.stopInputs(owned)
                run.record("input.cleanup released=\(!hid.busy && !hid.inputActive && hid.status == "蓝牙键鼠已释放")")
            }
            run.fail(error)
        }
    }

    private static func sendKey(_ key: Int, modifiers: Int, session: BluetoothHIDSession, run: NotesTaskRun) async throws {
        try run.requireLive(session)
        // Mac must have moved to Notes before confirming a command. Do not
        // send the fixed Notes action into our own foreground diagnostic UI.
        guard UIApplication.shared.applicationState != .active else {
            throw AppError.unavailable("请先由 Mac 打开备忘录并确认当前页面")
        }
        try await BluetoothHIDTransport.shared.keyboard(session, modifiers: modifiers, keys: [key])
        try await Task.sleep(for: .milliseconds(60))
        try run.requireLive(session)
        try await BluetoothHIDTransport.shared.keyboard(session, keys: [])
    }
}

@MainActor private final class NotesTaskRun {
    let runID = UUID().uuidString.lowercased()
    let transition = ExecutionTransitionLease()
    let status: @MainActor (String) -> Void
    var expired = false
    private(set) var logWritable = true
    // Reserve five seconds within the overall minute for terminal STOP.
    private let deadline = ContinuousClock.now.advanced(by: .seconds(55))
    private var lines: [String] = []
    private var expectedBoardID = ""
    private let logURL = URL.documentsDirectory.appending(path: "hardware-notes-task-verification.log")
    private let confirmationURL = URL.documentsDirectory.appending(path: "hardware-notes-task-confirmation.json")

    init(status: @escaping @MainActor (String) -> Void) { self.status = status }

    func record(_ stage: String) {
        lines.append(Date().ISO8601Format() + " " + stage + " run_id=" + runID)
        do {
            try Data((lines.joined(separator: "\n") + "\n").utf8)
                .write(to: logURL, options: [.atomic, .completeFileProtection])
        } catch { logWritable = false }
    }

    func requireLogWritable() throws {
        guard logWritable else { throw AppError.unavailable("无法保存本次验收日志，本轮停止") }
    }

    func requirePreflight() throws {
        try Task.checkCancellation()
        try requireLogWritable()
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--hardware-board-id"), index + 1 < arguments.count else {
            throw AppError.unavailable("本次验收未指定硬件身份")
        }
        let expected = arguments[index + 1]
        guard expected.utf8.count == 12,
              expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              BluetoothBoardFlow.shared.connected, BluetoothBoardFlow.shared.boardID == expected,
              BluetoothHIDTransport.shared.supported else {
            throw AppError.unavailable("本次验收硬件身份或蓝牙输入服务不匹配")
        }
        guard UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else {
            throw AppError.unavailable("请先解锁手机并在随办前台启动验收")
        }
        guard !PhoneAgentRuntime.shared.model.hasBusySessions,
              !PairingFlow.shared.running, !PairingFlow.shared.ready, !PairingFlow.shared.agentReserved,
              PairingFlow.shared.canChangeRoute else {
            throw AppError.unavailable("请先停止当前手机操控或任务，再开始备忘录验收")
        }
        expectedBoardID = expected
        record("preflight.verified")
        try requireLogWritable()
    }

    func requireLive(_ session: BluetoothHIDSession? = nil) throws {
        try Task.checkCancellation()
        try requireLogWritable()
        guard !expired, transition.valid, ContinuousClock.now < deadline else {
            throw AppError.unavailable("本次有限后台验收已到期")
        }
        guard UIApplication.shared.isProtectedDataAvailable,
              !PhoneAgentRuntime.shared.model.hasBusySessions,
              !PairingFlow.shared.running, !PairingFlow.shared.ready, !PairingFlow.shared.agentReserved,
              BluetoothBoardFlow.shared.connected, BluetoothBoardFlow.shared.boardID == expectedBoardID else {
            throw AppError.unavailable("手机锁定、连接变化或其他任务占用，本轮停止")
        }
        if let session { try BluetoothHIDTransport.shared.requireSession(session) }
    }

    func waitForConfirmation(_ step: NotesConfirmationStep, session: BluetoothHIDSession) async throws {
        let stepDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(20)))
        record("command.wait step=" + step.rawValue)
        status("等待 Mac 核对页面：" + step.rawValue)
        while ContinuousClock.now < stepDeadline {
            try requireLive(session)
            if let handle = try? FileHandle(forReadingFrom: confirmationURL) {
                defer { try? handle.close() }
                // Bound the read even if the external confirmation is malformed.
                if let data = try handle.read(upToCount: NotesConfirmationParser.maximumBytes + 1),
                   try NotesConfirmationParser.parse(data, runID: runID, expected: step) != nil {
                    try requireLive(session)
                    record("command.confirmed step=" + step.rawValue)
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AppError.unavailable("等待 Mac 本轮页面确认超时，本轮停止")
    }

    func fail(_ error: Error) {
        let failure = error as NSError
        let appFailure = error as? AppError
        let reason = appFailure.map { " reason=" + $0.localizedDescription } ?? ""
        record("FAIL error_domain=\(failure.domain) error_code=\(failure.code)" + reason)
        status(appFailure?.localizedDescription ?? "备忘录验收已停止；没有自动重试动作")
    }
}
#endif
