// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from committed PA3 interface selection; no PA3/HID dependency.
import Foundation
import Network
import Darwin

/// Credentials received from the selected hardware over Bluetooth. Addresses
/// are pinned to one private LAN or the hardware hotspot, without a default route.
public struct WirelessRelayConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let localAddress: String
    public let boardAddress: String
    public let relayToken: String
    public let subnetMask: String
    let localIPv4: UInt32
    let boardIPv4: UInt32
    let subnetMaskIPv4: UInt32

    public init(localAddress: String, boardAddress: String, relayToken: String, subnetMask: String = "255.255.255.0") throws {
        let local = try WiFiNetworkBinding(localAddress: localAddress, subnetMask: subnetMask)
        let board = try WiFiNetworkBinding(localAddress: boardAddress, subnetMask: subnetMask)
        guard WiFiNetworkBinding.isPrivate(local.ipv4), WiFiNetworkBinding.isPrivate(board.ipv4),
              local.ipv4 != board.ipv4, local.ipv4 & local.maskIPv4 == board.ipv4 & local.maskIPv4,
              relayToken.utf8.count == 64,
              relayToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NCMError.interfaceInvalid
        }
        self.localAddress = localAddress
        self.boardAddress = boardAddress
        self.relayToken = relayToken
        self.subnetMask = subnetMask
        localIPv4 = local.ipv4; boardIPv4 = board.ipv4; subnetMaskIPv4 = local.maskIPv4
    }
    public var description: String { "WirelessRelayConfiguration(localAddress: \(localAddress), boardAddress: \(boardAddress), subnetMask: \(subnetMask), relayToken: [REDACTED])" }
    public var debugDescription: String { description }
}

/// An existing Wi-Fi network may use public or link-local IPv4. Detecting it
/// must still prevent hotspot switching; relay configuration separately requires RFC1918.
public struct WiFiNetworkBinding: Sendable, Equatable {
    public let localAddress: String
    public let subnetMask: String
    let ipv4: UInt32
    let maskIPv4: UInt32
    public init(localAddress: String, subnetMask: String) throws {
        guard let ip = Self.parseIPv4(localAddress), let mask = Self.parseIPv4(subnetMask),
              (8...30).contains(mask.nonzeroBitCount),
              mask.nonzeroBitCount + mask.trailingZeroBitCount == 32,
              ip >> 24 > 0, ip >> 24 != 127, ip >> 24 < 224,
              ip & ~mask != 0, ip & ~mask != ~mask else { throw NCMError.interfaceInvalid }
        self.localAddress = localAddress; self.subnetMask = subnetMask
        ipv4 = ip; maskIPv4 = mask
    }
    static func parseIPv4(_ value: String) -> UInt32? {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return nil }
        var ip: UInt32 = 0
        for piece in pieces {
            guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }),
                  let octet = UInt8(piece), String(octet) == piece else { return nil }
            ip = (ip << 8) | UInt32(octet)
        }
        return ip
    }
    static func isPrivate(_ ip: UInt32) -> Bool {
        ip >> 24 == 10 || ip & 0xfff00000 == 0xac100000 || ip >> 16 == 0xc0a8
    }
}

/// A connection attempt selects this once; probe and backend calls reuse it.
/// A disconnected transport fails rather than changing a running session.
public enum HardwareRelayTransport: Sendable, Equatable {
    case usb
    case wifi(WirelessRelayConfiguration)
}

struct NCMInterfaceBinding {
    static let localIP = "192.168.7.2"
    static let remoteIP = "192.168.7.1"
    static let netmask = "255.255.255.0"
    struct Row: Equatable {
        let name: String
        let index: UInt32
        let address: String
        let mask: String
        let flags: UInt32
        let linkType: UInt8?
    }
    let row: Row
    let interface: NWInterface
    let localAddress: IPv4Address
    let remoteAddress: IPv4Address

    static func select(_ rows: [Row]) throws -> Row {
        let matches = rows.filter { $0.address == localIP }
        guard matches.count == 1, let row = matches.first else {
            throw matches.isEmpty ? NCMError.interfaceUnavailable : NCMError.interfaceAmbiguous
        }
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        let forbidden = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
        guard row.index > 0, row.mask == netmask, row.flags & required == required,
              row.flags & forbidden == 0, row.linkType == UInt8(IFT_ETHER) else {
            throw NCMError.interfaceInvalid
        }
        return row
    }
    static func currentWiFiNetwork(_ rows: [Row]) throws -> WiFiNetworkBinding? {
        var candidates: [WiFiNetworkBinding] = []
        for row in rows {
            guard let scoped = IPv4Address("\(row.address)%\(row.name)"), let interface = scoped.interface,
                  interface.name == row.name, interface.index == Int(row.index) else {
                throw NCMError.interfaceScopeUnsupported
            }
            guard interface.type == .wifi else { continue }
            let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
            let forbidden = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
            guard row.index > 0, row.flags & required == required, row.flags & forbidden == 0,
                  row.linkType == UInt8(IFT_ETHER) else { throw NCMError.interfaceInvalid }
            candidates.append(try WiFiNetworkBinding(localAddress: row.address, subnetMask: row.mask))
        }
        guard candidates.count <= 1 else { throw NCMError.interfaceAmbiguous }
        return candidates.first
    }
    /// A router can assign the USB subnet's .2 address to real Wi-Fi. Only
    /// explicitly recognized Wi-Fi/cellular rows are excluded from USB candidates.
    static func usbCandidates(_ rows: [Row]) throws -> [Row] {
        try rows.filter { row in
            guard row.address == localIP else { return false }
            guard let scoped = IPv4Address("\(row.address)%\(row.name)"), let interface = scoped.interface,
                  interface.name == row.name, interface.index == Int(row.index) else {
                throw NCMError.interfaceScopeUnsupported
            }
            return interface.type != .wifi && interface.type != .cellular
        }
    }
    static func validateType(_ type: NWInterface.InterfaceType) throws {
        switch type {
        case .wiredEthernet, .other: break // .other additionally requires IFT_ETHER and no POINTOPOINT above.
        default: throw NCMError.interfaceInvalid
        }
    }
    static func resolve(_ rows: [Row]) throws -> NCMInterfaceBinding {
        let row = try select(usbCandidates(rows))
        // Compatibility workaround inherited from PA3: IPv4 %scope parsing is not
        // explicitly guaranteed by Apple documentation. Validate it and fail closed.
        // Validate the result; unsupported/stale scopes fail instead of unbinding.
        guard let remote = IPv4Address("\(remoteIP)%\(row.name)"),
              let local = IPv4Address("\(localIP)%\(row.name)"),
              let interface = remote.interface, local.interface == interface,
              interface.name == row.name, interface.index == Int(row.index) else {
            throw NCMError.interfaceInvalid
        }
        try validateType(interface.type)
        return NCMInterfaceBinding(row: row, interface: interface, localAddress: local, remoteAddress: remote)
    }
    static func selectWiFi(_ rows: [Row], configuration: WirelessRelayConfiguration) throws -> Row {
        let matches = rows.filter { $0.address == configuration.localAddress }
        guard matches.count == 1, let row = matches.first else {
            throw matches.isEmpty ? NCMError.interfaceUnavailable : NCMError.interfaceAmbiguous
        }
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        let forbidden = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
        guard row.index > 0, row.mask == configuration.subnetMask, row.flags & required == required,
              row.flags & forbidden == 0, row.linkType == UInt8(IFT_ETHER) else {
            throw NCMError.interfaceInvalid
        }
        return row
    }
    static func resolve(_ rows: [Row], transport: HardwareRelayTransport) throws -> NCMInterfaceBinding {
        switch transport {
        case .usb:
            return try resolve(rows)
        case .wifi(let configuration):
            let row = try selectWiFi(rows, configuration: configuration)
            guard let remote = IPv4Address("\(configuration.boardAddress)%\(row.name)"),
                  let local = IPv4Address("\(configuration.localAddress)%\(row.name)"),
                  let interface = remote.interface, local.interface == interface,
                  interface.name == row.name, interface.index == Int(row.index),
                  interface.type == .wifi else {
                throw NCMError.interfaceInvalid
            }
            return NCMInterfaceBinding(row: row, interface: interface, localAddress: local, remoteAddress: remote)
        }
    }
    func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(localAddress), port: .any)
        parameters.includePeerToPeer = false
        return parameters
    }
    static func inventory() throws -> [Row] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw NCMError.interfaceInvalid }
        defer { freeifaddrs(head) }
        var entries: [(String, String, String, UInt32)] = []
        var linkTypes: [String: UInt8] = [:]
        var cursor = head
        func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
            guard let pointer, pointer.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(pointer, socklen_t(pointer.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: buffer)
        }
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee, name = String(cString: value.ifa_name)
            if let address = ipv4(value.ifa_addr) {
                entries.append((name, address, ipv4(value.ifa_netmask) ?? "unknown", value.ifa_flags))
            }
            if let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) {
                // Read the link type only, never link-layer addresses (MACs).
                linkTypes[name] = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee.sdl_type
            }
        }
        return entries.map { name, address, mask, flags in
            Row(name: name, index: if_nametoindex(name), address: address, mask: mask, flags: flags, linkType: linkTypes[name])
        }
    }
}
