import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AgentViewModel
    @ObservedObject var statusPiP: StatusPiPController
    @ObservedObject private var sessions: ConversationStore
    let commands: SessionCommandService
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    @State private var consumedActivityNavigationID: UUID?
    @State private var search = ""
    private enum Panel: String, Identifiable { case settings; var id: String { rawValue } }
    @State private var panel: Panel?
    init(model: AgentViewModel, statusPiP: StatusPiPController, commands: SessionCommandService) {
        self.commands = commands
        self.model = model; self.statusPiP = statusPiP; self.sessions = model.sessions
    }
    private var visible: [AgentConversation] {
        sessions.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.preview.localizedCaseInsensitiveContains(search) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sessions.conversations.isEmpty {
                    emptyState
                } else {
                    List {
                        if let warning = sessions.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                        ForEach(visible) { session in
                            NavigationLink(value: session.id) {
                                conversationRow(session)
                            }
                            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 16))
                            .swipeActions { if !model.isRunning(in: session.id) { Button("删除", role: .destructive) { sessions.delete(session.id) } } }
                        }
                        if visible.isEmpty { ContentUnavailableView.search(text: search) }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("会话")
            .searchable(text: $search, prompt: "搜索会话")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { panel = .settings } label: { Image(systemName: "gear") }.accessibilityLabel("设置") }
                ToolbarItem(placement: .topBarTrailing) { Button(action: createConversation) { Image(systemName: "square.and.pencil") }.accessibilityLabel("新建会话").accessibilityIdentifier("newConversationToolbar") }
            }
            .navigationDestination(for: UUID.self) { id in
                ConversationView(model: model, conversationID: id).id(id)
            }
            .sheet(item: $panel) { item in
                switch item {
                case .settings: SettingsView(model: model)
                }
            }

        }
        .onOpenURL { url in
            if url == URL(string: "phoneagent://home") {
                consumedActivityNavigationID = model.activityNavigation?.id
                path = []; panel = nil
            } else { model.openActivityURL(url) }
        }
        .onChange(of: path) { old, new in
            for id in old where !new.contains(id) { model.discardConversationDraft(id) }
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("--task-pip-probe"),
               ProcessInfo.processInfo.arguments.contains("--background-stream-probe"), let id = sessions.conversations.first?.id {
                path = [id]
            }
        }
        #endif
        .onChange(of: model.activityNavigation, initial: true) { _, _ in
            routeActivityNavigation()
        }
        .alert("实时活动链接", isPresented: Binding(get: { model.activityLinkError != nil }, set: { if !$0 { model.activityLinkError = nil } })) {
            Button("知道了") { model.activityLinkError = nil }
        } message: { Text(model.activityLinkError ?? "") }
        .onChange(of: commands.pendingRoute, initial: true) { _, _ in routePreparedTask() }
        .onChange(of: model.running) { _, _ in routePreparedTask() }
        .onChange(of: model.stopping) { _, _ in routePreparedTask() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { routeActivityNavigation(); routePreparedTask() }
        }
        .onChange(of: panel) { _, value in if value == nil { routePreparedTask() } }
    }
    private var emptyState: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 26) {
                    Image("BrandMark").resizable().scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: .blue.opacity(0.14), radius: 18, y: 8)
                        .accessibilityLabel("随办")
                    VStack(spacing: 10) {
                        Text("把想做的事，交给随办").font(.title2.bold())
                        Text("说出你的目标，一起把事情办好。\n对话和执行进展都会保留在这里。")
                            .font(.subheadline).multilineTextAlignment(.center)
                            .foregroundStyle(.secondary).lineSpacing(4)
                    }
                    Button(action: createConversation) {
                        Label("新建会话", systemImage: "plus")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("newConversation")
                    HStack(spacing: 12) {
                        VStack(spacing: 7) { Image(systemName: "bubble.left"); Text("说出目标") }.frame(maxWidth: .infinity)
                        VStack(spacing: 7) { Image(systemName: "list.bullet"); Text("查看进展") }.frame(maxWidth: .infinity)
                        VStack(spacing: 7) { Image(systemName: "checkmark.circle"); Text("确认结果") }.frame(maxWidth: .infinity)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).padding(.vertical, 40)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
    private func conversationRow(_ session: AgentConversation) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: model.isRunning(in: session.id) ? "bolt.fill" : "bubble.left.and.bubble.right")
                .font(.body.weight(.medium)).foregroundStyle(.blue)
                .frame(width: 42, height: 42)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(session.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.updatedAt, format: .dateTime.month().day())
                        .font(.caption).foregroundStyle(.tertiary).fixedSize()
                }
                Text(session.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if model.isRunning(in: session.id) {
                    Text(session.phase == .awaitingApproval ? "等待确认" : "正在执行")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(session.phase == .awaitingApproval ? Color.orange : Color.blue)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((session.phase == .awaitingApproval ? Color.orange : Color.blue).opacity(0.10), in: Capsule())
                }
            }
        }.padding(.vertical, 6)
    }
    private func routeActivityNavigation() {
        // A completion can arrive while UIKit is still displaying another app.
        // Keep its destination pending until this scene can mount the message UI.
        guard scenePhase == .active, let destination = model.activityNavigation,
              consumedActivityNavigationID != destination.id else { return }
        consumedActivityNavigationID = destination.id
        panel = nil
        path = [destination.route.sessionID]
    }
    private func routePreparedTask() {
        guard scenePhase == .active, panel == nil, let id = commands.pendingRoute,
              path.last != id else { return }
        if case .open(let destination) = try? commands.perform(SessionCommand(.open, sessionID: id, source: .app)) {
            path = [destination]
        }
    }
    private func createConversation() {
        path.append(model.createConversationDraft(mode: .live))
    }
}
