import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit
import Combine

enum BackgroundPlaybackMode: String, CaseIterable, Identifiable {
    case audio, pictureInPicture, systemTask
    static let defaultsKey = "backgroundPlaybackMode"
    static let residentDefaultsKey = "backgroundResidentEnabled"
    static let defaultMode: Self = .audio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: return "音频"
        case .pictureInPicture: return "画中画"
        case .systemTask: return "系统后台任务"
        }
    }
    var usesSystemProcessing: Bool { self == .systemTask }
    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? defaultMode
    }
}

@MainActor protocol TaskAudioPlayback: AnyObject {
    var onStopped: (() -> Void)? { get set }
    func start() async throws -> Bool
    func stop()
}

/// All process-wide audio session mutations share one serial worker. Native
/// iOS 27 activation is asynchronous; older activation runs on the worker queue.
/// Keeping deactivation in the same queue prevents an old stop overtaking a new start.
final class TaskAudioSession: @unchecked Sendable {
    static let shared = TaskAudioSession()
    private typealias Operation = @Sendable (@escaping @Sendable () -> Void) -> Void
    private let queue = DispatchQueue(label: "PhoneAgent.audio-session", qos: .userInitiated)
    // Accessed exclusively on queue. Each native completion advances the queue.
    private var operations: [Operation] = []
    private var running = false
    private func enqueue(_ operation: @escaping Operation) {
        queue.async { self.operations.append(operation); self.advance() }
    }
    private func advance() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !running, !operations.isEmpty else { return }
        running = true
        let operation = operations.removeFirst()
        operation {
            self.queue.async { self.running = false; self.advance() }
        }
    }
    func activate(mode: AVAudioSession.Mode) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue { finished in
                dispatchPrecondition(condition: .notOnQueue(.main))
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: mode, options: [.mixWithOthers])
                    if #available(iOS 27.0, *) {
                        session.activate(options: []) { activated, error in
                            if let error { continuation.resume(throwing: error) }
                            else if activated { continuation.resume() }
                            else { continuation.resume(throwing: AppError.unavailable("Audio session activation declined")) }
                            finished()
                        }
                    } else {
                        try session.setActive(true)
                        continuation.resume()
                        finished()
                    }
                } catch { continuation.resume(throwing: error); finished() }
            }
        }
    }
    func deactivate() {
        enqueue { finished in
            dispatchPrecondition(condition: .notOnQueue(.main))
            let session = AVAudioSession.sharedInstance()
            if #available(iOS 27.0, *) {
                session.deactivate(options: [.notifyOthersOnDeactivation]) { _, _ in finished() }
            } else {
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
                finished()
            }
        }
    }
}

/// Tokens are installed only during initialization, then released on any thread.
private final class AudioNotificationTokens: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// A real, silent PCM loop; activating AVAudioSession alone is not playback.
@MainActor final class SilentTaskAudioPlayback: NSObject, TaskAudioPlayback, AVAudioPlayerDelegate {
    var onStopped: (() -> Void)?
    private var player: AVAudioPlayer?
    private var ownsSession = false
    private var generation = UUID()
    private let observations = AudioNotificationTokens()
    private var monitor: Task<Void, Never>?
    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.routeChangeNotification] {
            observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let interrupted = notification.name == AVAudioSession.interruptionNotification &&
                    (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue == AVAudioSession.InterruptionType.began.rawValue
                let reset = notification.name == AVAudioSession.mediaServicesWereResetNotification
                let lostRoute = notification.name == AVAudioSession.routeChangeNotification &&
                    (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                if interrupted || reset || lostRoute { Task { @MainActor [weak self] in self?.failed() } }
            })
        }
    }
    deinit { monitor?.cancel() }
    func start() async throws -> Bool {
        if let player, player.isPlaying { return true }
        stop()
        let current = generation
        ownsSession = true // Includes the pending activation, so stop queues its release.
        do {
            try await TaskAudioSession.shared.activate(mode: .default)
            guard current == generation, !Task.isCancelled else { throw CancellationError() }
            let next = try AVAudioPlayer(data: Self.silentPCM())
            next.numberOfLoops = -1; next.delegate = self
            guard next.prepareToPlay(), next.play(), next.isPlaying else { stop(); return false }
            player = next
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    guard self.player?.isPlaying == true else { self.failed(); return }
                }
            }
            return true
        } catch {
            if current == generation { stop() }
            throw error
        }
    }
    func stop() {
        generation = UUID()
        monitor?.cancel(); monitor = nil
        player?.stop(); player?.delegate = nil; player = nil
        if ownsSession {
            TaskAudioSession.shared.deactivate()
            ownsSession = false
        }
    }
    private func failed() {
        guard player != nil || ownsSession else { return }
        stop(); BackgroundExecutionTrace.record("audio.playbackEnded")
        onStopped?()
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.failed()
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.failed()
        }
    }
    static func silentPCM() -> Data {
        // One second of mono PCM16 at 8 kHz. Zero samples generate actual silence.
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(16036); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(8000); u32(16000); u16(2); u16(16); ascii("data"); u32(16000)
        data.append(Data(repeating: 0, count: 16000)); return data
    }
}

/// A dismissal suppresses re-opening during the same background visit.
struct TaskPiPPolicy {
    var running = false
    var foreground = true
    var dismissed = false
    var shouldStart: Bool { running && !foreground && !dismissed }
    mutating func setRunning(_ value: Bool) { running = value; if !value { dismissed = false } }
    mutating func setForeground(_ value: Bool) { foreground = value; if value { dismissed = false } }
}

/// AVKit may query playback state off the main actor.
private final class PiPPlaybackState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var playing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// A user-initiated sample-buffer status window. Only AVKit's actual start/stop
/// receipts contribute to run execution; an inline preview grants nothing.
@MainActor final class StatusPiPController: NSObject, ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var audioActive = false
    private var preferredMode: BackgroundPlaybackMode = .defaultMode
    private(set) var playingMode: BackgroundPlaybackMode = .defaultMode
    private let audioPlayback: any TaskAudioPlayback
    private var taskRunning = false
    private(set) var backgroundResident = false
    private var audioAttempted = false
    private var audioStartTask: Task<Void, Never>?
    private var audioStartGeneration = UUID()
    private var sessionPrepareTask: Task<Void, Never>?
    private var sessionGeneration = UUID()
    @Published private(set) var message = "状态卡片默认关闭"
    @Published var previewEnabled = false
    let displayLayer = AVSampleBufferDisplayLayer()
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    let backgroundModeConfigured = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("audio")
    private var controller: AVPictureInPictureController?
    private var foreground = true
    private(set) var policy = TaskPiPPolicy()
    private let playback = PiPPlaybackState()
    private var frameTask: Task<Void, Never>?
    private var requested = false
    private var modelObservation: AnyCancellable?
    #if DEBUG
    private var controlProbeRunning = false
    func setControlProbeRunning(_ value: Bool) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ncm-tools-probe") ||
              (args.contains("--ncm-video-geometry-probe") && args.contains("--ncm-video-background-probe")) else { return }
        controlProbeRunning = value
        setTaskRunning(value)
    }
    #endif
    private var starting = false
    private var ownsAudioSession = false
    private var snapshot = AgentStatusSnapshot(isDemo: true, phase: .idle)
    private let executionOwner: UUID
    private let executionActivity: PiPExecutionActivity

    override convenience init() { self.init(executionActivity: .shared) }
    init(executionActivity: PiPExecutionActivity, executionOwner: UUID = UUID(), audioPlayback: (any TaskAudioPlayback)? = nil) {
        self.audioPlayback = audioPlayback ?? SilentTaskAudioPlayback()
        self.executionActivity = executionActivity; self.executionOwner = executionOwner
        super.init()
        self.audioPlayback.onStopped = { [weak self] in
            guard let self, self.audioActive else { return }
            self.audioActive = false
            self.executionActivity.update(owner: self.executionOwner, active: false)
            self.message = "音频播放已中断"
        }
        displayLayer.videoGravity = .resizeAspect
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
        }
        guard supported else { message = "此设备或模拟器不支持画中画"; return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        pip.requiresLinearPlayback = true
        controller = pip
    }

    /// SwiftUI may defer view updates in background. Observe task state directly.
    func observeTasks(in model: AgentViewModel) {
        modelObservation = model.objectWillChange.sink { [weak self, weak model] in
            Task { @MainActor in
                // objectWillChange precedes the property's write.
                await Task.yield()
                guard let self, let model else { return }
                self.update(model.displayStatus)
                self.setTaskRunning(model.hasBusySessions)
            }
        }
        update(model.displayStatus); setTaskRunning(model.hasBusySessions)
    }

    func update(_ next: AgentStatusSnapshot) {
        snapshot = next
        if previewEnabled { render() }
    }

    func setBackgroundMode(_ mode: BackgroundPlaybackMode) {
        preferredMode = mode
        if !policy.running { playingMode = mode }
        updatePlaybackDemand()
    }

    func setBackgroundResident(_ enabled: Bool) {
        guard backgroundResident != enabled else { return }
        backgroundResident = enabled
        recordLifecycle("pip.resident value=\(enabled)")
        updatePlaybackDemand()
    }

    func setForeground(_ value: Bool) {
        recordLifecycle("pip.foreground value=\(value)")
        foreground = value
        policy.setForeground(value)
        if value && playingMode == .pictureInPicture { stop() }
        reconcileTask()
    }

    func setTaskRunning(_ value: Bool) {
        var actual = value
        #if DEBUG
        actual = actual || controlProbeRunning
        // Finite offline fixture only: isolate island presentation from AVKit.
        if ProcessInfo.processInfo.arguments.contains("--task-pip-probe"),
           ProcessInfo.processInfo.arguments.contains("--activity-probe-no-pip") { return }
        #endif
        guard actual != taskRunning else { return }
        taskRunning = actual
        recordLifecycle("pip.task value=\(actual)")
        updatePlaybackDemand()
    }

    private func updatePlaybackDemand() {
        let needed = taskRunning || backgroundResident
        if needed != policy.running {
            if needed { playingMode = preferredMode; audioAttempted = false }
            policy.setRunning(needed)
        } else if needed, !taskRunning, playingMode != preferredMode {
            // Idle residency follows Settings immediately; an active task retains its mode.
            stop()
            playingMode = preferredMode
            audioAttempted = false
        }
        reconcileTask()
    }

    private func reconcileTask() {
        guard policy.running else {
            cancelAudioStart()
            audioPlayback.stop(); audioActive = false
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
            frameTask?.cancel(); frameTask = nil
            // Keep playback valid through AVKit's stop transition.
            if controller?.isPictureInPictureActive != true { playback.playing = false }
            stop(); previewEnabled = false
            if controller?.isPictureInPictureActive != true { displayLayer.flushAndRemoveImage() }
            return
        }
        if playingMode == .systemTask, !backgroundResident {
            cancelAudioStart()
            audioAttempted = false
            audioPlayback.stop(); audioActive = false
            executionActivity.update(owner: executionOwner, active: false)
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
            frameTask?.cancel(); frameTask = nil
            stop(); previewEnabled = false
            message = "本轮申请系统后台任务"
            return
        }
        if playingMode != .pictureInPicture {
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
            previewEnabled = false
            frameTask?.cancel(); frameTask = nil
            displayLayer.flushAndRemoveImage()
            guard backgroundModeConfigured else { message = "此构建未配置后台音频"; return }
            // Start while the task is foregrounded so background handoff has no gap.
            // Scene changes never restart an interrupted player within the same run.
            guard !audioAttempted else { return }
            audioAttempted = true
            let generation = UUID(); audioStartGeneration = generation
            audioStartTask = Task { [weak self] in
                guard let self, !Task.isCancelled, self.audioStartGeneration == generation else { return }
                do {
                    let playing = try await self.audioPlayback.start()
                    guard !Task.isCancelled, self.audioStartGeneration == generation,
                          self.policy.running, self.playingMode != .pictureInPicture,
                          self.playingMode != .systemTask || self.backgroundResident else { return }
                    self.audioActive = playing
                    self.executionActivity.update(owner: self.executionOwner, active: playing)
                    self.message = playing ? "后台音频已准备" : "音频播放未能启动"
                    BackgroundExecutionTrace.record("audio.started playing=\(playing)")
                } catch {
                    if self.audioStartGeneration == generation { self.message = "音频播放未能启动" }
                }
                if self.audioStartGeneration == generation { self.audioStartTask = nil }
            }
            return
        }
        guard supported, backgroundModeConfigured else { return }
        if controller?.contentSource == nil {
            controller?.contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        }
        previewEnabled = true
        if foreground || policy.shouldStart {
            if !ownsAudioSession || sessionPrepareTask != nil {
                prepareAudioSession()
                return
            }
            playback.playing = true
            controller?.canStartPictureInPictureAutomaticallyFromInline = !policy.dismissed
            render()
            if frameTask == nil {
                frameTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self else { return }
                        if self.playback.playing { self.render() }
                        if self.policy.shouldStart && !self.active && !self.starting { self.start() }
                    }
                }
            }
            if policy.shouldStart { start() }
        }
    }

    private func prepareAudioSession() {
        guard !ownsAudioSession, sessionPrepareTask == nil else { return }
        ownsAudioSession = true // stop must release even an activation still in flight.
        let generation = UUID(); sessionGeneration = generation
        sessionPrepareTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.sessionGeneration == generation else { return }
            do {
                try await TaskAudioSession.shared.activate(mode: .moviePlayback)
                guard !Task.isCancelled, self.sessionGeneration == generation else { return }
                self.sessionPrepareTask = nil
                self.reconcileTask()
            } catch {
                guard self.sessionGeneration == generation else { return }
                self.sessionPrepareTask = nil
                self.releaseAudioSession()
                self.message = "媒体会话不可用；没有启动画中画"
            }
        }
    }

    private func cancelAudioStart() {
        audioStartGeneration = UUID()
        audioStartTask?.cancel(); audioStartTask = nil
    }

    func setPreviewEnabled(_ value: Bool) {
        previewEnabled = value
        if value {
            render()
            message = backgroundModeConfigured ? "仅由你主动开启，显示当前任务状态" : "仅前台预览：尚未启用系统后台媒体/PiP 配置"
        } else {
            stop()
            displayLayer.flushAndRemoveImage()
            message = "状态卡片已关闭"
        }
    }

    func start() {
        guard playingMode == .pictureInPicture, previewEnabled, !starting, !active, policy.shouldStart else { return }
        guard backgroundModeConfigured else {
            message = "此构建未启用后台媒体模式，不能承诺跨 App 显示"
            return
        }
        guard let controller, supported else { message = "当前环境不支持画中画"; return }
        guard ownsAudioSession, sessionPrepareTask == nil else {
            prepareAudioSession()
            return
        }
        playback.playing = true
        render()
        guard controller.isPictureInPicturePossible else {
            releaseAudioSession()
            message = "系统尚不允许画中画；请保持预览可见后重试"
            return
        }
        starting = true; requested = true
        message = "正在请求系统画中画"
        controller.startPictureInPicture()
    }

    func stop() {
        recordLifecycle("pip.stopRequested")
        if playingMode != .pictureInPicture { cancelAudioStart(); audioPlayback.stop(); audioActive = false }
        requested = false
        executionActivity.update(owner: executionOwner, active: false)
        if active || starting || controller?.isPictureInPictureActive == true {
            message = "正在关闭画中画"
            controller?.stopPictureInPicture()
            if !policy.running { controller?.contentSource = nil }
        } else { releaseAudioSession() }
        starting = false
    }

    private func releaseAudioSession() {
        sessionGeneration = UUID()
        sessionPrepareTask?.cancel(); sessionPrepareTask = nil
        guard ownsAudioSession else { return }
        if !audioActive { TaskAudioSession.shared.deactivate() }
        ownsAudioSession = false
    }

    private func render() {
        do {
            let sample = try StatusFrameRenderer.sample(for: snapshot)
            displayLayer.flushAndRemoveImage()
            displayLayer.enqueue(sample)
            controller?.invalidatePlaybackState()
        } catch { message = "状态画面生成失败；未显示任务内容" }
    }

    private func recordLifecycle(_ event: String) {
        BackgroundExecutionTrace.record("\(event) running=\(policy.running) foreground=\(foreground) active=\(controller?.isPictureInPictureActive == true) suspended=\(controller?.isPictureInPictureSuspended == true) playing=\(playback.playing)")
    }

    func setSystemPlayback(_ playing: Bool, suspended: Bool) {
        recordLifecycle("pip.setPlaying value=\(playing) reportedSuspended=\(suspended)")
        // Playback controls and temporary hiding do not close the AVKit window.
        // Start/stop receipts remain the execution source's lifetime boundary.
        if !suspended { playback.playing = playing && policy.running }
        controller?.invalidatePlaybackState()
    }

    #if DEBUG
    func recordTaskProbe(step: Int, running: Bool, liveActivities: Int) {
        let url = URL.documentsDirectory.appending(path: "task-pip-probe.txt")
        let line = "\(Date().ISO8601Format()) step=\(step) task=\(running) policy=\(policy.running) foreground=\(foreground) pip=\(active) avkit=\(controller?.isPictureInPictureActive == true) playing=\(playback.playing) possible=\(controller?.isPictureInPicturePossible == true) activities=\(liveActivities) message=\(message)\n"
        let previous = step == 0 ? "" : ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        try? (previous + line).write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

}

extension StatusPiPController: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.playingMode == .pictureInPicture, self.policy.running, !self.policy.dismissed,
                  UIApplication.shared.applicationState != .active else {
                self.controller?.stopPictureInPicture(); return
            }
            self.recordLifecycle("pip.didStart")
            self.starting = false; self.active = true; self.requested = true
            self.playback.playing = true
            self.executionActivity.update(owner: self.executionOwner, active: true)
            self.message = "画中画已开启"
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recordLifecycle("pip.didStop")
            self.starting = false; self.active = false; self.requested = false
            if self.policy.shouldStart { self.policy.dismissed = true }
            self.playback.playing = false
            self.controller?.canStartPictureInPictureAutomaticallyFromInline = false
            if self.playingMode == .pictureInPicture { self.executionActivity.update(owner: self.executionOwner, active: false) }
            self.releaseAudioSession()
            if !self.policy.running { self.displayLayer.flushAndRemoveImage() }
            self.message = "画中画已关闭"
            if self.foreground && self.policy.running { self.reconcileTask() }
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recordLifecycle("pip.failedToStart")
            self.starting = false; self.active = false
            if self.playingMode == .pictureInPicture { self.executionActivity.update(owner: self.executionOwner, active: false) }
            self.releaseAudioSession()
            self.message = "系统未能启动画中画；继续使用 App 内预览"
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The status card lives in the existing root screen. Restoring never starts a task.
        // No foreground navigation is needed to close the task's status window.
        completionHandler(false)
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // Media playback cannot approve or restart a stopped agent.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setSystemPlayback(playing, suspended: pictureInPictureController.isPictureInPictureSuspended)
        }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { !playback.playing }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool { true }
}

@MainActor enum StatusFrameRenderer {
    static func sample(for snapshot: AgentStatusSnapshot) throws -> CMSampleBuffer {
        let width = 640, height = 360
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor(red: 0.07, green: 0.10, blue: 0.17, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            func text(_ value: String, y: CGFloat, size: CGFloat, color: UIColor, weight: UIFont.Weight) {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                (value as NSString).draw(in: CGRect(x: 32, y: y, width: 576, height: 62), withAttributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph
                ])
            }
            text("PHONE AGENT · 状态预览", y: 28, size: 22, color: .lightGray, weight: .semibold)
            text(snapshot.title, y: 83, size: 29, color: .white, weight: .medium)
            text(snapshot.phase.rawValue, y: 143, size: 37, color: .systemTeal, weight: .bold)
            text(snapshot.detail, y: 216, size: 24, color: .white, weight: .regular)
        }
        var pixel: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { throw AppError.unavailable("状态帧分配失败") }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue), let cgImage = image.cgImage else { throw AppError.unavailable("状态帧绘制失败") }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &description) == noErr, let description else { throw AppError.unavailable("状态帧格式失败") }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: 1, preferredTimescale: 600), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { throw AppError.unavailable("状态帧封装失败") }
        // Live status frames are displayed immediately; AVKit owns the PiP timeline.
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
