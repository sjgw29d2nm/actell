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
                    if state.state == "failed" { throw AppError.unavailable("硬件连接路由器失败，请核对名称、密码与 2.4GHz 网络；原配置保留") }
                    if state.state == "ready", state.ssid == requestedSSID, let boardAddress = state.board_ip,
                       let mask = state.netmask, mask == current.subnetMask {
                        let received = HardwareWiFiProfile(version: 1, id: ap.id, ssid: state.ssid, passphrase: "",
                            relay_token: ap.relay_token, local_ip: current.localAddress, board_ip: boardAddress,
                            mode: "router", netmask: mask)
                        try received.validate(expectedBoardID: bluetooth.boardID)
                        guard let configuration = received.relayConfiguration else { throw AppError.invalid("硬件配置无效") }
                        let reply = try await NCMProbeClient().request(.status, transport: .wifi(configuration))
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
    private var canChangeBluetooth: Bool { control.canChangeRoute && !wifi.busy }
    var body: some View {
        Form {
            Section {
                LabeledContent("当前操控模式", value: control.route.title)
                if control.route == .ncmDeveloper {
                    LabeledContent("实际操控通道", value: control.ready ? control.hardwareConnectionLabel : "未连接")
                } else {
                    Button("使用随办硬件v1操控") { _ = control.selectRoute(.ncmDeveloper) }
                        .disabled(!canChangeBluetooth)
                }
            } header: { Text("连接方式") } footer: {
                Text("首次无线配置：连接蓝牙 → 在 App 配置并连接 Wi-Fi → 完成手机操控授权并检查连接。全程无需按板子按钮。配置保存后可只用 Wi-Fi，蓝牙无需持续连接。")
                Text("USB 优先。同一次操控固定使用一种通道；拔线或网络断开后会停止，请重新连接，不会自动重发动作。")
            }
            bluetoothSection
            if !bluetooth.connected && !bluetooth.connecting && !bluetooth.devices.isEmpty {
                Section("附近的硬件") {
                    ForEach(bluetooth.devices) { device in
                        Button { bluetooth.connect(device) } label: {
                            HStack { Text(device.name); Spacer(); Text("\(device.signal) dBm").font(.caption).foregroundStyle(.secondary) }
                        }.disabled(!canChangeBluetooth)
                    }
                }
            }
            wifiSection
            if control.route == .ncmDeveloper {
                PairingSection { showingTouchTest = true }
            }
            if !wifi.history.isEmpty {
                Section("连接记录") {
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
        .navigationTitle("随办硬件v1")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingTouchTest) { TouchVerificationView(flow: control) }
        .confirmationDialog("清除本机硬件 Wi-Fi 配置和连接记录？", isPresented: $clearConfirmation, titleVisibility: .visible) {
            Button("清除", role: .destructive) { wifi.clearConfiguration() }
        } message: { Text("下次无线使用需重新连接蓝牙，在 App 重新配网。系统开发者配对身份会保留。") }
        .onAppear {
            wifi.reload(); wifi.refreshNetwork()
            #if DEBUG
            if !ProcessInfo.processInfo.arguments.contains("--hardware-bluetooth-probe") { control.resume() }
            #else
            control.resume()
            #endif
        }
        .onChange(of: wifi.currentWiFiName) { oldValue, newValue in
            if routerSSID.isEmpty || routerSSID == oldValue { routerSSID = newValue }
        }
        .onDisappear { bluetooth.stopScan() }
    }
    private var bluetoothSection: some View {
        Section {
            Label(bluetooth.message, systemImage: bluetooth.connected ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
            if bluetooth.connecting { ProgressView("正在连接蓝牙") }
            if bluetooth.connected {
                LabeledContent("设备", value: bluetooth.boardName)
                LabeledContent("设备编号", value: bluetooth.boardID)
                Button("断开蓝牙", role: .destructive) { bluetooth.disconnect() }.disabled(bluetooth.busy || !canChangeBluetooth)
            } else if !bluetooth.connecting {
                if bluetooth.rememberedPeripheralID != nil {
                    Button("重连已保存的蓝牙设备") { bluetooth.reconnectRemembered() }.disabled(!canChangeBluetooth)
                }
                Button(bluetooth.scanning ? "停止查找" : "查找硬件") {
                    if bluetooth.scanning { bluetooth.stopScan() } else { bluetooth.scan() }
                }.disabled(!canChangeBluetooth)
                if bluetooth.scanning { ProgressView() }
            } else {
                Button("停止蓝牙连接") { bluetooth.disconnect() }
            }
        } header: { Text("1 · 蓝牙与设备") } footer: {
            Text("连接蓝牙时会自动检查双向通信，用于首次配网与识别硬件。手机操控还需完成下方的连接检查，无需重复测试蓝牙。")
        }
    }
    private var wifiSection: some View {
        Section {
            Text(wifi.networkStatus).font(.footnote).foregroundStyle(.secondary)
            Button("重新检查手机网络") { wifi.refreshNetwork() }.disabled(wifi.busy)
            Text(wifi.statusText).font(.footnote).foregroundStyle(.secondary)
            if wifi.hasConfiguration {
                LabeledContent("已保存网络", value: wifi.ssid)
                LabeledContent("配置方式", value: wifi.savedModeTitle)
                LabeledContent("已保存的设备", value: wifi.boardID)
                if let hotspot = wifi.backupHotspotSSID { LabeledContent("备用硬件热点", value: hotspot) }
                Text("硬件连接凭据保存在本机钥匙串，路由器密码不会长期保存在 App").font(.caption).foregroundStyle(.secondary)
                Button("检查或连接已保存网络") { wifi.join() }
                    .disabled(!wifi.canConfigure)
                    .accessibilityIdentifier("joinHardwareWiFi")
            }
            if wifi.usesRouterNetwork {
                Button("读取当前 Wi-Fi 名称") { wifi.readCurrentWiFiName() }.disabled(wifi.busy)
                TextField("当前 Wi-Fi 名称（隐藏网络也可手填）", text: $routerSSID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(wifi.busy)
                SecureField("Wi-Fi 密码（开放网络留空）", text: $routerPassword)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(wifi.busy)
                Button("让硬件加入当前 Wi-Fi") {
                    let password = routerPassword; routerPassword = ""
                    wifi.configureRouter(ssid: routerSSID, passphrase: password)
                }.disabled(!wifi.canConfigure || !bluetooth.connected || !bluetooth.supportsRouterConfiguration)
                    .accessibilityIdentifier("configureHardwareRouterWiFi")
                Button("只读取硬件热点备用配置") { wifi.readConfiguration() }
                    .disabled(!wifi.canConfigure || !bluetooth.connected || !bluetooth.supportsWiFiConfiguration)
            } else {
                Button(wifi.hasConfiguration ? "重新读取硬件热点并连接" : "配置并连接硬件热点") { wifi.readConfiguration(joinAfterSave: true) }
                    .disabled(!wifi.canConfigure || !bluetooth.connected || !bluetooth.supportsWiFiConfiguration)
                    .accessibilityIdentifier("readHardwareWiFiConfiguration")
            }
            if wifi.hasRouterConfiguration {
                Button("通过蓝牙刷新硬件路由器地址") { wifi.refreshRouterAddress() }
                    .disabled(!wifi.canConfigure || !bluetooth.connected || !bluetooth.supportsRouterConfiguration)
            }
            if wifi.busy {
                ProgressView("正在配置")
                Button("停止配置") { wifi.cancelConfiguration() }
            }
            if wifi.hasConfiguration {
                Button("清除本机硬件配置与连接记录", role: .destructive) { clearConfirmation = true }
                    .disabled(!wifi.canConfigure)
            }
        } header: { Text("2 · Wi-Fi 配置") } footer: {
            Text("手机已有 Wi-Fi 时会保留原网络，让硬件加入同一路由器。手机没有 Wi-Fi 时才申请加入硬件热点。全程无需硬件按键；配网前请停止当前操控并拔下手机与硬件间的 USB 线，编程 USB 供电可保留。")
            if bluetooth.connected && !bluetooth.supportsWiFiConfiguration { Text("当前固件未提供 Wi-Fi 配置，需要先更新硬件固件。") }
            Text("路由器须支持 2.4GHz，并允许设备互相通信。开放网络密码留空；隐藏网络需要真实 Wi-Fi 名称，可手动填写。随办不能读取系统保存的 Wi-Fi 密码。硬件地址改变时通过蓝牙刷新。")
            Text("读取 Wi-Fi 名称可能需要 iOS 定位授权；仅在点击读取按钮时申请，不获取坐标。无法识别名称时可手填。")
            Text("硬件热点不提供互联网。随办调用智谱等模型时，手机还需可用的蜂窝网络或其他独立上网路径，实际联网情况需在手机上验证。")
        }
    }
}
