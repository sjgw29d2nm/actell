// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

/// Short, bounded connections to S3 diagnostics, never to the phone's own
/// RemotePairing address. One command at a time; no reconnect or action replay.
@MainActor public final class NCMProbeClient {
    private struct Pending {
        let id: UUID
        let connection: NWConnection
        let continuation: CheckedContinuation<DiagnosticReply, Error>
        var bytes = Data()
        var sent = false
    }
    private var pending: Pending?
    private var timer: Task<Void, Never>?
    public init() {}

    /// IPv4 on the actual Wi-Fi interface, independent of the default route.
    /// Invalid or multiple Wi-Fi bindings are errors, never permission to join another network.
    public static func currentWiFiNetwork() throws -> WiFiNetworkBinding? {
        try NCMInterfaceBinding.currentWiFiNetwork(NCMInterfaceBinding.inventory())
    }

    /// Never interpret an IPv6-only Wi-Fi network, policy denial or an unknown
    /// path as absence of Wi-Fi. No connection or network reconfiguration occurs.
    public static func hasConnectedWiFi() async throws -> Bool {
        try Task.checkCancellation()
        if try currentWiFiNetwork() != nil { return true }
        return try await WiFiConnectionCheck().check()
    }

    /// USB wins only when initially selecting a connection attempt. An invalid
    /// or ambiguous USB interface is an error, never permission to use Wi-Fi.
    public static func selectHardwareTransport(wifi: WirelessRelayConfiguration?) throws -> HardwareRelayTransport {
        let rows = try NCMInterfaceBinding.inventory()
        let usb = try NCMInterfaceBinding.usbCandidates(rows)
        if !usb.isEmpty {
            _ = try NCMInterfaceBinding.resolve(usb)
            return .usb
        }
        guard let wifi else { throw NCMError.interfaceUnavailable }
        let transport = HardwareRelayTransport.wifi(wifi)
        _ = try NCMInterfaceBinding.resolve(rows, transport: transport)
        return transport
    }

    public func request(_ command: DiagnosticCommand, transport: HardwareRelayTransport = .usb) async throws -> DiagnosticReply {
        guard pending == nil else { throw NCMError.busy }
        try Task.checkCancellation()
        let binding = try NCMInterfaceBinding.resolve(NCMInterfaceBinding.inventory(), transport: transport)
        let connection = NWConnection(host: .ipv4(binding.remoteAddress), port: 28767, using: binding.parameters())
        let authorization: WirelessRelayConfiguration?
        if case .wifi(let configuration) = transport { authorization = configuration }
        else { authorization = nil }
        return try await exchange(command, connection: connection, authorization: authorization)
    }
    // Internal test seam: the public path always resolves and binds the selected interface.
    func exchange(_ command: DiagnosticCommand, connection: NWConnection, timeout: Duration = .seconds(7), authorization: WirelessRelayConfiguration? = nil) async throws -> DiagnosticReply {
        guard pending == nil else { throw NCMError.busy }
        try Task.checkCancellation()
        // No authentication ACK is expected. The hardware forwards the command
        // after checking this header, then returns the unchanged ND1 reply.
        var requestBytes = Data()
        if let authorization { requestBytes.append(contentsOf: "NW1 AUTH \(authorization.relayToken)\n".utf8) }
        requestBytes.append(contentsOf: command.wire.utf8)
        let wireBytes = requestBytes
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = Pending(id: id, connection: connection, continuation: continuation)
                connection.stateUpdateHandler = { [weak self] state in
                    // Network callbacks execute on the explicitly selected main queue.
                    Task { @MainActor [weak self] in
                        guard let self, self.pending?.id == id else { return }
                        switch state {
                        case .ready:
                            guard self.pending?.sent == false else { return }
                            self.pending?.sent = true
                            connection.send(content: wireBytes, completion: .contentProcessed { [weak self] error in
                                Task { @MainActor [weak self] in
                                    if error != nil { self?.finish(id, .failure(NCMError.network)) }
                                    else { self?.receive(id) }
                                }
                            })
                        case .failed: self.finish(id, .failure(NCMError.network))
                        case .cancelled: self.finish(id, .failure(NCMError.disconnected))
                        default: break
                        }
                    }
                }
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id, .failure(NCMError.timeout))
                }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }
    public func cancel() {
        if let id = pending?.id { finish(id, .failure(CancellationError())) }
    }
    private func receive(_ id: UUID) {
        guard let current = pending, current.id == id else { return }
        current.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.pending?.id == id else { return }
                if let data { self.pending?.bytes.append(data) }
                guard let bytes = self.pending?.bytes, bytes.count <= 4096 else {
                    self.finish(id, .failure(NCMError.malformedReply)); return
                }
                if error != nil { self.finish(id, .failure(NCMError.network)) }
                else if complete { self.finish(id, Result { try DiagnosticReply.decode(bytes) }) }
                else { self.receive(id) }
            }
        }
    }
    private func finish(_ id: UUID, _ result: Result<DiagnosticReply, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        timer?.cancel(); timer = nil
        current.connection.stateUpdateHandler = nil
        current.connection.cancel()
        current.continuation.resume(with: result)
    }
}

@MainActor private final class WiFiConnectionCheck {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var continuation: CheckedContinuation<Bool, Error>?
    private var timer: Task<Void, Never>?
    private var finished = false

    func check() async throws -> Bool {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                monitor.pathUpdateHandler = { [weak self] path in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch path.status {
                        case .satisfied:
                            self.finish(path.usesInterfaceType(.wifi) ? .success(true) : .failure(NCMError.network))
                        case .unsatisfied:
                            // An available Wi-Fi interface or policy denial can
                            // be an associated IPv6/local-only network. Fail closed.
                            if path.unsatisfiedReason == .notAvailable,
                               !path.usesInterfaceType(.wifi),
                               !path.availableInterfaces.contains(where: { $0.type == .wifi }) {
                                self.finish(.success(false))
                            } else { self.finish(.failure(NCMError.network)) }
                        case .requiresConnection:
                            self.finish(.failure(NCMError.network))
                        @unknown default:
                            self.finish(.failure(NCMError.network))
                        }
                    }
                }
                timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    self?.finish(.failure(NCMError.timeout))
                }
                monitor.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }
    private func finish(_ result: Result<Bool, Error>) {
        guard !finished, let continuation else { return }
        finished = true; self.continuation = nil
        timer?.cancel(); timer = nil
        monitor.pathUpdateHandler = nil; monitor.cancel()
        continuation.resume(with: result)
    }
}
