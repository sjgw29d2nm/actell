import Foundation
import Darwin

/// Shared only by the containing app and its explicitly entitled upload extension.
/// There is one latest image, never an image history or an upload destination.
enum ReplayKitBroadcastStorageError: Error { case unavailable, malformed, inactive, busy }

struct ReplayKitBroadcastRequest: Codable, Sendable {
    let version: Int
    let session: UUID
    let createdUptime: TimeInterval
    var heartbeatUptime: TimeInterval
    var permitted: Bool
}

struct ReplayKitBroadcastState: Codable, Sendable {
    enum Phase: String, Codable { case waiting, active, stopped }
    let version: Int
    let session: UUID
    let broadcast: UUID?
    var phase: Phase
    let startedUptime: TimeInterval
    var frameUptime: TimeInterval
    var sequence: UInt64
    var width: Int
    var height: Int
    var sourceWidth: Int
    var sourceHeight: Int
    var orientation: UInt32
    var presentationSeconds: Double
    var capturedAt: Date
}

final class ReplayKitBroadcastStore: @unchecked Sendable {
    static let hostLease: TimeInterval = 5
    static let frameLease: TimeInterval = 2
    static let preparationLease: TimeInterval = 60
    static let maximumImageBytes = 8 * 1024 * 1024
    private let directory: URL
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()
    private let localLock = NSLock()

    init(groupIdentifier: String) throws {
        guard groupIdentifier.hasPrefix("group."), groupIdentifier.utf8.count <= 200,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw ReplayKitBroadcastStorageError.unavailable
        }
        directory = container.appendingPathComponent("SuibanReplayKit", isDirectory: true)
        encoder.outputFormat = .binary
    }

    func prepare(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> UUID {
        try locked {
            let session = UUID()
            let request = ReplayKitBroadcastRequest(version: 1, session: session, createdUptime: now, heartbeatUptime: now, permitted: true)
            let state = ReplayKitBroadcastState(version: 1, session: session, broadcast: nil, phase: .waiting,
                startedUptime: now, frameUptime: 0, sequence: 0, width: 0, height: 0, sourceWidth: 0, sourceHeight: 0,
                orientation: 1, presentationSeconds: 0, capturedAt: Date())
            try eraseImage()
            try write(request, name: "request.plist")
            try write(state, name: "state.plist")
            return session
        }
    }

    func heartbeat(session: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        try locked {
            var request: ReplayKitBroadcastRequest = try read("request.plist")
            try validate(request, session: session, now: now)
            request.heartbeatUptime = now
            try write(request, name: "request.plist")
        }
    }

    func beginBroadcast(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> ReplayKitBroadcastState {
        try locked {
            let request: ReplayKitBroadcastRequest = try read("request.plist")
            try validate(request, session: request.session, now: now)
            let old: ReplayKitBroadcastState = try read("state.plist")
            guard old.version == 1, old.session == request.session, old.phase == .waiting,
                  now >= request.createdUptime, now - request.createdUptime <= Self.preparationLease else {
                throw ReplayKitBroadcastStorageError.inactive
            }
            let state = ReplayKitBroadcastState(version: 1, session: request.session, broadcast: UUID(), phase: .active,
                startedUptime: now, frameUptime: 0, sequence: 0, width: 0, height: 0, sourceWidth: 0, sourceHeight: 0,
                orientation: 1, presentationSeconds: 0, capturedAt: Date())
            try eraseImage()
            try write(state, name: "state.plist")
            return state
        }
    }

    func state(session: UUID, broadcast: UUID? = nil, requireFreshFrame: Bool = false,
               now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> ReplayKitBroadcastState {
        try locked { try checkedState(session: session, broadcast: broadcast, requireFreshFrame: requireFreshFrame, now: now) }
    }

    func publish(image: Data, state candidate: ReplayKitBroadcastState,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard candidate.broadcast != nil, candidate.phase == .active, candidate.sequence > 0,
              !image.isEmpty, image.count <= Self.maximumImageBytes,
              (1...1280).contains(candidate.width), (1...1280).contains(candidate.height),
              (1...16384).contains(candidate.sourceWidth), (1...16384).contains(candidate.sourceHeight),
              (1...8).contains(candidate.orientation), candidate.presentationSeconds.isFinite,
              candidate.frameUptime <= now, now - candidate.frameUptime <= Self.frameLease else {
            throw ReplayKitBroadcastStorageError.malformed
        }
        try locked {
            let old = try checkedState(session: candidate.session, broadcast: candidate.broadcast, requireFreshFrame: false, now: now)
            guard old.phase == .active, candidate.sequence > old.sequence else { throw ReplayKitBroadcastStorageError.inactive }
            // Publishing and reading the image/metadata pair share this process lock.
            try protectedWrite(image, to: directory.appendingPathComponent("latest.png"))
            try write(candidate, name: "state.plist")
        }
    }

    func frame(session: UUID, broadcast: UUID, after sequence: UInt64, notBefore: TimeInterval,
               now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> (ReplayKitBroadcastState, Data)? {
        try locked {
            let state = try checkedState(session: session, broadcast: broadcast, requireFreshFrame: true, now: now)
            guard state.sequence > sequence, state.frameUptime > notBefore else { return nil }
            let data = try boundedData("latest.png", maximum: Self.maximumImageBytes)
            guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw ReplayKitBroadcastStorageError.malformed }
            return (state, data)
        }
    }

    func stop(session: UUID, broadcast: UUID? = nil) throws {
        try locked {
            var request: ReplayKitBroadcastRequest = try read("request.plist")
            guard request.session == session else { return }
            var state: ReplayKitBroadcastState = try read("state.plist")
            guard state.session == session, broadcast == nil || state.broadcast == broadcast else { return }
            request.permitted = false
            state.phase = .stopped; state.sequence = 0; state.frameUptime = 0
            // Revoke before deleting so another reader cannot accept a stopped frame.
            try write(request, name: "request.plist")
            try write(state, name: "state.plist")
            try eraseImage()
        }
    }

    private func validate(_ request: ReplayKitBroadcastRequest, session: UUID, now: TimeInterval) throws {
        guard request.version == 1, request.session == session, request.permitted,
              request.createdUptime.isFinite, request.heartbeatUptime.isFinite,
              request.createdUptime >= 0, request.heartbeatUptime >= request.createdUptime,
              now >= request.heartbeatUptime, now - request.heartbeatUptime <= Self.hostLease else {
            throw ReplayKitBroadcastStorageError.inactive
        }
    }
    private func checkedState(session: UUID, broadcast: UUID?, requireFreshFrame: Bool, now: TimeInterval) throws -> ReplayKitBroadcastState {
        let request: ReplayKitBroadcastRequest = try read("request.plist")
        try validate(request, session: session, now: now)
        let state: ReplayKitBroadcastState = try read("state.plist")
        guard state.version == 1, state.session == session, state.phase != .stopped,
              broadcast == nil || state.broadcast == broadcast else { throw ReplayKitBroadcastStorageError.inactive }
        if requireFreshFrame {
            guard state.phase == .active, state.broadcast != nil, state.sequence > 0,
                  state.frameUptime.isFinite, now >= state.frameUptime, now - state.frameUptime <= Self.frameLease else {
                throw ReplayKitBroadcastStorageError.inactive
            }
        }
        return state
    }
    private func read<Value: Decodable>(_ name: String) throws -> Value {
        try decoder.decode(Value.self, from: boundedData(name, maximum: 4096))
    }
    private func write<Value: Encodable>(_ value: Value, name: String) throws {
        let data = try encoder.encode(value)
        guard data.count <= 4096 else { throw ReplayKitBroadcastStorageError.malformed }
        try protectedWrite(data, to: directory.appendingPathComponent(name))
    }
    private func boundedData(_ name: String, maximum: Int) throws -> Data {
        let url = directory.appendingPathComponent(name)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= maximum else {
            throw ReplayKitBroadcastStorageError.malformed
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= maximum else { throw ReplayKitBroadcastStorageError.malformed }
        return data
    }
    private func protectedWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func eraseImage() throws {
        let url = directory.appendingPathComponent("latest.png")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func locked<Value>(_ body: () throws -> Value) throws -> Value {
        localLock.lock(); defer { localLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        let url = directory.appendingPathComponent("store.lock")
        if !FileManager.default.fileExists(atPath: url.path) { try protectedWrite(Data([0]), to: url) }
        let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ReplayKitBroadcastStorageError.unavailable }
        defer { Darwin.close(descriptor) }
        var fileLock = flock()
        fileLock.l_type = Int16(F_WRLCK); fileLock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &fileLock) == 0 else { throw ReplayKitBroadcastStorageError.busy }
        defer { fileLock.l_type = Int16(F_UNLCK); _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock) }
        return try body()
    }
}
