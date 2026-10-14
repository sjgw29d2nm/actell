// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI
@preconcurrency import CoreBluetooth

struct BluetoothHIDSession: Sendable, Equatable {
    let connection: UUID
    let owner: String
    let boardID: String
}

enum BluetoothHIDWire {
    static let zeroOwner = String(repeating: "0", count: 32)
    static let codes: Set<String> = ["ok", "format", "session", "owner", "busy", "mtu", "subscriptions",
        "stale", "conflict", "history_full", "lease", "stopped", "disconnect", "security", "notify", "queue_full", "suspended"]
    struct Ready: Sendable {
        let nonce: String, state: String, owner: String
        let highestID: UInt32, leaseMS: Int
    }
    struct Receipt: Sendable {
        let nonce: String, owner: String
        let id: UInt32
        let phase: String, code: String
    }
    enum Reply: Sendable { case ready(Ready), receipt(Receipt) }
    static func isToken(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func parseReply(_ data: Data) throws -> Reply {
        guard !data.isEmpty, data.count <= 160, data.allSatisfy({ (32...126).contains($0) }),
              let text = String(data: data, encoding: .ascii) else { throw AppError.protocolViolation("蓝牙输入回应格式无效") }
        let words = text.split(separator: " ").map(String.init)
        guard words.joined(separator: " ") == text, words.first == "BH1" else { throw AppError.protocolViolation("蓝牙输入回应格式无效") }
        guard words.count == 6 || words.count == 7 else { throw AppError.protocolViolation("蓝牙输入回应字段数无效") }
        if words[1] == "READY" {
            guard words.count == 7, isToken(words[2]), words[2] != zeroOwner,
                  ["idle", "active", "releasing"].contains(words[3]), isToken(words[4]),
                  let id = UInt32(words[5]), String(id) == words[5],
                  let lease = Int(words[6]), String(lease) == words[6], (0...750).contains(lease),
                  words[3] != "idle" || (words[4] == zeroOwner && lease == 0) else {
                throw AppError.protocolViolation("蓝牙输入状态无效")
            }
            return .ready(Ready(nonce: words[2], state: words[3], owner: words[4], highestID: id, leaseMS: lease))
        }
        guard words.count == 6, words[0] == "BH1", isToken(words[1]), words[1] != zeroOwner,
              isToken(words[2]), words[2] != zeroOwner, let id = UInt32(words[3]), id > 0, String(id) == words[3],
              ["accepted", "reports_sent", "neutral_sent", "cancelled", "unknown", "rejected"].contains(words[4]),
              codes.contains(words[5]) else { throw AppError.protocolViolation("蓝牙输入回执无效") }
        return .receipt(Receipt(nonce: words[1], owner: words[2], id: id, phase: words[4], code: words[5]))
    }
}

/// BH1 acknowledgements prove only report submission, never a visible phone action.
/// One command is outstanding, and cancellation never resends that command.
@MainActor final class BluetoothHIDTransport: ObservableObject {
    static let shared = BluetoothHIDTransport()
    static let commandID = CBUUID(string: "AD51B107-2A4B-4C6D-8E90-102030405060")
    static let responseID = CBUUID(string: "AD51B108-2A4B-4C6D-8E90-102030405060")
    @Published private(set) var supported = false
    @Published private(set) var inputActive = false
    @Published private(set) var status = "当前硬件尚未提供蓝牙键鼠"
    var onBusyChanged: (() -> Void)?
    var onFatalError: (() -> Void)?
    var busy: Bool { pending != nil || pendingRead != nil || session != nil }
    var hasPendingCommand: Bool { pending != nil || pendingRead != nil }
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var response: CBCharacteristic?
    private var epoch = UUID()
    private var boardID = ""
    private var nonce: String?
    private var highestID: UInt32 = 0
    private var session: BluetoothHIDSession?
    private struct Pending {
        let id: UInt32, owner: String, verb: String
        let continuation: CheckedContinuation<Void, Error>
    }
    private var pending: Pending?
    private var pendingRead: CheckedContinuation<BluetoothHIDWire.Ready, Error>?
    private var pendingReadID: UUID?
    private var requestTimer: Task<Void, Never>?
    private var readTimer: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopping = false
    private var inputReservation: UUID?
    #if DEBUG
    private var diagnosticLines: [String] = []
    #endif
    private func recordDiagnostic(_ line: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--hardware-hid-verification") ||
              ProcessInfo.processInfo.arguments.contains("--hardware-hid-auto-verification") ||
              ProcessInfo.processInfo.arguments.contains("--hardware-notes-task-verification") else { return }
        diagnosticLines.append(Date().ISO8601Format() + " " + line)
        if diagnosticLines.count > 240 { diagnosticLines.removeFirst(diagnosticLines.count - 240) }
        let url = URL.documentsDirectory.appending(path: "hardware-hid-verification.log")
        try? Data((diagnosticLines.joined(separator: "\n") + "\n").utf8).write(to: url, options: [.atomic, .completeFileProtection])
        #endif
    }

    func bind(_ peer: CBPeripheral, command: CBCharacteristic?, response: CBCharacteristic?) {
        invalidate("正在发现蓝牙输入服务")
        peripheral = peer; self.command = command; self.response = response
        if let response { peer.setNotifyValue(true, for: response) }
    }
    func confirmBoard(id: String, capability: Bool) {
        boardID = id
        supported = capability && command != nil && response != nil
        status = supported ? "蓝牙键鼠可用；需在系统辅助触控中完成配对" : "当前固件未提供蓝牙键鼠，请更新硬件"
    }
    func invalidate(_ message: String = "蓝牙输入已断开") {
        epoch = UUID(); heartbeat?.cancel(); heartbeat = nil; stopTask?.cancel(); stopTask = nil
        requestTimer?.cancel(); requestTimer = nil; readTimer?.cancel(); readTimer = nil
        let commandWaiter = pending, readWaiter = pendingRead
        pending = nil; pendingRead = nil; pendingReadID = nil; session = nil; stopping = false; inputReservation = nil
        supported = false; inputActive = false; peripheral = nil; command = nil; response = nil
        nonce = nil; highestID = 0; boardID = ""; status = message
        commandWaiter?.continuation.resume(throwing: AppError.unknownOutcome)
        readWaiter?.resume(throwing: AppError.unavailable(message))
        onBusyChanged?()
    }
    func notificationChanged(_ peer: CBPeripheral, characteristic: CBCharacteristic, error: Error?) -> Bool {
        guard peer === peripheral, characteristic === response else { return false }
        let detail: String
        if let error {
            let failure = error as NSError
            detail = failure.domain + " " + String(failure.code)
        } else { detail = "none" }
        recordDiagnostic("ack.subscription notifying=\(characteristic.isNotifying) error=\(detail)")
        if error != nil || !characteristic.isNotifying { failConnection("无法订阅蓝牙输入回执") }
        return true
    }
    func writeCompleted(_ peer: CBPeripheral, characteristic: CBCharacteristic, error: Error?) -> Bool {
        guard peer === peripheral, characteristic === command else { return false }
        if let error { recordDiagnostic("att.write.error domain=\((error as NSError).domain) code=\((error as NSError).code)") }
        // A write acknowledgement alone does not confirm execution.
        if error != nil { failConnection("蓝牙输入写入结果未确认，已停止；不会自动重发") }
        return true
    }
    func valueUpdated(_ peer: CBPeripheral, characteristic: CBCharacteristic, error: Error?) -> Bool {
        guard peer === peripheral, characteristic === response else { return false }
        guard error == nil, let data = characteristic.value else {
            if let error { recordDiagnostic("att.read.error domain=\((error as NSError).domain) code=\((error as NSError).code)") }
            failConnection("蓝牙输入回应未确认，已停止"); return true
        }
        do {
            switch try BluetoothHIDWire.parseReply(data) {
            case .ready(let state):
                guard let waiter = pendingRead else { return true }
                recordDiagnostic("BH1 READY state=\(state.state) id=\(state.highestID) lease_ms=\(state.leaseMS)")
                readTimer?.cancel(); readTimer = nil; pendingRead = nil; pendingReadID = nil
                nonce = state.nonce; highestID = state.highestID
                onBusyChanged?(); waiter.resume(returning: state)
            case .receipt(let receipt):
                guard let pending, receipt.nonce == nonce, receipt.id == pending.id,
                      receipt.owner == pending.owner else { return true }
                recordDiagnostic("BH1 ACK id=\(receipt.id) verb=\(pending.verb) phase=\(receipt.phase) code=\(receipt.code)")
                if receipt.phase == "accepted", receipt.code == "ok",
                   !["BEGIN", "PING"].contains(pending.verb) { return true }
                let expected = pending.verb == "STOP" ? "neutral_sent" :
                    (["BEGIN", "PING"].contains(pending.verb) ? "accepted" : "reports_sent")
                if receipt.phase == expected && receipt.code == "ok" { finishRequest(.success(Void())) }
                else {
                    let failure: AppError = receipt.phase == "unknown" ? .unknownOutcome :
                        .unavailable(Self.failureMessage(receipt.code))
                    inputActive = false
                    finishRequest(.failure(failure))
                    if let lease = session { Task { await self.stopInputs(lease) } }
                }
            }
        } catch { failConnection("蓝牙输入回应不匹配，已停止") }
        return true
    }
    private static func failureMessage(_ code: String) -> String {
        switch code {
        case "subscriptions": return "请在系统辅助触控中配对随办硬件，等待键盘和鼠标服务就绪"
        case "mtu": return "蓝牙连接参数不足，请重新连接硬件后重试"
        case "busy": return "硬件正在处理其他输入，请先停止当前 USB 或蓝牙操控"
        case "lease", "stopped", "session", "owner": return "蓝牙输入会话已失效，本轮停止；请重新连接"
        case "suspended": return "蓝牙键鼠已暂停，请重新连接并确认系统配对"
        default: return "蓝牙输入未完成（\(code)），本轮停止；不会自动重发动作"
        }
    }
    private func failConnection(_ message: String) {
        recordDiagnostic("connection.failed \(message)")
        invalidate(message)
        // Retire the app transport. The board's lease releases a system-held
        // HID connection even when CoreBluetooth cancellation is not the last user.
        onFatalError?()
    }
    private func finishRequest(_ result: Result<Void, Error>) {
        requestTimer?.cancel(); requestTimer = nil
        let old = pending; pending = nil; onBusyChanged?()
        old?.continuation.resume(with: result)
    }
    private func readState() async throws -> BluetoothHIDWire.Ready {
        guard supported, pending == nil, pendingRead == nil, let peripheral, let response,
              peripheral.state == .connected, response.isNotifying else {
            throw AppError.unavailable("蓝牙输入服务尚未就绪，请连接硬件并完成系统配对")
        }
        let generation = epoch, readID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pendingRead = continuation; pendingReadID = readID; onBusyChanged?()
                readTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self, self.epoch == generation, self.pendingReadID == readID else { return }
                    self.failConnection("读取蓝牙输入状态超时，请重新连接")
                }
                peripheral.readValue(for: response)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == generation, self.pendingReadID == readID else { return }
                self.failConnection("蓝牙输入准备已取消")
            }
        }
    }
    func openInputSession() async throws -> BluetoothHIDSession {
        guard session == nil, !stopping, stopTask == nil else { throw AppError.unavailable("上一轮蓝牙输入尚未释放") }
        let generation = epoch
        var state = try await readState()
        if state.state != "idle" {
            // Read-only wait for an abandoned owner's finite lease. Never take it over.
            try await Task.sleep(for: .milliseconds(800))
            guard epoch == generation else { throw AppError.stopped }
            state = try await readState()
        }
        guard epoch == generation, state.state == "idle" else { throw AppError.unavailable("硬件仍在释放上一轮输入，请稍后重新连接") }
        let lease = BluetoothHIDSession(connection: generation,
            owner: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), boardID: boardID)
        session = lease; onBusyChanged?()
        do {
            try await request("BEGIN", session: lease)
            guard session == lease, epoch == generation else { throw AppError.stopped }
            inputActive = true; status = "蓝牙输入已启用；实际效果以手机页面为准"
            startHeartbeat(lease)
            return lease
        } catch {
            await stopInputs(lease)
            throw error
        }
    }
    func requireSession(_ lease: BluetoothHIDSession) throws {
        guard session == lease, epoch == lease.connection, inputActive, !stopping,
              peripheral?.state == .connected, response?.isNotifying == true else { throw AppError.stopped }
    }
    func mouse(_ lease: BluetoothHIDSession, dx: Int, dy: Int, wheel: Int = 0, buttons: Int = 0) async throws {
        try requireSession(lease)
        guard (-127...127).contains(dx), (-127...127).contains(dy),
              (-127...127).contains(wheel), (0...7).contains(buttons) else { throw AppError.invalid("蓝牙鼠标报告越界") }
        guard inputReservation == nil else { throw AppError.unavailable("已有蓝牙输入正在等待确认") }
        let reservation = UUID(); inputReservation = reservation
        defer { if inputReservation == reservation { inputReservation = nil } }
        do {
            try await waitForHeartbeat(lease)
            try await request("MOUSE \(dx) \(dy) \(wheel) \(buttons)", session: lease)
        } catch { await stopInputs(lease); throw error }
    }
    func keyboard(_ lease: BluetoothHIDSession, modifiers: Int = 0, keys: [Int]) async throws {
        try requireSession(lease)
        guard (0...255).contains(modifiers), keys.count <= 6,
              keys.allSatisfy({ $0 == 0 || (4...223).contains($0) }),
              Set(keys.filter { $0 != 0 }).count == keys.filter({ $0 != 0 }).count else { throw AppError.invalid("蓝牙键盘报告无效") }
        guard inputReservation == nil else { throw AppError.unavailable("已有蓝牙输入正在等待确认") }
        let reservation = UUID(); inputReservation = reservation
        defer { if inputReservation == reservation { inputReservation = nil } }
        let padded = keys + Array(repeating: 0, count: 6 - keys.count)
        do {
            try await waitForHeartbeat(lease)
            try await request("KEY \(modifiers) " + padded.map(String.init).joined(separator: " "), session: lease)
        } catch { await stopInputs(lease); throw error }
    }
    private func waitForHeartbeat(_ lease: BluetoothHIDSession) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        while pending?.verb == "PING", ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
            try requireSession(lease)
        }
        try requireSession(lease)
    }
    private func request(_ body: String, session lease: BluetoothHIDSession) async throws {
        guard session == lease, lease.connection == epoch, pending == nil, pendingRead == nil,
              let peripheral, let command, response?.isNotifying == true, let nonce,
              highestID < UInt32.max else { throw AppError.unavailable("蓝牙输入通道不可用或仍有请求等待确认") }
        highestID += 1
        let id = highestID, generation = epoch, verb = String(body.split(separator: " ")[0])
        let bytes = Data("BH1 \(nonce) \(lease.owner) \(id) \(body)".utf8)
        guard bytes.count <= 160, bytes.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            throw AppError.unavailable("当前蓝牙写入长度不足，已停止输入")
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                recordDiagnostic("BH1 WRITE id=\(id) verb=\(verb) bytes=\(bytes.count) max_write=\(peripheral.maximumWriteValueLength(for: .withResponse))")
                pending = Pending(id: id, owner: lease.owner, verb: verb, continuation: continuation); onBusyChanged?()
                requestTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                    guard let self, self.epoch == generation, self.pending?.id == id else { return }
                    self.failConnection("蓝牙输入确认超时，结果未知；已停止且不会自动重发")
                }
                peripheral.writeValue(bytes, for: command, type: .withResponse)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == generation, self.pending?.id == id else { return }
                self.finishRequest(.failure(AppError.unknownOutcome))
            }
        }
    }
    private func startHeartbeat(_ lease: BluetoothHIDSession) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.session == lease, !self.stopping else { return }
                if self.hasPendingCommand || self.inputReservation != nil { continue }
                do { try await self.request("PING", session: lease) }
                catch {
                    guard !Task.isCancelled, self.session == lease, !self.stopping else { return }
                    self.failConnection("蓝牙输入保活失败，已停止"); return
                }
            }
        }
    }
    func stopInputs(_ lease: BluetoothHIDSession) async {
        guard session == lease, epoch == lease.connection else { return }
        if let stopTask { await stopTask.value; return }
        guard session == lease, epoch == lease.connection, !stopping else { return }
        let task = Task { await self.performStop(lease) }
        stopTask = task
        await task.value
        if epoch == lease.connection { stopTask = nil }
    }
    private func performStop(_ lease: BluetoothHIDSession) async {
        guard session == lease, epoch == lease.connection, !stopping else { return }
        recordDiagnostic("input.stop requested")
        stopping = true; inputActive = false; heartbeat?.cancel(); heartbeat = nil
        finishRequest(.failure(AppError.unknownOutcome))
        do {
            try await request("STOP", session: lease)
            guard session == lease else { return }
            session = nil; stopping = false; status = "蓝牙键鼠已释放"; onBusyChanged?()
        } catch {
            guard epoch == lease.connection, session == lease else { return }
            failConnection("停止回执未确认，请检查硬件；旧输入不会恢复")
        }
    }
    func stopAll() async {
        if let session { await stopInputs(session) }
    }
}
