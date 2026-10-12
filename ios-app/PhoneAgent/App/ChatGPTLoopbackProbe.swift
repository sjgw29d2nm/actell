#if DEBUG
import SwiftUI
import AuthenticationServices
import SafariServices
import Network

/// Local-only system-browser experiment. Never contacts OpenAI, loads saved
/// credentials, exchanges a code or marks a real account connected.
@MainActor final class ChatGPTLoopbackProbe: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding, SFSafariViewControllerDelegate {
    @Published private(set) var stage = "尚无 HTTP 请求"
    @Published var lifecycle = "尚未记录"
    @Published private(set) var message = "本地浏览器回调实验：未开始"
    private var listener: NWListener?
    private var browser: ASWebAuthenticationSession?
    private var safariView: SFSafariViewController?
    private var timeout: Task<Void, Never>?
    private var pending: ChatGPTAuthorizationAttempt?
    private var connections: [NWConnection] = []
    private var running = false
    private let queue = DispatchQueue(label: "chatgpt.loopback.probe")

    func start(redirectEnabled: Bool = true, externalSafari: Bool = false, embeddedSafari: Bool = false) {
        guard !running else { return }
        running = true; stage = "监听已启动，等待 HTTP 请求"; message = "本地浏览器回调实验：等待浏览器"
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let newListener = try NWListener(using: parameters)
            listener = newListener
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor in
                        guard let self, self.running else { return }
                        self.stage = "监听就绪，正在打开浏览器"
                        self.openBrowser(redirectEnabled: redirectEnabled, externalSafari: externalSafari, embeddedSafari: embeddedSafari)
                    }
                case .failed(let error):
                    let reason = error.localizedDescription
                    Task { @MainActor in self?.finish("本地浏览器回调实验：监听失败（\(reason)）") }
                case .waiting(let error):
                    let reason = error.localizedDescription
                    Task { @MainActor in self?.stage = "监听等待：\(reason)" }
                default: break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receive(connection, redirectEnabled: redirectEnabled) }
            }
            newListener.start(queue: queue)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                self?.finish("本地浏览器回调实验：超时，监听已释放")
            }
        } catch { finish("本地浏览器回调实验：监听失败") }
    }
    private func openBrowser(redirectEnabled: Bool, externalSafari: Bool, embeddedSafari: Bool) {
        guard running, pending == nil, let port = listener?.port else { return }
        do {
            let redirect = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
            pending = try ChatGPTAuthorizationAttempt(redirect: redirect)
            let url = URL(string: "http://127.0.0.1:\(port.rawValue)/mock/authorize")!
            if embeddedSafari {
                let safari = SFSafariViewController(url: url)
                safari.delegate = self; safari.modalPresentationStyle = .pageSheet
                safariView = safari
                guard var presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: { $0.isKeyWindow })?.rootViewController else { finish("本地浏览器回调实验：Safari 界面不可用"); return }
                while let presented = presenter.presentedViewController { presenter = presented }
                presenter.present(safari, animated: true)
                return
            }
            if externalSafari {
                UIApplication.shared.open(url) { [weak self] opened in
                    Task { @MainActor in if !opened { self?.finish("本地浏览器回调实验：Safari 启动失败") } }
                }
                return
            }
            // nil deliberately does not register or substitute a custom callback
            // scheme: the actual return is handled by the HTTP loopback listener.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
                Task { @MainActor in
                    guard let self, self.running else { return }
                    if let error = error as NSError? {
                        if error.domain == ASWebAuthenticationSessionErrorDomain && error.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                            self.finish("本地浏览器回调实验：已取消，监听已释放")
                        } else { self.finish("本地浏览器回调实验：系统会话失败（代码 \(error.code)），监听已释放") }
                    } else { self.finish("本地浏览器回调实验：系统会话结束") }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            browser = session
            guard session.start() else { finish("本地浏览器回调实验：系统浏览器启动失败"); return }
        } catch { finish("本地浏览器回调实验：准备失败") }
    }
    private func receive(_ connection: NWConnection, redirectEnabled: Bool) {
        guard running else { connection.cancel(); return }
        connections.append(connection); connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            Task { @MainActor in self?.handle(data, connection: connection, redirectEnabled: redirectEnabled) }
        }
    }
    private func handle(_ data: Data?, connection: NWConnection, redirectEnabled: Bool) {
        guard running, let data, let first = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first,
              first.hasPrefix("GET "), let path = first.split(separator: " ").dropFirst().first,
              let attempt = pending else { connection.cancel(); return }
        if path == "/mock/authorize" {
            stage = "已收到本地 mock 授权页请求"
            if redirectEnabled {
                let location = attempt.redirect.absoluteString + "?code=local_mock&state=\(attempt.state)&client_id=oaiapp_local_mock"
                send("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", on: connection)
            } else {
                let html = "<html><body><h1>Local OAuth fixture</h1><p>No account or credentials. Waiting for cancellation/timeout.</p></body></html>"
                send("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)", on: connection)
            }
        } else if path.hasPrefix("/auth/callback?") {
            stage = "已收到 HTTP 回环回调"
            do {
                let url = URL(string: "http://127.0.0.1:\(attempt.redirect.port!)" + String(path))!
                _ = try attempt.validateCallback(url)
                send("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK", on: connection, successMessage: "本地浏览器回调实验：HTTP 回调验证成功，监听已释放")
            } catch { finish("本地浏览器回调实验：回调校验失败，监听已释放") }
        } else { connection.cancel() }
    }
    private func send(_ value: String, on connection: NWConnection, successMessage: String? = nil) {
        connection.send(content: Data(value.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            if let successMessage { Task { @MainActor in self?.finish(successMessage) } }
        })
    }
    func cancel() { if running { finish("本地浏览器回调实验：已取消，监听已释放") } }
    private func finish(_ result: String) {
        guard running else { return }
        running = false; message = result; pending = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections { connection.cancel() }; connections.removeAll()
        browser?.cancel(); browser = nil
        safariView?.dismiss(animated: true); safariView = nil
    }
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) { cancel() }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? UIWindow()
    }
}

struct ChatGPTLoopbackProbeView: View {
    @StateObject private var probe = ChatGPTLoopbackProbe()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Section("本地 mock · 不进行真实授权") {
            Text(probe.message).accessibilityIdentifier("chatGPTLoopbackStatus")
            Text(probe.stage).accessibilityIdentifier("chatGPTLoopbackStage")
            Text("实验场景状态：" + probe.lifecycle).accessibilityIdentifier("chatGPTLoopbackLifecycle")
            Button("测试本地系统浏览器回调") { probe.start() }.accessibilityIdentifier("chatGPTLoopbackStart")
            Button("测试内嵌系统 Safari 回调") { probe.start(embeddedSafari: true) }.accessibilityIdentifier("chatGPTLoopbackEmbeddedSafari")
            Button("测试外部 Safari 回调") { probe.start(externalSafari: true) }.accessibilityIdentifier("chatGPTLoopbackSafari")
            Button("测试本地等待页面") { probe.start(redirectEnabled: false) }.accessibilityIdentifier("chatGPTLoopbackWait")
            Button("取消本地浏览器实验") { probe.cancel() }.accessibilityIdentifier("chatGPTLoopbackCancel")
        }.onDisappear { probe.cancel() }
            .onChange(of: scenePhase) { _, value in probe.lifecycle += " → " + String(describing: value) }
    }
}
#endif
