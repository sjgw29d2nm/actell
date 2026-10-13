// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import BackgroundTasks
import Observation

enum NCMControlError: Error { case unavailable(String), stopped }

@MainActor @Observable final class PairingFlow: NSObject, @preconcurrency NetServiceDelegate {
    static let shared = PairingFlow()
    static let taskID = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent.NCMProbe") + ".pairing"
    private let pairing = RemotePairingSession()
    private let backend = NativeDeveloperServices()
    private let client = NCMProbeClient()
    private let localDiscovery = LocalVPNDiscovery()
    private(set) var route: DeviceControlRoute
    private(set) var hardwareTransport: HardwareRelayTransport?
    var hardwareConnectionLabel: String {
        guard let hardwareTransport else { return "未连接" }
        switch hardwareTransport { case .usb: return "USB"; case .wifi: return "Wi-Fi" }
    }
    private let defaults: UserDefaults
    private static let vpnConfigurationKey = "vpnLoopbackConfiguration"
    private(set) var vpnConfiguration: VPNLoopbackConfiguration
    func saveVPNConfiguration(localAddress: String, peerAddress: String) throws {
        guard canChangeRoute, !HardwareWiFiFlow.shared.busy else { throw NCMControlError.unavailable("请先停止当前操控或完成硬件配网，再修改连接配置") }
        let configuration = try VPNLoopbackConfiguration(localAddress: localAddress, peerAddress: peerAddress)
        guard configuration != vpnConfiguration else { return }
        cancel()
        vpnConfiguration = configuration
        defaults.set(["localAddress": configuration.localAddress, "peerAddress": configuration.peerAddress], forKey: Self.vpnConfigurationKey)
        lastFailure = nil
        message = "配置已保存，请重新连接"
    }
    var canChangeRoute: Bool { !running && !agentReserved && connectionUsers.isEmpty && !mediaLifetime.stopping }
    @discardableResult func selectRoute(_ selected: DeviceControlRoute) -> Bool {
        guard selected != .localCaptureUSB, canChangeRoute, !HardwareWiFiFlow.shared.busy else { return false }
        guard selected != route else { return true }
        cancel()
        route = selected
        defaults.set(selected.rawValue, forKey: DeviceControlRoute.defaultsKey)
        lastFailure = nil
        message = hasRecord ? "已切换，请连接验证" : "请先完成系统配对"
        return true
    }
    private let store: RemotePairRecordStore
    private var service: NetService?
    private var generation = UUID()
    private(set) var connectionStopID: UUID? = UUID()
    private(set) var controlSessionID = UUID()
    private var agentOwner: UUID?
    private var connectionUsers: Set<UUID> = []
    private var agentRuns: Set<UUID> = []
    private var agentQueue: [UUID] = []
    private(set) var isBackground = false
    var agentReserved: Bool { !agentRuns.isEmpty || agentOwner != nil }
    private var registeredBackgroundTask = false
    private var mediaStarted = false
    private let mediaLifetime = ControlMediaLifetime()
    private var job: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatEpoch = UUID()
    private var maintenanceBusy = false
    private var backgroundTask: BGTask?
    private var operationLease: ExecutionTransitionLease?
    private(set) var capturing = false
    var running = false
    var pairingActive = false
    var lastFailure: String?
    var ready = false
    var hasRecord = false
    var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }
    var pin: String?
    var message = "请先完成系统配对"
    var image: UIImage?
    private(set) var screenshotData: Data?
    var statusText: String {
        if pairingActive { return message }
        if running { return ready ? "正在处理操作" : "正在连接 \(route.connectionName)" }
        if ready {
            if lastFailure != nil { return "最近操作未成功" }
            return image == nil ? "截图与点击可用" : "截图已收到"
        }
        if hasRecord { return lastFailure == nil ? "已配对，可连接 \(route.connectionName)" : "连接未成功；若已在系统取消授权，请重新配对" }
        return message
    }
    override convenience init() {
        self.init(store: RemotePairRecordStore(url: URL.applicationSupportDirectory.appending(path: "RemotePairing/identity.plist")))
    }
    init(store: RemotePairRecordStore, defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults; route = DeviceControlRoute.load(from: defaults)
        let saved = defaults.dictionary(forKey: Self.vpnConfigurationKey) as? [String: String]
        vpnConfiguration = (try? VPNLoopbackConfiguration(localAddress: saved?["localAddress"] ?? VPNLoopbackConfiguration.defaults.localAddress,
            peerAddress: saved?["peerAddress"] ?? VPNLoopbackConfiguration.defaults.peerAddress)) ?? .defaults
        super.init(); hasRecord = store.exists
    }

    /// User explicitly requests new system authorization, even if a local identity remains.
    func resetPairing() {
        guard canChangeRoute, !HardwareWiFiFlow.shared.busy else { return }
        cancel()
        do {
            try store.remove(); hasRecord = false; lastFailure = nil; pin = nil
            message = "请先完成系统配对"
        } catch {
            hasRecord = store.exists; message = "无法清除本地配对身份，请重试"; lastFailure = message
        }
    }
    func pairAgain() {
        guard canChangeRoute, !HardwareWiFiFlow.shared.busy else { return }
        guard supportsOnDevicePairing else {
            message = "当前系统重新授权需连接 Mac；已保存的手机授权会保留"
            lastFailure = message
            return
        }
        resetPairing()
        if !hasRecord { startPairing() }
    }

    func registerBackgroundTask() {
        guard !registeredBackgroundTask else { return }
        if #available(iOS 26.0, *) {
            registeredBackgroundTask = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: .main) { task in
                Task { @MainActor in
                    guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                    Self.shared.begin(continued)
                }
            }
        }
    }
    func startPairing() {
        guard !running, !agentReserved, !HardwareWiFiFlow.shared.busy else { return }
        hasRecord = store.exists
        guard !hasRecord else { message = "请连接 \(route.connectionName)"; return }
        guard supportsOnDevicePairing else {
            message = "当前 iOS 首次手机操控授权需通过 Mac 完成；授权保存后可使用 USB 或硬件 Wi-Fi"
            lastFailure = message
            return
        }
        guard registeredBackgroundTask else { message = "系统配对后台任务未注册，请重新打开 App"; return }
        guard #available(iOS 26.0, *) else { message = "系统交互配对需要 iOS 26 或更新版本的持续后台任务"; return }
        generation = UUID(); running = true; pairingActive = true; message = "正在申请配对后台任务，请等待入口就绪"
        let request = BGContinuedProcessingTaskRequest(identifier: Self.taskID, title: "随办 配对", subtitle: "在系统设置中完成授权")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch { running = false; pairingActive = false; message = "系统未批准后台任务，请保持 App 在前台后重试" }
    }
    @available(iOS 26.0, *) private func begin(_ continued: BGContinuedProcessingTask) {
        guard pairingActive, running, job == nil else { continued.setTaskCompleted(success: false); return }
        let epoch = generation
        backgroundTask = continued
        continued.progress.totalUnitCount = 4; continued.progress.completedUnitCount = 1
        continued.expirationHandler = { Task { @MainActor in
            guard Self.shared.generation == epoch else { return }
            Self.shared.cancel()
        } }
        job = Task { @MainActor in
            var success = false
            defer { if generation == epoch { finishPairing(success: success) } }
            do {
                try await pairing.pair(authorized: true, persist: { record in
                    guard self.generation == epoch else { throw CancellationError() }
                    try self.store.save(record); self.hasRecord = true
                }, update: { update in
                    guard self.generation == epoch else { throw CancellationError() }
                    switch update {
                    case .listening(let advertisement):
                        let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: advertisement.identifier, port: Int32(advertisement.port))
                        service.delegate = self
                        guard service.setTXTRecord(NetService.data(fromTXTRecord: advertisement.txt.mapValues { Data($0.utf8) })) else { throw NativeBackendError.malformedEvent }
                        self.service = service; service.publish()
                        self.message = "正在发布系统配对入口"
                    case .code(let value): self.pin = value; self.message = "在系统配对页面输入此 PIN"; continued.progress.completedUnitCount = 2
                    case .persisted(let committed): self.message = committed ? "正在确认配对完成" : "正在完成配对"; continued.progress.completedUnitCount = 3
                    case .completed: self.message = "配对成功。回到 App，点击验证 \(route.connectionName) 连接"; continued.progress.completedUnitCount = 4
                    }
                })
                success = true
            } catch is CancellationError { guard generation == epoch else { return }; message = "配对已停止" }
            catch { guard generation == epoch else { return }; message = "配对未完成，请检查本地网络权限和系统配对页面" }
        }
    }
    func netServiceDidPublish(_ sender: NetService) {
        guard service === sender else { return }
        message = "打开设置 → 隐私与安全性 → 开发者模式，选择与「随办」配对"
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard service === sender else { return }
        cancel(); message = "配对入口发布失败，请检查本地网络权限后重试"
    }
    private func finishPairing(success: Bool) {
        service?.stop(); service = nil; pairing.close(); pin = nil
        backgroundTask?.setTaskCompleted(success: success); backgroundTask = nil
        running = false; pairingActive = false; job = nil; hasRecord = store.exists
    }
    func cancel() {
        if let transport = hardwareTransport {
            HardwareWiFiFlow.shared.recordConnection(transport: transport, success: false, message: "连接已停止")
        }
        hardwareTransport = nil
        connectionStopID = UUID()
        mediaLifetime.revoke()
        operationLease?.complete(success: false); operationLease = nil
        stopHeartbeat()
        generation = UUID(); controlSessionID = UUID(); agentOwner = nil; agentRuns.removeAll(); agentQueue.removeAll()
        job?.cancel(); pairing.close(); service?.stop(); service = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        if pairingActive { finishPairing(success: false) }
        backend.close(); client.cancel(); localDiscovery.cancel(); ready = false; mediaStarted = false; image = nil; screenshotData = nil; running = false; capturing = false; job = nil
        message = "已停止"
    }
    func background() {
        isBackground = true
        // App visibility does not revoke an authenticated device session.
        // Active runs own their system execution leases; settings operations
        // own a finite transition lease. Explicit stop/expiry/transport loss
        // still closes the session, without replaying input after reconnect.
    }
    func resume() {
        let wasBackground = isBackground
        isBackground = false
        // Cancelling an in-flight native readiness request closes its transport.
        // Scene transitions may wake an idle heartbeat, never cancel active I/O.
        if ready, wasBackground, !maintenanceBusy { startHeartbeat(immediate: true) }
        restoreConnection()
    }
    func restoreConnection() {
        hasRecord = store.exists
        if hasRecord, !pairingActive, !running, !ready { verify() }
    }
    /// Called only by a device tool or App startup, never by normal chat.
    /// Concurrent waiters share the same verification job.
    func connectIfNeeded() throws {
        guard !HardwareWiFiFlow.shared.busy else { throw NCMControlError.unavailable("正在配置硬件 Wi-Fi，请完成后再连接") }
        hasRecord = store.exists
        if ready || pairingActive { return }
        guard hasRecord else { throw NCMControlError.unavailable("请先在设置 → 手机操控 → 连接与验证中完成系统配对") }
        if !running && !agentReserved { verify() }
    }
    func verify() {
        guard !running, !agentReserved, !HardwareWiFiFlow.shared.busy, store.exists else { return }
        let previousMaintenance = heartbeatTask
        stopHeartbeat()
        mediaLifetime.revoke()
        generation = UUID(); controlSessionID = UUID(); let epoch = generation
        running = true; ready = false; mediaStarted = false; hardwareTransport = nil; image = nil; screenshotData = nil; lastFailure = nil; backend.close()
        beginOperationLease(epoch: epoch)
        job = Task { @MainActor in
            defer { if generation == epoch { finishOperationLease(); running = false; job = nil } }
            do {
                await previousMaintenance?.value
                try Task.checkCancellation()
                guard generation == epoch else { return }
                var identity = try store.load().identity(); defer { identity.clearSeed() }
                let authorization = ExistingSessionAuthorization(verifyExistingIdentity: true, screen: true, screenVideoStream: true, input: true)
                if route == .vpnLoopback {
                    message = "正在发现本机 RemotePairing 服务，请保持 VPN 回环连接开启"
                    let configuration = vpnConfiguration
                    let port = try await localDiscovery.discoverPort(configuration: configuration)
                    try Task.checkCancellation(); guard generation == epoch else { return }
                    message = "正在经 VPN 回环验证身份并建立 CoreDevice 隧道"
                    try await backend.connectLocalVPN(identity: identity, authorization: authorization, pairingPort: port, configuration: configuration)
                } else {
                    // Select once. Every socket in this attempt remains bound to
                    // the same transport; a cable/hotspot change cannot replay it.
                    let transport = try NCMProbeClient.selectHardwareTransport(wifi: HardwareWiFiFlow.shared.relayConfiguration)
                    hardwareTransport = transport
                    message = "正在通过 \(hardwareConnectionLabel) 发现手机服务"
                    var discovery = try await client.request(.discoverIPv4, transport: transport)
                    if discovery.endpoints?.contains(where: { $0.service == "remotepairing" }) != true {
                        discovery = try await client.request(.discoverIPv6, transport: transport)
                    }
                    try Task.checkCancellation(); guard generation == epoch else { return }
                    guard let endpoint = discovery.endpoints?.first(where: { $0.service == "remotepairing" }) else {
                        if case .wifi = transport, discovery.result == "unsupported" {
                            throw NCMControlError.unavailable("路由器模式未发现手机 IPv4 开发者服务；请检查开发者模式与路由器设备互通，当前不使用路由器上的 IPv6 候选")
                        }
                        throw NCMControlError.unavailable("未发现手机服务，请检查随办硬件v1 连接")
                    }
                    message = "正在通过 \(hardwareConnectionLabel) 验证身份并建立开发者隧道"
                    try await backend.connect(identity: identity, authorization: authorization, discovery: discovery, endpoint: endpoint, transport: transport)
                }
                try await backend.checkDeveloperReadiness()
                try Task.checkCancellation(); guard generation == epoch else { return }
                ready = true; startHeartbeat(); message = "\(route.connectionName) 认证、开发者隧道和服务检查成功，可测试截图与输入"
                if let transport = hardwareTransport {
                    HardwareWiFiFlow.shared.recordConnection(transport: transport, success: true, message: "身份与服务验证成功")
                }
            } catch {
                guard generation == epoch else { return }
                backend.close(); message = failure(error); lastFailure = message
                recordHardwareDisconnection("连接验证未成功")
            }
        }
    }
    #if DEBUG
    func videoDiagnosticKeyframe() async -> Data? { await backend.videoDiagnosticKeyframe() }
    #endif
    func capture() { operation(capturing: true) {
        try await self.prepareAgentInput(self.backend)
        let png = try await self.backend.captureVideoJPEG()
        try Task.checkCancellation()
        guard let image = UIImage(data: png) else { throw NativeBackendError.malformedEvent }
        self.screenshotData = png; self.image = image; self.message = "已收到手机截图"
    } }
    func tapCenter() { operation {
        try await self.prepareAgentInput(self.backend)
        _ = try await self.backend.tapDelivery(x: 32768, y: 32768)
        try Task.checkCancellation()
        self.message = "已发送屏幕中心点击，请观察手机确认实际效果"
    } }
    private func operation(capturing: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        guard ready, !running, !agentReserved else { return }
        generation = UUID(); let epoch = generation
        running = true; self.capturing = capturing
        beginOperationLease(epoch: epoch)
        job = Task { @MainActor in
            defer {
                if generation == epoch {
                    running = false; self.capturing = false; job = nil
                    finishControlMediaIfIdle()
                    if !mediaLifetime.stopping { finishOperationLease() }
                }
            }
            do {
                // User requests queue behind an in-flight keepalive; the UI only
                // becomes busy after a user operation, never for maintenance.
                while maintenanceBusy {
                    try await Task.sleep(for: .milliseconds(10))
                    guard generation == epoch else { return }
                }
                try Task.checkCancellation()
                guard generation == epoch, ready else { return }
                try await action()
                lastFailure = nil
            }
            catch {
                guard generation == epoch else { return }
                if case NativeBackendError.touchPreparationFailure = error {
                    mediaStarted = false
                    message = failure(error) + "。本次未发送点击"
                    lastFailure = message
                } else if case NativeBackendError.screenshotFailure(let stage, let cause) = error {
                    BackgroundExecutionTrace.record("screenshot.failed stage=\(stage) cause=\(cause) connectionRetained=true")
                    message = failure(error)
                    lastFailure = message
                } else {
                    stopHeartbeat(); ready = false; mediaStarted = false; backend.close()
                    image = nil; screenshotData = nil; invalidateAgentSession()
                    recordHardwareDisconnection("连接中断；本次操作不自动重试")
                    message = failure(error) + "；请重新连接 \(route.connectionName)"; lastFailure = message
                }
            }
        }
    }
    /// A task pins one authenticated session. Reconnect never silently substitutes
    /// another generation; diagnostics and task traffic share the operation gate.
    func agentOperation<T>(owner: UUID, session: UUID, action: (NativeDeveloperServices) async throws -> T) async throws -> T {
        guard ready, controlSessionID == session else { throw NCMControlError.unavailable("手机操控未连接，请在设置 → 手机操控 → 连接与验证中连接") }
        if agentOwner != owner {
            if !agentQueue.contains(owner) { agentQueue.append(owner) }
            defer { agentQueue.removeAll { $0 == owner } }
            while running || agentOwner != nil || agentQueue.first != owner {
                try Task.checkCancellation()
                guard ready, controlSessionID == session, agentRuns.contains(owner) else { throw NCMControlError.stopped }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        try Task.checkCancellation()
        guard ready, controlSessionID == session, agentRuns.contains(owner) else { throw NCMControlError.stopped }
        agentOwner = owner
        running = true
        defer { if controlSessionID == session { running = false } }
        do {
            while maintenanceBusy {
                try await Task.sleep(for: .milliseconds(10))
                guard ready, controlSessionID == session, agentOwner == owner else { throw NCMControlError.stopped }
            }
            try Task.checkCancellation()
            guard ready, controlSessionID == session, agentOwner == owner else { throw NCMControlError.stopped }
            let value = try await action(backend)
            try Task.checkCancellation()
            guard ready, controlSessionID == session, agentOwner == owner else { throw NCMControlError.stopped }
            lastFailure = nil
            return value
        } catch {
            guard controlSessionID == session else { throw NCMControlError.stopped }
            if case NativeBackendError.touchPreparationFailure = error {
                mediaStarted = false; message = failure(error) + "。本次未发送输入"; lastFailure = message
                throw NCMControlError.unavailable(message)
            }
            if case NativeBackendError.screenshotFailure(let stage, let cause) = error {
                BackgroundExecutionTrace.record("screenshot.failed stage=\(stage) cause=\(cause) connectionRetained=true")
                message = failure(error)
                lastFailure = message
                throw NCMControlError.unavailable(message)
            }
            if case NativeBackendError.applicationQueryFailure(let stage, let cause) = error {
                BackgroundExecutionTrace.record("apps.query.failed stage=\(stage) cause=\(cause)")
                throw NCMControlError.unavailable("查询已安装 App 失败，请稍后重试")
            }
            if error is CancellationError || (error as? NCMControlError) != nil {
                cancel(); throw NCMControlError.stopped
            }
            message = failure(error) + "；请重新连接 \(route.connectionName)"; lastFailure = message
            stopHeartbeat(); ready = false; mediaStarted = false; backend.close()
            image = nil; screenshotData = nil
            recordHardwareDisconnection("任务连接中断；结果未知的操作不自动重试")
            invalidateAgentSession(); running = false
            throw NCMControlError.unavailable(message)
        }
    }
    func prepareAgentInput(_ services: NativeDeveloperServices) async throws {
        if !mediaStarted {
            try await services.startTouchMedia()
            try Task.checkCancellation()
            mediaStarted = true
            mediaLifetime.didOpen()
        }
    }
    private func invalidateAgentSession() {
        mediaLifetime.revoke()
        controlSessionID = UUID(); agentOwner = nil
        agentRuns.removeAll(); agentQueue.removeAll()
    }
    func mediaLifetimeWait() async { await mediaLifetime.wait() }
    func canActivateApplication(owner: UUID, session: UUID) -> Bool {
        ready && controlSessionID == session && !running &&
            (agentOwner == owner || (agentOwner == nil && agentQueue.isEmpty))
    }
    func retainConnection(owner: UUID) { connectionUsers.insert(owner) }
    func releaseConnection(owner: UUID) {
        connectionUsers.remove(owner)
    }
    func registerAgent(owner: UUID, session: UUID) {
        guard ready, controlSessionID == session else { return }
        agentRuns.insert(owner)
    }
    func releaseAgent(owner: UUID, session: UUID) {
        guard controlSessionID == session else { return }
        agentRuns.remove(owner); agentQueue.removeAll { $0 == owner }
        guard agentOwner == owner else {
            finishControlMediaIfIdle()
            return
        }
        // Partial/cancelled operations remain fatal. Completed runs release media
        // only after the final registered controller finishes; queued runs share it.
        if running { cancel() } else {
            agentOwner = nil
            finishControlMediaIfIdle()
        }
    }
    private func finishControlMediaIfIdle() {
        guard ready, !running, mediaStarted else { return }
        let session = controlSessionID
        let accepted = mediaLifetime.finishIfIdle(hasUsers: !agentRuns.isEmpty || agentOwner != nil,
            stop: { [weak self] in
                guard let self else { throw CancellationError() }
                while self.maintenanceBusy {
                    try await Task.sleep(for: .milliseconds(10))
                    guard self.controlSessionID == session else { throw CancellationError() }
                }
                guard self.controlSessionID == session, self.ready else { throw CancellationError() }
                BackgroundExecutionTrace.record("control.mediaStopRequested scoped=true")
                try await self.backend.stopTouchMedia()
            }, completed: { [weak self] success in
                guard let self, self.controlSessionID == session else { return }
                self.running = false; self.mediaStarted = false
                self.finishOperationLease()
                if success {
                    BackgroundExecutionTrace.record("control.mediaReleased peerConfirmed=true connectionRetained=true")
                    self.message = "屏幕控制已结束"
                } else {
                    self.cancel()
                    self.message = "屏幕控制结束失败，请重新连接"
                    self.lastFailure = self.message
                }
            })
        if accepted { running = true }
    }
    /// Termination notification is best-effort; synchronous native handle close
    /// revokes all App-owned transports without waiting for an async stop reply.
    func applicationWillTerminate() { cancel() }
    private func beginOperationLease(epoch: UUID) {
        finishOperationLease()
        let lease = ExecutionTransitionLease()
        lease.expirationHandler = { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.cancel()
            self.message = "后台执行已到期，操作已停止"
            self.lastFailure = self.message
        }
        lease.begin(); operationLease = lease
    }
    private func finishOperationLease() {
        operationLease?.complete(success: true); operationLease = nil
    }
    private func stopHeartbeat() {
        heartbeatEpoch = UUID(); heartbeatTask?.cancel(); heartbeatTask = nil; maintenanceBusy = false
    }
    private func recordHardwareDisconnection(_ detail: String) {
        if let transport = hardwareTransport {
            HardwareWiFiFlow.shared.recordConnection(transport: transport, success: false, message: detail)
        }
        hardwareTransport = nil
    }
    /// Read-only service traffic keeps the ESP32's 60-second relay idle lease alive.
    /// Shares the operation gate; never overlaps a screenshot or touch request.
    private func startHeartbeat(immediate: Bool = false) {
        stopHeartbeat(); let epoch = heartbeatEpoch
        heartbeatTask = Task { @MainActor [weak self] in
            var delay: Duration = immediate ? .zero : .seconds(20)
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                delay = .seconds(20)
                guard let self, self.heartbeatEpoch == epoch, self.ready else { return }
                if self.running { continue }
                self.maintenanceBusy = true
                do {
                    try await self.backend.checkDeveloperReadiness()
                    guard self.heartbeatEpoch == epoch else { return }
                    self.maintenanceBusy = false
                } catch {
                    guard self.heartbeatEpoch == epoch else { return }
                    self.maintenanceBusy = false; self.ready = false; self.mediaStarted = false; self.running = false
                    self.backend.close(); self.invalidateAgentSession()
                    self.image = nil; self.screenshotData = nil
                    self.recordHardwareDisconnection("连接保活失败，请重新验证")
                    self.message = "连接保活失败：" + self.failure(error) + "；请重新连接 \(route.connectionName)"
                    self.lastFailure = self.message
                    return
                }
            }
        }
    }
    private func failure(_ error: Error) -> String {
        if case NCMControlError.unavailable(let message) = error { return message }
        if let probeError = error as? NCMError {
            switch probeError {
            case .interfaceUnavailable: return "未检测到硬件连接，请连接 USB 或已保存的硬件 Wi-Fi"
            case .interfaceAmbiguous: return "检测到多个硬件网络接口，请断开多余连接后重新验证"
            case .interfaceInvalid: return "硬件网络地址或接口不匹配，请重新加入硬件 Wi-Fi 或检查 USB 连接"
            case .timeout: return "硬件响应超时，请靠近硬件并重新验证"
            case .busy: return "硬件连接正在处理其他请求，请稍后重试"
            default: return "硬件通信未成功，请检查供电、已保存的硬件和本地网络权限"
            }
        }
        if let vpnError = error as? LocalVPNError {
            switch vpnError {
            case .inactive: return "未找到 VPN 接口 \(vpnConfiguration.localAddress)，请检查 VPN 是否开启及地址配置"
            case .ambiguousInterface: return "发现多个匹配的 VPN 接口，请检查连接配置"
            case .serviceNotFound: return "未发现本机 RemotePairing 服务，请检查开发者模式、系统配对和本地网络权限"
            case .ambiguousService: return "发现多个本机 RemotePairing 端口，请重新连接后再试"
            case .invalidConfiguration: return "请输入不同的有效 IPv4 接口地址和对端地址"
            case .discoveryDenied: return "本机服务发现失败，请允许本地网络访问"
            }
        }

        if case NativeBackendError.screenshotFailure(let stage, let cause) = error {
            return failure(NativeBackendError.protocolFailure(stage: stage, cause: cause))
        }

        if case NativeBackendError.touchPreparationFailure(let stage, let cause) = error {
            let labels: [UInt32: String] = [10:"视频服务可用性", 11:"触控服务可用性", 13:"视频接收端口", 14:"连接视频服务", 15:"请求视频会话", 16:"解析视频协商回复", 17:"接收有效视频包", 18:"连接触控服务"]
            let reasons: [UInt32: String] = [1:"协议错误", 2:"超时", 3:"参数无效", 4:"服务缺失", 5:"尚未就绪"]
            return "触控准备失败：\(labels[stage] ?? "视频准备")，\(reasons[cause] ?? "原因 \(cause)")"
        }
        if case NativeBackendError.protocolFailure(let stage, let cause) = error {
            if stage == 19 || stage == 20 {
                let reasons: [UInt32: String] = [1:"协议错误", 2:"超时", 3:"参数无效", 4:"服务缺失", 5:"尚未就绪", 8:"超时，未收到视频数据", 9:"超时，未收到协商匹配的视频包", 10:"超时，视频包未组成完整帧", 11:"超时，未能确认视频画面完整性", 12:"超时，视频画面超过接收大小限制", 13:"视频解码会话已失效", 14:"视频解码失败"]
                return "截图\(stage == 19 ? "服务连接" : "请求与接收")失败（\(reasons[cause] ?? "原因 \(cause)")）"
            }
            let labels: [UInt32: String] = [1:"配对身份", 2:route.connectionName + " 连接", 3:"手机身份认证", 4:"动态隧道入口", 5:"隧道 TLS", 6:"远程服务列表", 7:"开发者模式", 8:"开发者镜像", 9:"截图", 10:"屏幕视频会话", 11:"输入发送", 12:"会话关闭", 21:"App 服务"]
            let reasons: [UInt32: String] = [1:"协议错误", 2:"超时", 3:"参数无效", 4:"服务缺失", 5:"尚未就绪", 6:"屏幕会话失效", 7:"发送结果未知"]
            return "\(labels[stage] ?? "协议")失败（\(reasons[cause] ?? "原因 \(cause)")）"
        }
        if error is CancellationError { return "已停止" }
        return route == .vpnLoopback
            ? "连接失败，请检查 VPN 回环配置、开发者模式及本地网络权限"
            : "连接失败，请检查随办硬件v1 供电、USB 或硬件 Wi-Fi 和本地网络权限"
    }
    #if DEBUG
    private var backgroundProbeStarted = false
    /// Opt-in real-device acceptance probe. Uses the production bridge and
    /// scheduler; logs state/dimensions. The additional input-probe flag saves
    /// three local verification images for the reversible Home-screen swipe.
    func runBackgroundProbeIfRequested(pip: StatusPiPController? = nil) async {
        guard (ProcessInfo.processInfo.arguments.contains("--ncm-background-probe") || pip != nil), !backgroundProbeStarted else { return }
        backgroundProbeStarted = true
        let url = URL.documentsDirectory.appending(path: "ncm-background-probe.txt")
        var lines: [String] = []
        func record(_ value: String) {
            lines.append("\(Date().ISO8601Format()) \(value)")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        record("start paired=\(hasRecord)")
        if !ready && !running { verify() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !ready && running && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { record("connect failed: \(message)"); return }
        let systemScheduler = ContinuedProcessingScheduler()
        systemScheduler.diagnostic = { record($0) }
        let scheduler: any RunBackgroundScheduler = pip == nil
            ? systemScheduler : PiPBackedRunScheduler(primary: ForegroundOnlyScheduler())
        let identifier = (Bundle.main.bundleIdentifier ?? "com.ja1chen.PhoneAgent") + ".backgroundRun." + UUID().uuidString
        var lease: (any RunBackgroundLease)?
        var expired = false
        var activeBridge: NCMDeviceBridge?
        do {
            try scheduler.submit(identifier: identifier, launched: { grant in
                lease = grant
                grant.expirationHandler = { expired = true; activeBridge?.cancelTransport(); record("execution expired") }
            })
            if pip != nil { record("PiP-only acceptance active=\(pip?.active == true); combined lease=\(lease != nil); no system execution lease requested") }
            let bridge = try NCMDeviceBridge(flow: self)
            activeBridge = bridge
            defer { lease?.complete(success: !expired); scheduler.cancel(identifier: identifier) }
            do {
                let frame = try await bridge.screenshot()
                record("foreground capture \(frame.width)x\(frame.height) bytes=\(frame.png.count); background switch window=15s")
                UIApplication.shared.perform(NSSelectorFromString("suspend"))
                for step in 1...3 {
                    try await Task.sleep(for: .seconds(15))
                    guard !expired else { throw AppError.stopped }
                    record("readiness \(step) start background=\(isBackground) pip=\(pip?.active == true)")
                    while maintenanceBusy { try await Task.sleep(for: .milliseconds(10)) }
                    running = true
                    do { try await backend.checkDeveloperReadiness(); running = false }
                    catch { running = false; throw error }
                    record("readiness \(step) ok")
                    let start = ContinuousClock.now
                    let frame = try await bridge.screenshot()
                    record("capture \(step) background=\(isBackground) ready=\(ready) \(frame.width)x\(frame.height) bytes=\(frame.png.count) elapsed=\(start.duration(to: .now))")
                    lease?.report(completed: step, subtitle: "后台截图验证 \(step)/3")
                    if step == 1 && ProcessInfo.processInfo.arguments.contains("--ncm-background-input-probe") {
                        try frame.png.write(to: URL.documentsDirectory.appending(path: "ncm-input-before.png"))
                        try await bridge.authorizeTaskInput(imageID: frame.id)
                        try await bridge.drag(fromX: 52428, fromY: 32768, toX: 13107, toY: 32768, durationMS: 300, imageID: frame.id)
                        record("background swipe-left reports written")
                        lease?.report(completed: step + 1, subtitle: "后台滑动已发送，正在验证实际画面")
                        try await Task.sleep(for: .seconds(1))
                        let changed = try await bridge.screenshot()
                        try changed.png.write(to: URL.documentsDirectory.appending(path: "ncm-input-after.png"))
                        lease?.report(completed: step + 2, subtitle: "已收到滑动后的截图，正在恢复桌面")
                        try await bridge.authorizeTaskInput(imageID: changed.id)
                        try await bridge.drag(fromX: 13107, fromY: 32768, toX: 52428, toY: 32768, durationMS: 300, imageID: changed.id)
                        record("background swipe-right reports written")
                        lease?.report(completed: step + 3, subtitle: "已发送恢复滑动，正在验证桌面")
                        try await Task.sleep(for: .seconds(1))
                        let restored = try await bridge.screenshot()
                        try restored.png.write(to: URL.documentsDirectory.appending(path: "ncm-input-restored.png"))
                        record("background swipe verification images saved")
                        record("complete"); break
                    }
                }
                record("complete")
            } catch { record("capture failed background=\(isBackground): \(message); \(error)") }
            await bridge.stop()
        } catch { record("probe failed: \(error)") }
    }
    #endif
}

struct PairingSection: View {
    @State private var flow = PairingFlow.shared
    let showTouchTest: () -> Void
    private var stateText: String {
        if flow.pairingActive { return "配对中" }
        if flow.ready { return "已连接" }
        if flow.running { return "连接中" }
        return flow.hasRecord ? "未连接" : "未配对"
    }
    private var showsDetail: Bool {
        flow.lastFailure != nil || (flow.running && !flow.ready) ||
        (!flow.hasRecord && flow.message != "请先完成系统配对")
    }
    var body: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(stateText).foregroundStyle(flow.ready ? .green : .secondary)
                        if flow.running && !flow.ready { ProgressView().controlSize(.small) }
                    }
                    if showsDetail {
                        Text(flow.lastFailure ?? flow.statusText)
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("pairingResult")
                    }
                    if let pin = flow.pin {
                        Text(pin).font(.title.monospacedDigit())
                            .accessibilityIdentifier("pairingPIN")
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if !flow.ready && !flow.running && !flow.agentReserved && (flow.hasRecord || flow.supportsOnDevicePairing) {
                        Button(flow.route == .ncmDeveloper ? (flow.hasRecord ? "连接并检查" : "授权手机操控") : (flow.hasRecord ? "连接" : "配对")) {
                            if flow.hasRecord { flow.verify() }
                            else { flow.startPairing() }
                        }.disabled(flow.running || flow.agentReserved || HardwareWiFiFlow.shared.busy)
                    }
                    if !flow.ready && flow.hasRecord && !flow.running && !flow.agentReserved && flow.supportsOnDevicePairing {
                        Button("重新配对") { flow.pairAgain() }
                            .disabled(!flow.canChangeRoute || HardwareWiFiFlow.shared.busy)
                            .accessibilityIdentifier("pairAgain")
                    }
                    if flow.running || flow.ready || flow.agentReserved {
                        Button("停止") { flow.cancel() }
                    }
                }
                .buttonStyle(.bordered)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        } header: {
            Text(flow.route == .ncmDeveloper ? "3 · 手机操控验证" : "连接与验证")
        } footer: {
            if !flow.hasRecord && !flow.supportsOnDevicePairing {
                Text("当前 iOS 首次授权需将手机连接 Mac 完成，蓝牙配对不能代替手机操控授权。授权会保存，之后可直接连接 USB 或已配置的硬件 Wi-Fi。")
            }
        }
        if flow.ready {
            Section("服务验证") {
                Button { flow.capture() } label: {
                    HStack {
                        Text(flow.capturing ? "正在获取截图" : "获取截图")
                        if flow.capturing { ProgressView().controlSize(.small) }
                    }
                }.disabled(flow.running || flow.agentReserved)
                Button("点击验证", action: showTouchTest).disabled(flow.running || flow.agentReserved)
            }
            if let image = flow.image {
                Section {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("手机截图")
                } header: {
                    HStack {
                        Text("截图")
                        Spacer()
                        if let data = flow.screenshotData {
                            SaveScreenshotButton(data: data).disabled(flow.capturing)
                        }
                    }
                }
            }
        }
    }
}

/// The counter is changed only by UIKit/SwiftUI delivering a real button action,
/// never by an HID send acknowledgement. Keep this page foreground during test.
struct TouchVerificationView: View {
    let flow: PairingFlow
    @Environment(\.dismiss) private var dismiss
    @State private var count = 0
    @State private var baseline = 0
    @State private var testing = false
    @State private var result = "测试时不要用手触碰中央按钮"
    @State private var task: Task<Void, Never>?
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Button { count += 1 } label: {
                VStack {
                    Text("中央触摸目标").font(.title2)
                    Text("收到触摸：\(count)").font(.title.monospacedDigit())
                }.frame(width: 260, height: 160)
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("touchVerificationTarget")
            VStack {
                HStack { Text("真实点击验证").font(.headline); Spacer(); Button("关闭") { dismiss() }.disabled(testing) }
                Spacer()
                Text(result).multilineTextAlignment(.center).accessibilityIdentifier("touchVerificationResult")
                Text(flow.message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !flow.ready {
                    Button("重新连接 \(flow.route.connectionName)") { flow.verify() }.disabled(flow.running || flow.agentReserved)
                }
                if testing { ProgressView() }
                Button("经 \(flow.route.connectionName) 点击中央目标") { test() }.buttonStyle(.bordered).disabled(testing || !flow.ready || flow.running || flow.agentReserved)
                Text("保持此页打开。计数增加才说明界面收到触摸；单纯报告发送成功不计入。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
        .interactiveDismissDisabled()
        .onDisappear { task?.cancel(); if testing { flow.cancel() } }
    }
    private func test() {
        baseline = count; testing = true; result = "准备视频会话并发送一次中央点击，请勿手动触摸"
        task = Task { @MainActor in
            defer { testing = false; task = nil }
            flow.tapCenter()
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    if !flow.running {
                        try await Task.sleep(for: .milliseconds(500))
                        result = count > baseline ? "验证通过：测试页面实际收到触摸，计数增加" : "未确认实际点击：计数未变化。\n\(flow.message)"
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                flow.cancel()
                result = "等待超时，未确认实际点击；不会自动重发"
            } catch { result = "测试已停止" }
        }
    }
}
