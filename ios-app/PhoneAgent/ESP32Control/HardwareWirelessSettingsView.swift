// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import NetworkExtension
@preconcurrency import CoreLocation

/// The complete configuration is stored only in this app's protected Keychain.
/// Public UI and connection history never contain the passphrase or relay token.
struct HardwareWiFiProfile: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let version: Int
    let id: String
    let ssid: String
    let passphrase: String
    let relay_token: String
    let local_ip: String
    let board_ip: String
    let mode: String?
    let netmask: String?
    var isRouter: Bool { mode == "router" }
    init(version: Int, id: String, ssid: String, passphrase: String, relay_token: String,
         local_ip: String, board_ip: String, mode: String? = nil, netmask: String? = nil) {
        self.version = version; self.id = id; self.ssid = ssid; self.passphrase = passphrase
        self.relay_token = relay_token; self.local_ip = local_ip; self.board_ip = board_ip
        self.mode = mode; self.netmask = netmask
    }

    func validate(expectedBoardID: String) throws {
        guard version == 1, id == expectedBoardID, id.utf8.count == 12,
              id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              mode == nil || mode == "hotspot" || mode == "router" else {
            throw AppError.invalid("硬件 Wi-Fi 配置不匹配，请重新连接正确的板子")
        }
        if isRouter {
            guard !ssid.isEmpty, ssid.utf8.count <= 32, !ssid.utf8.contains(0), passphrase.isEmpty, let netmask else { throw AppError.invalid("路由器配置无效，请重新配网") }
            _ = try WirelessRelayConfiguration(localAddress: local_ip, boardAddress: board_ip, relayToken: relay_token, subnetMask: netmask)
        } else {
            let fixedPool = (local_ip == "192.168.8.2" && board_ip == "192.168.8.1") || (local_ip == "172.31.254.2" && board_ip == "172.31.254.1")
            guard ssid == "Suiban-v1-\(id.suffix(6))", fixedPool,
                  netmask == nil || netmask == "255.255.255.0", (8...63).contains(passphrase.utf8.count),
                  passphrase.utf8.allSatisfy({ (32...126).contains($0) }) else { throw AppError.invalid("硬件热点配置无效，请重新读取") }
            _ = try WirelessRelayConfiguration(localAddress: local_ip, boardAddress: board_ip, relayToken: relay_token)
        }
    }
    var relayConfiguration: WirelessRelayConfiguration? {
        try? WirelessRelayConfiguration(localAddress: local_ip, boardAddress: board_ip, relayToken: relay_token, subnetMask: netmask ?? "255.255.255.0")
    }
    var description: String { "HardwareWiFiProfile(id: \(id), ssid: \(ssid), credentials: [REDACTED])" }
    var debugDescription: String { description }
}

@MainActor final class HardwareWiFiFlow: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = HardwareWiFiFlow()
    private static let secretAccount = "suiban-hardware-wifi-v1"
    private static let historyKey = "suibanHardware.connectionHistory.v1"
    struct ConnectionRecord: Codable, Identifiable {
        let id: UUID
        let date: Date
        let boardID: String?
        let transport: String
        let success: Bool
        let message: String
    }
    private struct PendingHotspot {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    @Published private(set) var statusText = "尚未保存硬件 Wi-Fi 配置"
    @Published private(set) var busy = false
    @Published private(set) var joined = false
    @Published private(set) var ssid = ""
    @Published private(set) var boardID = ""
    @Published private(set) var history: [ConnectionRecord] = []
    @Published private(set) var currentWiFiName = ""
    @Published private(set) var usesRouterNetwork = false
    @Published private(set) var networkStatus = "正在检查手机 Wi-Fi"
    private var locationManager: CLLocationManager?
    private var nameRequested = false
    private var profile: HardwareWiFiProfile?
    private var hotspotProfile: HardwareWiFiProfile?
    private var routerProfile: HardwareWiFiProfile?
    private var confirmedNetwork: WiFiNetworkBinding?
    private var confirmedConfiguration: WirelessRelayConfiguration?
    private struct SavedProfiles: Codable {
        let version: Int
        let hotspot: HardwareWiFiProfile?
        let router: HardwareWiFiProfile?
    }
    private var operationID: UUID?
    private var operation: Task<Void, Never>?
    private var pendingHotspot: PendingHotspot?
    private var hotspotTimer: Task<Void, Never>?
    private var joiningSSID: String?
    private var networkCheckID = UUID()

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.historyKey), data.count <= 64 * 1024,
           let records = try? JSONDecoder().decode([ConnectionRecord].self, from: data) {
            history = Array(records.filter { $0.message.count <= 240 && ["USB", "Wi-Fi"].contains($0.transport) }.prefix(20))
        }
        reload()
    }
    var relayConfiguration: WirelessRelayConfiguration? {
        if profile == nil { reload() }
        guard let current = try? NCMProbeClient.currentWiFiNetwork() else { clearConfirmedConnection(); return nil }
        if confirmedNetwork != current { clearConfirmedConnection() }
        let candidates = relayCandidates(network: current)
        if confirmedNetwork == current, let confirmedConfiguration, candidates.contains(confirmedConfiguration) { return confirmedConfiguration }
        if confirmedConfiguration != nil { clearConfirmedConnection() }
        // Matching private subnets do not identify a network. An explicit
        // read-only check must select a candidate when AP and router overlap.
        return candidates.count == 1 ? candidates.first : nil
    }
    private func relayCandidates(network current: WiFiNetworkBinding) -> [WirelessRelayConfiguration] {
        var candidates: [WirelessRelayConfiguration] = []
        if let routerProfile, current.subnetMask == routerProfile.netmask,
           let configuration = try? WirelessRelayConfiguration(localAddress: current.localAddress, boardAddress: routerProfile.board_ip,
                relayToken: routerProfile.relay_token, subnetMask: current.subnetMask) {
            candidates.append(configuration)
        }
        if let hotspotProfile, let configuration = hotspotBinding(hotspotProfile, network: current),
           !candidates.contains(configuration) { candidates.append(configuration) }
        return candidates
    }
    private func clearConfirmedConnection() {
        confirmedNetwork = nil; confirmedConfiguration = nil; joined = false
    }
    private func hotspotBinding(_ profile: HardwareWiFiProfile, network: WiFiNetworkBinding) -> WirelessRelayConfiguration? {
        guard network.subnetMask == "255.255.255.0" else { return nil }
        let peer: String
        switch network.localAddress {
        case "192.168.8.2": peer = "192.168.8.1"
        case "172.31.254.2": peer = "172.31.254.1"
        default: return nil
        }
        return try? WirelessRelayConfiguration(localAddress: network.localAddress, boardAddress: peer,
            relayToken: profile.relay_token, subnetMask: network.subnetMask)
    }
    var savedModeTitle: String { profile?.isRouter == true ? "现有 Wi-Fi" : "硬件热点" }
    var savedRouterSSID: String? { routerProfile?.ssid }
    var currentWiFiIsHardwareHotspot: Bool { !currentWiFiName.isEmpty && currentWiFiName == hotspotProfile?.ssid }
    var configurationUnavailableReason: String? {
        if busy { return "正在配置硬件网络，请等待或点「停止配置」。" }
        if !PairingFlow.shared.canChangeRoute { return "手机操控正在连接或执行任务，请返回硬件页面停止，再修改硬件网络。" }
        if BluetoothBoardFlow.shared.busy { return "蓝牙正在处理请求，请等待完成。" }
        do {
            _ = try NCMProbeClient.selectHardwareTransport(wifi: nil)
            return "当前 USB 通道优先；无线配网前请拔下手机与硬件之间的 USB 线。编程 USB 供电可保留。"
        } catch NCMError.interfaceUnavailable { return nil }
        catch { return "USB 接口状态尚未确认，请检查手机与硬件之间的 USB 线后重试。" }
    }
    var backupHotspotSSID: String? { hotspotProfile?.ssid }
    var hasRouterConfiguration: Bool { routerProfile != nil }
    var hasConfiguration: Bool { profile != nil }
    var lastConnectedAt: Date? { history.first(where: \.success)?.date }
    var canConfigure: Bool {
        guard !busy, PairingFlow.shared.canChangeRoute, !BluetoothBoardFlow.shared.busy else { return false }
        do {
            _ = try NCMProbeClient.selectHardwareTransport(wifi: nil)
            return false
        } catch NCMError.interfaceUnavailable {
            return true
        } catch {
            return false
        }
    }
    func refreshNetwork() {
        guard !busy else { return }
        clearConfirmedConnection()
        networkCheckID = UUID()
        let checkID = networkCheckID
        if locationManager == nil { locationManager = CLLocationManager(); locationManager?.delegate = self }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let hasWiFi = try await NCMProbeClient.hasConnectedWiFi()
                guard self.networkCheckID == checkID, !Task.isCancelled else { return }
                self.usesRouterNetwork = hasWiFi
                self.networkStatus = self.usesRouterNetwork ? "保留手机现有 Wi-Fi，给硬件配置同一路由器" : "手机未连接 Wi-Fi，可使用硬件热点与蜂窝网络"
                if self.usesRouterNetwork { self.fetchCurrentWiFiName() }
                else { self.currentWiFiName = "" }
            } catch { self.networkStatus = "无法确认当前 Wi-Fi，暂不切换网络；请检查手机 Wi-Fi 后重试" }
        }
    }
    func readCurrentWiFiName() {
        guard !busy else { return }
        nameRequested = true
        if locationManager == nil { locationManager = CLLocationManager(); locationManager?.delegate = self }
        switch locationManager?.authorizationStatus {
        case .notDetermined: locationManager?.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: fetchCurrentWiFiName()
        default: networkStatus = "未允许读取 Wi-Fi 名称，可手动填写；随办不会读取系统密码"; nameRequested = false
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard nameRequested else { return }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { fetchCurrentWiFiName() }
        else if manager.authorizationStatus != .notDetermined { nameRequested = false; networkStatus = "可手动填写 Wi-Fi 名称和密码" }
    }
    private func fetchCurrentWiFiName() {
        nameRequested = false
        let checkID = networkCheckID
        let current = try? NCMProbeClient.currentWiFiNetwork()
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let name = network?.ssid
            Task { @MainActor [weak self] in
                guard let self, !self.busy, self.networkCheckID == checkID,
                      (try? NCMProbeClient.currentWiFiNetwork()) == current else { return }
                if let name, !name.isEmpty, name.utf8.count <= 32 {
                    self.currentWiFiName = name
                    if name == self.hotspotProfile?.ssid {
                        self.usesRouterNetwork = false
                        self.networkStatus = "手机当前已连接保存的硬件热点，检查连接即可，无需再次加入"
                    } else {
                        self.usesRouterNetwork = true
                        self.networkStatus = "手机当前使用 \(name)，会保留原网络；可给硬件配置同一路由器"
                    }
                } else {
                    self.currentWiFiName = ""
                    self.networkStatus = "已有 Wi-Fi 名称未识别，原网络会保留；可手填路由器，或检查已保存的硬件连接"
                }
            }
        }
    }
    func reload() {
        guard !busy else { return }
        do {
            guard let value = try SecretStore.load(Self.secretAccount) else {
                profile = nil; hotspotProfile = nil; routerProfile = nil; ssid = ""; boardID = ""
                return
            }
            guard value.utf8.count <= 8192 else { throw AppError.invalid("保存的硬件配置无效") }
            if let container = try? JSONDecoder().decode(SavedProfiles.self, from: Data(value.utf8)), container.version == 1 {
                if let hotspot = container.hotspot { try hotspot.validate(expectedBoardID: hotspot.id); guard !hotspot.isRouter else { throw AppError.invalid("热点配置无效") } }
                if let router = container.router { try router.validate(expectedBoardID: router.id); guard router.isRouter else { throw AppError.invalid("路由器配置无效") } }
                hotspotProfile = container.hotspot; routerProfile = container.router
            } else {
                let saved = try JSONDecoder().decode(HardwareWiFiProfile.self, from: Data(value.utf8))
                try saved.validate(expectedBoardID: saved.id)
                hotspotProfile = saved.isRouter ? nil : saved; routerProfile = saved.isRouter ? saved : nil
            }
            profile = routerProfile ?? hotspotProfile
            ssid = profile?.ssid ?? ""; boardID = profile?.id ?? ""
            if statusText == "尚未保存硬件 Wi-Fi 配置" { statusText = "配置已保存，可以直接加入硬件 Wi-Fi" }
        } catch {
            profile = nil; hotspotProfile = nil; routerProfile = nil; ssid = ""; boardID = ""
            statusText = "暂时无法读取硬件配置，请解锁手机；仍失败时重新连接蓝牙读取"
        }
    }
    private func requireConfigurationChangeAllowed() throws {
        guard PairingFlow.shared.canChangeRoute else {
            throw AppError.unavailable("请先停止当前操控或任务，再修改硬件配置")
        }
        do {
            _ = try NCMProbeClient.selectHardwareTransport(wifi: nil)
        } catch NCMError.interfaceUnavailable {
            return
        } catch {
            throw AppError.unavailable("USB 接口状态无效，请拔下手机与硬件之间的 USB 线后重试")
        }
        throw AppError.unavailable("USB 当前优先，请先拔下手机与硬件之间的 USB 线，再配置无线连接")
    }
    func readConfiguration(joinAfterSave: Bool = false) {
        guard !busy else { return }
        do { try requireConfigurationChangeAllowed() }
        catch { statusText = safeMessage(error); return }
        let bluetooth = BluetoothBoardFlow.shared
        guard bluetooth.connected, !bluetooth.busy else { statusText = "请先连接蓝牙"; return }
        PairingFlow.shared.cancel()
        clearConfirmedConnection()
        let id = UUID(); operationID = id; busy = true
        statusText = "正在通过蓝牙读取硬件 Wi-Fi 配置"
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var saved = false
            defer {
                let continueJoin = saved && joinAfterSave && self.operationID == id
                self.finishOperation(id)
                if continueJoin { self.join() }
            }
            do {
                let received = try await bluetooth.fetchWiFiConfiguration()
                try Task.checkCancellation()
                guard self.operationID == id else { return }
                try self.requireConfigurationChangeAllowed()
                guard bluetooth.connected, bluetooth.boardID == received.id else { throw CancellationError() }
                try received.validate(expectedBoardID: bluetooth.boardID)
                try self.saveProfile(received)
                self.statusText = "硬件热点备用配置已保存，手机现有 Wi-Fi 保留；连接时会检查实际设备"
                saved = true
            } catch is CancellationError {
                if self.operationID == id { self.statusText = "读取已停止，原配置保留" }
            } catch {
                if self.operationID == id { self.statusText = self.safeMessage(error) }
            }
        }
    }
    func configureRouter(ssid requestedSSID: String, passphrase: String) {
        guard !busy else { return }
        do { try requireConfigurationChangeAllowed() }
        catch { statusText = safeMessage(error); return }
        let bluetooth = BluetoothBoardFlow.shared
        guard bluetooth.connected, bluetooth.supportsRouterConfiguration, !bluetooth.busy else { statusText = "请连接支持路由器配网的新硬件固件"; return }
        guard !requestedSSID.isEmpty, requestedSSID.utf8.count <= 32, !requestedSSID.utf8.contains(0),
              passphrase.isEmpty || ((8...63).contains(passphrase.utf8.count) && passphrase.utf8.allSatisfy({ (32...126).contains($0) })) else {
            statusText = "请输入 Wi-Fi 名称；加密网络密码为 8～63 个英文字符，开放网络留空"; return
        }
        PairingFlow.shared.cancel()
        clearConfirmedConnection()
        let id = UUID(); operationID = id; busy = true; joined = false
        statusText = "保留手机网络，正在给硬件配置同一路由器"
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(id) }
            do {
                guard try await NCMProbeClient.hasConnectedWiFi(), let initialNetwork = try NCMProbeClient.currentWiFiNetwork() else {
                    throw AppError.unavailable("手机须先连接目标 Wi-Fi；不能确认当前网络时不会切换")
                }
                let ap = try await bluetooth.fetchWiFiConfiguration()
                try ap.validate(expectedBoardID: bluetooth.boardID)
                try Task.checkCancellation()
                guard self.operationID == id else { return }
                try self.requireConfigurationChangeAllowed()
                try await bluetooth.configureRouter(ssid: requestedSSID, passphrase: passphrase)
                self.statusText = "硬件已接收请求，正在等待路由器分配地址；不会重发配置"
                let deadline = ContinuousClock.now.advanced(by: .seconds(45))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard self.operationID == id else { return }
                    try self.requireConfigurationChangeAllowed()
                    let state = try await bluetooth.fetchRouterState()
                    guard ContinuousClock.now < deadline else { break }
                    guard let current = try NCMProbeClient.currentWiFiNetwork(), current == initialNetwork else {
                        throw AppError.unavailable("手机网络已变化，已停止等待；请在目标 Wi-Fi 下重新检查硬件状态")
                    }
                    if state.state == "failed" { throw AppError.unavailable(state.failureMessage) }
                    if state.state == "ready", state.ssid == requestedSSID, let boardAddress = state.board_ip,
                       let mask = state.netmask, mask == current.subnetMask {
                        let received = HardwareWiFiProfile(version: 1, id: ap.id, ssid: state.ssid, passphrase: "",
                            relay_token: ap.relay_token, local_ip: current.localAddress, board_ip: boardAddress,
                            mode: "router", netmask: mask)
                        try received.validate(expectedBoardID: bluetooth.boardID)
                        guard let configuration = received.relayConfiguration else { throw AppError.invalid("硬件配置无效") }
                        self.statusText = "硬件已取得路由器地址，正在检查手机与硬件能否互通"
                        let reply: DiagnosticReply
                        do { reply = try await NCMProbeClient().request(.status, transport: .wifi(configuration)) }
                        catch is CancellationError { throw CancellationError() }
                        catch { throw AppError.unavailable("硬件已入网，但手机暂时无法访问；请确认两个网络处于同一局域网，并允许设备互通") }
                        guard reply.layer == "ncm", reply.result == "diagnostic-only" else { throw AppError.unavailable("硬件未确认网络连接，请重新检查") }
                        guard self.operationID == id, !Task.isCancelled else { throw CancellationError() }
                        guard try NCMProbeClient.currentWiFiNetwork() == current else { throw AppError.unavailable("手机网络已变化，请重新检查") }
                        try self.requireConfigurationChangeAllowed()
                        try self.saveProfile(received, backupAP: ap)
                        self.confirmedNetwork = current; self.confirmedConfiguration = configuration
                        self.joined = true; self.usesRouterNetwork = true
                        self.statusText = "硬件已加入同一路由器，手机原 Wi-Fi 保留；请继续连接验证"
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                throw AppError.unavailable("等待硬件入网超时；没有重发配置，可通过蓝牙刷新网络状态")
            } catch is CancellationError {
                if self.operationID == id { self.statusText = "已停止等待；硬件可能已接收配置，没有自动重发" }
            } catch {
                if self.operationID == id { self.statusText = self.safeMessage(error) }
            }
        }
    }
    func refreshRouterAddress() {
        guard !busy, let saved = routerProfile else { return }
        do { try requireConfigurationChangeAllowed() }
        catch { statusText = safeMessage(error); return }
        let bluetooth = BluetoothBoardFlow.shared
        guard bluetooth.connected, bluetooth.boardID == saved.id else { statusText = "请连接已保存硬件的蓝牙以刷新地址"; return }
        PairingFlow.shared.cancel()
        clearConfirmedConnection()
        let id = UUID(); operationID = id; busy = true
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(id) }
            do {
                let state = try await bluetooth.fetchRouterState()
                guard self.operationID == id, !Task.isCancelled else { throw CancellationError() }
                try self.requireConfigurationChangeAllowed()
                if state.state == "failed" { throw AppError.unavailable(state.failureMessage) }
                guard state.state == "ready", state.ssid == saved.ssid, let boardAddress = state.board_ip,
                      let current = try NCMProbeClient.currentWiFiNetwork(), current.subnetMask == state.netmask else {
                    throw AppError.unavailable("硬件尚未加入已保存的网络，请确认手机和硬件使用同一路由器")
                }
                let received = HardwareWiFiProfile(version: 1, id: saved.id, ssid: saved.ssid, passphrase: "", relay_token: saved.relay_token,
                    local_ip: current.localAddress, board_ip: boardAddress, mode: "router", netmask: current.subnetMask)
                try received.validate(expectedBoardID: bluetooth.boardID)
                guard let configuration = received.relayConfiguration else { throw AppError.invalid("硬件配置无效") }
                let reply = try await NCMProbeClient().request(.status, transport: .wifi(configuration))
                guard reply.layer == "ncm", reply.result == "diagnostic-only" else { throw AppError.unavailable("硬件未确认网络连接，请重新检查") }
                guard self.operationID == id, !Task.isCancelled else { throw CancellationError() }
                guard try NCMProbeClient.currentWiFiNetwork() == current else { throw AppError.unavailable("手机网络已变化，请重新检查") }
                try self.requireConfigurationChangeAllowed()
                try self.saveProfile(received); self.statusText = "硬件地址已刷新，手机 Wi-Fi 保留；请重新连接验证"
                self.confirmedNetwork = current; self.confirmedConfiguration = configuration
                self.joined = true
            } catch { if self.operationID == id { self.statusText = self.safeMessage(error) } }
        }
    }
    private func saveProfile(_ received: HardwareWiFiProfile, backupAP: HardwareWiFiProfile? = nil) throws {
        try received.validate(expectedBoardID: received.id)
        if let backupAP { try backupAP.validate(expectedBoardID: received.id); guard !backupAP.isRouter else { throw AppError.invalid("备用热点配置无效") } }
        let savedAP = received.isRouter ? (backupAP ?? hotspotProfile) : received
        let savedRouter = received.isRouter ? received : (routerProfile?.id == received.id ? routerProfile : nil)
        guard savedAP == nil || savedAP?.id == received.id else { throw AppError.invalid("备用热点属于其他硬件，请重新读取当前硬件") }
        let data = try JSONEncoder().encode(SavedProfiles(version: 1, hotspot: savedAP, router: savedRouter))
        guard data.count <= 8192, let value = String(data: data, encoding: .utf8) else { throw AppError.invalid("硬件配置长度无效") }
        try SecretStore.save(value, account: Self.secretAccount)
        confirmedNetwork = nil; confirmedConfiguration = nil
        hotspotProfile = savedAP; routerProfile = savedRouter
        profile = received; ssid = received.ssid; boardID = received.id; joined = false
    }
    func join() {
        guard !busy else { return }
        do { try requireConfigurationChangeAllowed() }
        catch { statusText = safeMessage(error); return }
        reload()
        guard hasConfiguration else {
            statusText = "请先通过蓝牙读取并保存 Wi-Fi 配置"; return
        }
        PairingFlow.shared.cancel()
        clearConfirmedConnection()
        let id = UUID(); operationID = id; busy = true; joined = false
        statusText = "正在检查手机网络，现有 Wi-Fi 会保留"
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishOperation(id) }
            do {
                let hasWiFi = try await NCMProbeClient.hasConnectedWiFi()
                try Task.checkCancellation()
                guard self.operationID == id else { return }
                let current = try NCMProbeClient.currentWiFiNetwork()
                if hasWiFi {
                    guard let current else { throw AppError.unavailable("手机已连接 Wi-Fi，但尚无可用 IPv4 地址；原网络保留") }
                    let candidates = self.relayCandidates(network: current)
                    guard !candidates.isEmpty, candidates.count <= 2 else { throw AppError.unavailable("当前网络没有匹配的已保存硬件，请配同一路由器或通过蓝牙刷新地址；原 Wi-Fi 保留") }
                    var successful: [WirelessRelayConfiguration] = []
                    for candidate in candidates {
                        try Task.checkCancellation()
                        guard self.operationID == id else { throw CancellationError() }
                        guard try NCMProbeClient.currentWiFiNetwork() == current else { throw AppError.unavailable("手机网络已变化，请重新检查") }
                        try self.requireConfigurationChangeAllowed()
                        var accepted = false
                        do {
                            let reply = try await NCMProbeClient().request(.status, transport: .wifi(candidate))
                            accepted = reply.layer == "ncm" && reply.result == "diagnostic-only"
                        } catch is CancellationError { throw CancellationError() }
                        catch { /* Each independent candidate is checked once; no replay. */ }
                        try Task.checkCancellation()
                        guard self.operationID == id else { throw CancellationError() }
                        guard try NCMProbeClient.currentWiFiNetwork() == current else { throw AppError.unavailable("手机网络已变化，请重新检查") }
                        try self.requireConfigurationChangeAllowed()
                        if accepted { successful.append(candidate) }
                    }
                    guard successful.count == 1, let actual = successful.first else {
                        throw AppError.unavailable(successful.isEmpty ? "已保存的硬件连接均未确认，请通过蓝牙检查地址；手机 Wi-Fi 保留" : "多个硬件连接同时回应，无法唯一选择；请通过蓝牙确认配置，手机 Wi-Fi 保留")
                    }
                    self.confirmedNetwork = current; self.confirmedConfiguration = actual
                    self.joined = true; self.statusText = "已唯一确认当前网络中的硬件，未切换手机 Wi-Fi；请继续连接验证"
                    return
                }
                guard let profile = self.hotspotProfile, profile.relayConfiguration != nil else {
                    throw AppError.unavailable("未保存备用热点，请通过蓝牙读取硬件配置")
                }
                self.statusText = "请在 iPhone 系统提示中确认加入 \(profile.ssid)"
                try await self.applyHotspot(profile, operationID: id)
                try Task.checkCancellation()
                guard self.operationID == id else { return }
                self.statusText = "正在确认硬件 Wi-Fi 接口"
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                var confirmed = false
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard self.operationID == id else { return }
                    try self.requireConfigurationChangeAllowed()
                    do {
                        if let current = try NCMProbeClient.currentWiFiNetwork(), let actual = self.hotspotBinding(profile, network: current) {
                            let transport = try NCMProbeClient.selectHardwareTransport(wifi: actual)
                            if case .wifi = transport {
                                let reply = try await NCMProbeClient().request(.status, transport: transport)
                                guard reply.layer == "ncm", reply.result == "diagnostic-only" else { throw AppError.unavailable("硬件未确认网络连接，请重新检查") }
                                try Task.checkCancellation()
                                guard self.operationID == id else { return }
                                guard try NCMProbeClient.currentWiFiNetwork() == current else { throw AppError.unavailable("手机网络已变化，请重新检查") }
                                try self.requireConfigurationChangeAllowed()
                                let updated = HardwareWiFiProfile(version: 1, id: profile.id, ssid: profile.ssid, passphrase: profile.passphrase,
                                    relay_token: profile.relay_token, local_ip: actual.localAddress, board_ip: actual.boardAddress,
                                    mode: "hotspot", netmask: actual.subnetMask)
                                try self.saveProfile(updated)
                                self.confirmedNetwork = current; self.confirmedConfiguration = actual
                                confirmed = true; break
                            }
                        }
                    } catch NCMError.interfaceUnavailable {
                        // The DHCP/interface may still be appearing after system approval.
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard confirmed else { throw AppError.unavailable("未确认硬件 Wi-Fi 接口，请检查板子供电、手机 Wi-Fi，再重新加入") }
                guard self.operationID == id else { return }
                self.joined = true
                self.statusText = "已确认硬件 Wi-Fi 接口，请点击连接验证；尚未验证手机操控服务"
                self.joiningSSID = nil
            } catch is CancellationError {
                if self.operationID == id { self.statusText = "入网操作已停止；硬件配置仍保存在本机" }
            } catch {
                if self.operationID == id { self.statusText = self.safeMessage(error) }
            }
        }
    }
    private func applyHotspot(_ profile: HardwareWiFiProfile, operationID id: UUID) async throws {
        guard !profile.isRouter, !(try await NCMProbeClient.hasConnectedWiFi()) else { throw AppError.unavailable("已检测到手机 Wi-Fi，取消热点切换；原网络保留") }
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
        let configuration = NEHotspotConfiguration(ssid: profile.ssid, passphrase: profile.passphrase, isWEP: false)
        configuration.joinOnce = false
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                joiningSSID = profile.ssid
                pendingHotspot = PendingHotspot(id: id, continuation: continuation)
                hotspotTimer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(45)) } catch { return }
                    self?.finishHotspot(id, .failure(AppError.unavailable("等待系统入网确认超时，请完成或关闭系统提示后重试")))
                }
                NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == id, self.pendingHotspot?.id == id else { return }
                        if let error = error as NSError? {
                            if error.domain == NEHotspotConfigurationErrorDomain,
                               error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                                self.finishHotspot(id, .success(Void()))
                            } else if error.domain == NEHotspotConfigurationErrorDomain,
                                      error.code == NEHotspotConfigurationError.userDenied.rawValue {
                                self.finishHotspot(id, .failure(AppError.unavailable("你取消了加入 Wi-Fi，配置仍保存在本机")))
                            } else {
                                self.finishHotspot(id, .failure(AppError.unavailable("系统未完成入网，请保持随办在前台，并检查板子热点和 Wi-Fi 权限")))
                            }
                        } else { self.finishHotspot(id, .success(Void())) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishHotspot(id, .failure(CancellationError())) }
        }
    }
    private func finishHotspot(_ id: UUID, _ result: Result<Void, Error>) {
        guard let pending = pendingHotspot, pending.id == id else { return }
        pendingHotspot = nil; hotspotTimer?.cancel(); hotspotTimer = nil
        pending.continuation.resume(with: result)
    }
    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        if let ssid = joiningSSID { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) }
        if !joined { clearConfirmedConnection() }
        joiningSSID = nil; operationID = nil; busy = false; operation = nil
    }
    func cancelConfiguration() {
        guard busy, let id = operationID else { return }
        operation?.cancel(); finishHotspot(id, .failure(CancellationError()))
        clearConfirmedConnection()
        finishOperation(id)
        statusText = "配置操作已停止；已保存的硬件凭据保留。若系统入网提示仍显示，请关闭提示"
    }
    func clearConfiguration() {
        guard !busy else { return }
        do {
            try requireConfigurationChangeAllowed()
            PairingFlow.shared.cancel()
            try SecretStore.delete(Self.secretAccount)
            if let hotspotProfile { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: hotspotProfile.ssid) }
            profile = nil; hotspotProfile = nil; routerProfile = nil; ssid = ""; boardID = ""; joined = false
            confirmedNetwork = nil; confirmedConfiguration = nil
            history = []; UserDefaults.standard.removeObject(forKey: Self.historyKey)
            statusText = "本机硬件配置与连接记录已清除；板子的蓝牙配对和系统开发者配对保留"
        } catch { statusText = safeMessage(error) }
    }
    func recordConnection(transport: HardwareRelayTransport, success: Bool, message: String) {
        if !success { clearConfirmedConnection() }
        let name: String
        let recordBoardID: String?
        switch transport {
        case .usb: name = "USB"; recordBoardID = nil
        case .wifi: name = "Wi-Fi"; recordBoardID = profile?.id
        }
        var safe = message
        if let profile {
            if !profile.passphrase.isEmpty { safe = safe.replacingOccurrences(of: profile.passphrase, with: "[已隐藏]") }
            safe = safe.replacingOccurrences(of: profile.relay_token, with: "[已隐藏]")
        }
        safe = String(safe.prefix(240))
        history.insert(ConnectionRecord(id: UUID(), date: Date(), boardID: recordBoardID, transport: name,
            success: success, message: safe), at: 0)
        history = Array(history.prefix(20))
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: Self.historyKey) }
        statusText = safe == "连接已停止" ? "\(name) 连接已停止" : "\(name)：\(safe)"
    }
    private func safeMessage(_ error: Error) -> String {
        if let error = error as? AppError { return error.localizedDescription }
        return "硬件配置未完成，请检查蓝牙配对、板子供电和 Wi-Fi 状态后重试"
    }
}

struct HardwareWirelessSettingsView: View {
    @ObservedObject private var bluetooth = BluetoothBoardFlow.shared
    @ObservedObject private var wifi = HardwareWiFiFlow.shared
    @State private var control = PairingFlow.shared
    @State private var showingTouchTest = false
    @State private var clearConfirmation = false
    @State private var routerSSID = ""
    @State private var routerPassword = ""
    @State private var requiresPassword = false
    private var canChangeBluetooth: Bool { control.canChangeRoute && !wifi.busy }
    private var canUseSavedNetwork: Bool {
        if wifi.currentWiFiIsHardwareHotspot { return wifi.hasConfiguration }
        if !wifi.usesRouterNetwork { return wifi.backupHotspotSSID != nil }
        return wifi.hasRouterConfiguration
    }
    private var mainButtonTitle: String {
        if canUseSavedNetwork { return "连接已配好的硬件" }
        if bluetooth.connecting { return "正在连接硬件" }
        if !bluetooth.connected { return bluetooth.rememberedPeripheralID == nil ? "查找硬件，继续配网" : "连接硬件，继续配网" }
        return wifi.usesRouterNetwork ? "连接硬件网络" : "配置并连接备用热点"
    }
    private var mainButtonUnavailableReason: String? {
        if let reason = wifi.configurationUnavailableReason { return reason }
        if canUseSavedNetwork { return nil }
        if bluetooth.connecting { return "正在连接硬件蓝牙，连接完成后才能发送网络配置。" }
        if bluetooth.scanning { return "正在查找硬件，请在上方列表选择你的板子。" }
        if !bluetooth.connected { return nil }
        if wifi.usesRouterNetwork && !bluetooth.supportsRouterConfiguration { return "当前硬件固件尚不支持加入路由器，需要先更新固件。" }
        if !wifi.usesRouterNetwork && !bluetooth.supportsWiFiConfiguration { return "当前硬件未提供热点配置，请检查固件。" }
        if wifi.usesRouterNetwork && routerSSID.isEmpty { return "手机 Wi-Fi 名称未识别，请读取名称或手动填写真实名称。" }
        return nil
    }
    var body: some View {
        Form {
            usbConnectionSection
            if control.route == .ncmDeveloper {
                PairingSection { showingTouchTest = true }
            } else {
                Section {
                    Text("当前操控模式：\(control.route.title)").foregroundStyle(.secondary)
                    Button("使用随办硬件v1操控手机") { _ = control.selectRoute(.ncmDeveloper) }
                        .disabled(!canChangeBluetooth)
                } header: { Text("手机操控连接") } footer: {
                    Text("选择随办硬件后，可通过 USB 或已配好的无线网络连接。")
                }
            }
            Section {
                NavigationLink { BluetoothHIDSettingsView() } label: {
                    Label("蓝牙键鼠与输入验收", systemImage: "keyboard")
                }.accessibilityIdentifier("openBluetoothHIDSettings")
            } header: { Text("纯蓝牙输入") } footer: {
                Text("可单独验证蓝牙键盘和鼠标，不配置硬件 Wi-Fi。跨 App 自动执行还需手机屏幕采集及指针定位验收。")
            }
            Section {
                NavigationLink { wirelessConfigurationForm } label: {
                    Label("蓝牙与 Wi-Fi 配置", systemImage: "antenna.radiowaves.left.and.right")
                }.accessibilityIdentifier("openHardwareWirelessConfiguration")
                if wifi.busy {
                    Text("正在配置无线网络，可进入上方页面查看进度或停止配置。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("无线连接（可选）") } footer: {
                Text("使用 USB 可以跳过这里。当前蓝牙用于识别硬件和配网，完整无线操控还需要 Wi-Fi。")
            }
            if !wifi.history.isEmpty { historySection }
        }
        .navigationTitle("随办硬件v1")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingTouchTest) { TouchVerificationView(flow: control) }
        .onAppear {
            wifi.reload()
            #if DEBUG
            if !ProcessInfo.processInfo.arguments.contains("--hardware-bluetooth-probe") { control.resume() }
            #else
            control.resume()
            #endif
        }
        .onDisappear { bluetooth.stopScan() }
    }
    private var usbConnectionSection: some View {
        Section {
            Label("USB 有线连接", systemImage: "cable.connector")
            LabeledContent("实际操控通道", value: control.route == .ncmDeveloper && control.ready ? control.hardwareConnectionLabel : "尚未验证")
                .accessibilityIdentifier("hardwareControlTransport")
            Text("USB 可独立连接手机与硬件，无需先连接蓝牙或配置 Wi-Fi。接好后在下方完成手机操控连接。")
                .font(.footnote).foregroundStyle(.secondary)
            DisclosureGroup("USB 接线与网络设置") {
                Text("手机需要接到板子的原生 USB／OTG 数据口。仅把编程口（COM）接到 Mac，不能建立手机与板子的 USB 操控连接。")
                Text("Lightning 接口的手机需要支持 USB 外设的相机转换器，再通过 USB 数据线连接板子；普通 Lightning 充电线不能直接代替。供电不足时，使用转换器的辅助供电口。")
                Text("若手机已识别 USB 以太网，将其设为手动：IP 192.168.7.2，子网掩码 255.255.255.0；路由器和 DNS 留空。")
            }.font(.footnote)
        } header: { Text("硬件连接") } footer: {
            Text("连接检查会优先使用有效的 USB 通道。每次任务固定使用已验证的通道，断线后停止，不会自动改走无线或重发动作。")
        }
    }
    private var wirelessConfigurationForm: some View {
        Form {
            bluetoothSection
            if !bluetooth.connected && !bluetooth.connecting && !bluetooth.devices.isEmpty {
                Section("选择你的硬件") {
                    ForEach(bluetooth.devices) { device in
                        Button { bluetooth.connect(device) } label: {
                            HStack { Text(device.name); Spacer(); Text("\(device.signal) dBm").font(.caption).foregroundStyle(.secondary) }
                        }.disabled(!canChangeBluetooth)
                    }
                }
            }
            phoneNetworkSection
            hardwareNetworkSection
            maintenanceSection
        }
        .navigationTitle("无线配置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清除本机硬件网络配置和连接记录？", isPresented: $clearConfirmation, titleVisibility: .visible) {
            Button("清除", role: .destructive) { wifi.clearConfiguration() }
        } message: { Text("会清除已保存的路由器和备用热点配置。系统开发者配对身份会保留。") }
        .onAppear {
            if routerSSID.isEmpty { routerSSID = wifi.currentWiFiName }
            wifi.refreshNetwork()
        }
        .onChange(of: wifi.currentWiFiName) { oldValue, newValue in
            if routerSSID.isEmpty || routerSSID == oldValue { routerSSID = newValue }
        }
        .onChange(of: requiresPassword) { _, value in if !value { routerPassword = "" } }
        .onDisappear { bluetooth.stopScan() }
    }
    private var bluetoothSection: some View {
        Section {
            Label(bluetooth.connected ? "硬件蓝牙已连接" : (bluetooth.connecting ? "正在连接硬件" : "硬件蓝牙未连接"),
                  systemImage: bluetooth.connected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(bluetooth.connected ? .green : .primary)
            Text(bluetooth.message).font(.footnote).foregroundStyle(.secondary)
            if bluetooth.connected {
                LabeledContent("硬件", value: bluetooth.boardName)
            } else if bluetooth.connecting {
                ProgressView()
                Button("停止蓝牙连接") { bluetooth.disconnect() }
            } else {
                Button(bluetooth.scanning ? "停止查找" : (bluetooth.rememberedPeripheralID == nil ? "查找我的硬件" : "连接我的硬件")) {
                    if bluetooth.scanning { bluetooth.stopScan() } else { connectBluetooth() }
                }.disabled(!canChangeBluetooth)
                if bluetooth.scanning { ProgressView() }
            }
            LabeledContent("当前硬件无线能力", value: "2.4GHz Wi-Fi")
        } header: { Text("1 · 设备连接") } footer: {
            Text("首次配网需要蓝牙，连接时会自动验证双向通信。配好后可只用 Wi-Fi，蓝牙无需一直连接。")
        }
    }
    private var phoneNetworkSection: some View {
        Section {
            LabeledContent("手机当前 Wi-Fi", value: wifi.currentWiFiName.isEmpty ? (wifi.usesRouterNetwork ? "已连接，名称未识别" : "未识别名称") : wifi.currentWiFiName)
            Text(wifi.networkStatus).font(.footnote).foregroundStyle(.secondary)
            if wifi.usesRouterNetwork && wifi.currentWiFiName.isEmpty {
                Button("读取手机当前 Wi-Fi 名称") { wifi.readCurrentWiFiName() }.disabled(wifi.busy)
            }
        } header: { Text("2 · 手机网络") } footer: {
            Text("手机现在的 Wi-Fi 会保留。下面只配置随办硬件，不修改手机的 Wi-Fi 密码。")
        }
    }
    private var hardwareNetworkSection: some View {
        Section {
            if let saved = wifi.savedRouterSSID { LabeledContent("硬件已保存的路由器", value: saved) }
            else { Text("硬件尚未保存路由器配置").font(.footnote).foregroundStyle(.secondary) }
            Text(wifi.statusText).font(.footnote).foregroundStyle(.secondary)
            if wifi.usesRouterNetwork && !canUseSavedNetwork {
                TextField("硬件要加入的 Wi-Fi 名称", text: $routerSSID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(wifi.busy)
                Toggle("这个 Wi-Fi 需要密码", isOn: $requiresPassword).disabled(wifi.busy)
                if requiresPassword {
                    SecureField("供硬件入网使用的密码", text: $routerPassword)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(wifi.busy)
                } else {
                    Text("开放网络无需密码，名称会发给硬件。").font(.caption).foregroundStyle(.secondary)
                }
            } else if wifi.currentWiFiIsHardwareHotspot {
                Text("手机当前已在硬件热点，只检查连接，不会再次加入网络。").font(.footnote).foregroundStyle(.secondary)
            } else if !wifi.usesRouterNetwork {
                Text("手机没有其他 Wi-Fi 时，可以使用备用硬件热点；调用模型还需可用的蜂窝网络。").font(.footnote).foregroundStyle(.secondary)
            }
            Button(mainButtonTitle, action: performMainAction)
                .disabled(mainButtonUnavailableReason != nil)
                .accessibilityIdentifier("configureHardwareNetwork")
            if let reason = mainButtonUnavailableReason {
                Text(reason).font(.footnote).foregroundStyle(.orange)
            } else if !canUseSavedNetwork && !bluetooth.connected {
                Text("蓝牙未连接，点击上方按钮连接硬件后，再把网络设置发给硬件。").font(.footnote).foregroundStyle(.secondary)
            }
            if wifi.busy {
                ProgressView("正在配置硬件网络")
                Button("停止配置") { wifi.cancelConfiguration() }
            }
        } header: { Text("3 · 硬件网络") } footer: {
            Text("手机现有 Wi-Fi 会保留。当前随办硬件v1仅支持2.4GHz，只有5GHz信号时无法无线入网。硬件网络与手机网络的名称可以不同，但需要处于同一局域网并允许互通。")
        }
    }
    private var maintenanceSection: some View {
        Section {
            DisclosureGroup("备用热点与维护") {
                if let hotspot = wifi.backupHotspotSSID {
                    LabeledContent("备用硬件热点", value: hotspot)
                    Text("这是手机无其他 Wi-Fi 时的备用连接，不会与当前路由器同时切换。").font(.caption).foregroundStyle(.secondary)
                }
                if bluetooth.connected { LabeledContent("硬件编号", value: bluetooth.boardID) }
                Text("实际操控通道：\(control.ready ? control.hardwareConnectionLabel : "未连接")").font(.footnote).foregroundStyle(.secondary)
                Button("重新读取手机网络") { wifi.refreshNetwork() }.disabled(wifi.busy)
                Button("读取当前 Wi-Fi 名称") { wifi.readCurrentWiFiName() }.disabled(wifi.busy)
                Button("查找其他硬件") { bluetooth.scan() }.disabled(!canChangeBluetooth || bluetooth.connected || bluetooth.connecting)
                if bluetooth.connected {
                    Button("断开蓝牙") { bluetooth.disconnect() }.disabled(bluetooth.busy || !canChangeBluetooth)
                    Button("更新备用热点配置") { wifi.readConfiguration() }
                        .disabled(!wifi.canConfigure || !bluetooth.supportsWiFiConfiguration)
                }
                if wifi.hasRouterConfiguration {
                    Button("通过蓝牙刷新硬件地址") { wifi.refreshRouterAddress() }
                        .disabled(!wifi.canConfigure || !bluetooth.connected || !bluetooth.supportsRouterConfiguration)
                }
                if wifi.usesRouterNetwork && bluetooth.connected {
                    DisclosureGroup("重新配置硬件路由器") {
                        TextField("路由器 Wi-Fi 名称", text: $routerSSID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("硬件入网密码（开放网络留空）", text: $routerPassword).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("重新发送一次配置") {
                            let password = routerPassword; routerPassword = ""
                            wifi.configureRouter(ssid: routerSSID, passphrase: password)
                        }.disabled(!wifi.canConfigure || !bluetooth.supportsRouterConfiguration || routerSSID.isEmpty)
                    }
                }
                if wifi.hasConfiguration {
                    Button("清除硬件网络配置与连接记录", role: .destructive) { clearConfirmation = true }.disabled(!wifi.canConfigure)
                }
                Text("USB 优先；配网前拔下手机与硬件之间的 USB 线，编程 USB 供电可保留。读取 Wi-Fi 名称可能需要定位授权，不采集坐标，也不能读取系统保存的密码。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text("正在连接或执行任务时，网络配置会暂时不可用。")
        }
    }
    private var historySection: some View {
        Section {
            DisclosureGroup("查看连接记录") {
                if let date = wifi.lastConnectedAt { LabeledContent("最近成功", value: date.formatted(date: .abbreviated, time: .shortened)) }
                ForEach(wifi.history) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(record.transport, systemImage: record.message == "连接已停止" ? "stop.circle" : (record.success ? "checkmark.circle" : "exclamationmark.circle"))
                            Spacer()
                            Text(record.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(record.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func connectBluetooth() {
        if bluetooth.rememberedPeripheralID != nil { bluetooth.reconnectRemembered() }
        else { bluetooth.scan() }
    }
    private func performMainAction() {
        if canUseSavedNetwork { wifi.join() }
        else if !bluetooth.connected { connectBluetooth() }
        else if wifi.usesRouterNetwork {
            let password = requiresPassword ? routerPassword : ""; routerPassword = ""
            wifi.configureRouter(ssid: routerSSID, passphrase: password)
        } else { wifi.readConfiguration(joinAfterSave: true) }
    }
}
