import Foundation
import Combine
import ImageIO
import CoreGraphics
import CoreVideo

/// ReplayKit 2 receives other apps' screens in the upload extension. The main
/// app reads one protected latest frame and retains the existing frame fences.
@MainActor final class ReplayKitBroadcastCapture: ObservableObject {
    static let shared = ReplayKitBroadcastCapture()
    @Published private(set) var active = false
    @Published private(set) var busy = false
    @Published private(set) var status = "屏幕采集扩展或共享组未授权，当前版本不可用"
    let frames = LatestScreenFrame()
    var onLoss: (@MainActor () -> Void)?
    private var store: ReplayKitBroadcastStore?
    private var requestSession: UUID?
    private var broadcastSession: UUID?
    private var frameEpoch: UUID?
    private var sequence: UInt64 = 0
    private var monitor: Task<Void, Never>?

    private init() {
        if isSupported { status = "未采集；请通过系统屏幕广播面板授权，保持手机解锁" }
    }

    var broadcastExtensionIdentifier: String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "SuibanBroadcastExtensionBundleIdentifier") as? String,
              !identifier.isEmpty, let plugins = Bundle.main.builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil),
              urls.contains(where: { $0.pathExtension == "appex" && Bundle(url: $0)?.bundleIdentifier == identifier }) else { return nil }
        return identifier
    }
    var isSupported: Bool {
        guard broadcastExtensionIdentifier != nil,
              let group = Bundle.main.object(forInfoDictionaryKey: "SuibanBroadcastAppGroup") as? String else { return false }
        return (try? ReplayKitBroadcastStore(groupIdentifier: group)) != nil
    }

    /// Arm a new session before the person taps the standard system picker.
    /// This does not start screen capture or bypass the system's confirmation.
    func prepareBroadcast() throws {
        guard !active, !busy else { throw AppError.unavailable("请先停止当前屏幕采集") }
        guard isSupported, let group = Bundle.main.object(forInfoDictionaryKey: "SuibanBroadcastAppGroup") as? String else {
            frames.invalidate(); status = "屏幕采集扩展或共享组未授权，当前版本不可用"
            throw AppError.unavailable(status)
        }
        do {
            let store = try ReplayKitBroadcastStore(groupIdentifier: group)
            let session = try store.prepare()
            self.store = store; requestSession = session; broadcastSession = nil
            sequence = 0; frameEpoch = frames.begin(); active = false; busy = true
            status = "请在系统屏幕广播面板中选择随办并确认开始；保持手机解锁"
            monitor?.cancel()
            monitor = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, self.requestSession == session else { return }
                    self.poll(session: session)
                    if self.requestSession != session { return }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
            }
        } catch {
            revoke(message: "无法开启受保护的屏幕采集；请检查扩展签名与共享组授权")
            throw AppError.unavailable(status)
        }
    }

    func stop() { revoke(message: "屏幕采集已停止；任务不会自动继续") }

    func captureSessionID() throws -> UUID {
        guard active, let requestSession, let broadcastSession, let store else {
            throw AppError.unavailable(status)
        }
        do { _ = try store.state(session: requestSession, broadcast: broadcastSession, requireFreshFrame: true) }
        catch { revoke(message: "屏幕采集已停止或画面不再更新；输入已禁用"); throw AppError.stopped }
        return try frames.sessionID()
    }
    func requireSession(_ expected: UUID) throws {
        guard try captureSessionID() == expected else { throw AppError.stopped }
        try frames.requireSession(expected)
    }
    func screenshot() async throws -> FrameImage {
        let expected = try captureSessionID()
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 7
        repeat {
            try Task.checkCancellation(); try requireSession(expected)
            if let stamp = try? frames.latestStamp(), stamp.uptime > started {
                let result = try frames.encoded(notBefore: started)
                try Task.checkCancellation(); try requireSession(expected)
                // Extension pixels and dimensions are already in upright display
                // coordinates, so capture.videoOrientation is deliberately 1.
                return result
            }
            try await Task.sleep(for: .milliseconds(40))
        } while ProcessInfo.processInfo.systemUptime < deadline
        revoke(message: "等待新屏幕画面超时；输入已禁用，请重新授权")
        throw AppError.unavailable(status)
    }

    private func poll(session: UUID) {
        guard requestSession == session, let store else { return }
        do {
            try store.heartbeat(session: session)
            let state = try store.state(session: session, broadcast: broadcastSession)
            let now = ProcessInfo.processInfo.systemUptime
            if state.phase == .waiting {
                guard now >= state.startedUptime, now - state.startedUptime <= ReplayKitBroadcastStore.preparationLease else {
                    throw ReplayKitBroadcastStorageError.inactive
                }
                return
            }
            guard state.phase == .active, let broadcast = state.broadcast else { throw ReplayKitBroadcastStorageError.inactive }
            if let expected = broadcastSession, expected != broadcast { throw ReplayKitBroadcastStorageError.inactive }
            broadcastSession = broadcast
            if state.sequence == 0 {
                guard now >= state.startedUptime, now - state.startedUptime <= 7 else { throw ReplayKitBroadcastStorageError.inactive }
                status = "系统屏幕广播已开始，等待首帧"; return
            }
            _ = try store.state(session: session, broadcast: broadcast, requireFreshFrame: true)
            guard state.sequence > sequence else { return }
            guard let (latest, data) = try store.frame(session: session, broadcast: broadcast, after: sequence, notBefore: 0),
                  let epoch = frameEpoch else { return }
            let pixel = try decode(data, width: latest.width, height: latest.height)
            // Validate again after decoding; stop/lock may have raced that work.
            _ = try store.state(session: session, broadcast: broadcast, requireFreshFrame: true)
            guard requestSession == session else { return }
            frames.put(pixel, orientation: 1, presentationSeconds: latest.presentationSeconds, epoch: epoch, now: latest.frameUptime)
            sequence = latest.sequence; active = true; busy = false
            status = "跨 App 屏幕采集中；画面留在手机，按任务需要交给所选模型"
        } catch ReplayKitBroadcastStorageError.busy { return }
        catch { revoke(message: "屏幕采集已停止、手机已锁定或画面不再更新；输入已禁用") }
    }

    private func decode(_ data: Data, width: Int, height: Int) throws -> CVPixelBuffer {
        guard (1...1280).contains(width), (1...1280).contains(height),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == width, image.height == height else {
            throw ReplayKitBroadcastStorageError.malformed
        }
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &result) == kCVReturnSuccess,
              let pixel = result else { throw ReplayKitBroadcastStorageError.malformed }
        CVPixelBufferLockBaseAddress(pixel, []); defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ReplayKitBroadcastStorageError.malformed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixel
    }
    private func revoke(message: String) {
        let hadSession = active || busy
        monitor?.cancel(); monitor = nil
        frames.invalidate(); frameEpoch = nil; active = false; busy = false; sequence = 0
        let oldStore = store, oldRequest = requestSession, oldBroadcast = broadcastSession
        store = nil; requestSession = nil; broadcastSession = nil; status = message
        if let oldStore, let oldRequest { try? oldStore.stop(session: oldRequest, broadcast: oldBroadcast) }
        if hadSession { onLoss?() }
    }
}
