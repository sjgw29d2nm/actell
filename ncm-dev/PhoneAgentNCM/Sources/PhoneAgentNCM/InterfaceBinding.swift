// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from committed PA3 interface selection; no PA3/HID dependency.
import Foundation
import Network
import Darwin

/// Credentials received from the selected hardware over Bluetooth. The first
/// wireless version uses the hardware's own hotspot, without a default route.
public struct WirelessRelayConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let localAddress: String
    public let boardAddress: String
    public let relayToken: String
    let localIPv4: UInt32 = 0xc0a80802
    let boardIPv4: UInt32 = 0xc0a80801

    public init(localAddress: String, boardAddress: String, relayToken: String) throws {
        guard localAddress == "192.168.8.2", boardAddress == "192.168.8.1",
              relayToken.utf8.count == 64,
              relayToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NCMError.interfaceInvalid
        }
        self.localAddress = localAddress
        self.boardAddress = boardAddress
        self.relayToken = relayToken
    }
    public var description: String { "WirelessRelayConfiguration(localAddress: \(localAddress), boardAddress: \(boardAddress), relayToken: [REDACTED])" }
    public var debugDescription: String { description }
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
    static func validateType(_ type: NWInterface.InterfaceType) throws {
        switch type {
        case .wiredEthernet, .other: break // .other additionally requires IFT_ETHER and no POINTOPOINT above.
        default: throw NCMError.interfaceInvalid
        }
    }
    static func resolve(_ rows: [Row]) throws -> NCMInterfaceBinding {
        let row = try select(rows)
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
        guard row.index > 0, row.mask == netmask, row.flags & required == required,
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
