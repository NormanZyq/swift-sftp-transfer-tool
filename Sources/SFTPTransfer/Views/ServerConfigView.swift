import SwiftUI

struct ServerConfigView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: HostEntry.ID?
    @State private var draft = ServerDraft()
    @State private var originalDraft = ServerDraft()
    @State private var tempDraftID: HostEntry.ID?
    @State private var pendingAction: PendingAction?
    @State private var showUnsavedAlert = false
    @State private var statusText: String?
    @State private var statusIsError = false
    @State private var isTesting = false

    private var listEntries: [ServerListEntry] {
        var entries = app.hosts.map(ServerListEntry.host)
        if let tempDraftID {
            entries.append(.draft(id: tempDraftID, draft: draft))
        }
        return entries
    }

    private var selectedHost: HostEntry? {
        guard let selectedID else { return nil }
        return app.hosts.first { $0.id == selectedID }
    }

    private var hasUnsavedChanges: Bool {
        draft.isEditable && draft != originalDraft
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 520)
        .interactiveDismissDisabled(hasUnsavedChanges)
        .alert(L10n.tr("有未保存的服务器配置"), isPresented: $showUnsavedAlert) {
            Button(L10n.tr("保存")) { saveThenRunPendingAction() }
            Button(L10n.tr("不保存"), role: .destructive) { discardThenRunPendingAction() }
            Button(L10n.tr("取消"), role: .cancel) { pendingAction = nil }
        } message: {
            Text(L10n.tr("当前服务器配置尚未保存。要先保存这些更改吗？"))
        }
        .onAppear {
            if selectedID == nil {
                select(app.hosts.first?.id)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(L10n.tr("服务器配置"))
                .font(.headline)
            Spacer()
            Button {
                refreshSSHConfig()
            } label: {
                Label(L10n.tr("从 SSH 配置读取"), systemImage: "arrow.clockwise")
            }
        }
        .padding(14)
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                List {
                    ForEach(listEntries) { entry in
                        ServerListRow(entry: entry, isSelected: selectedID == entry.id)
                            .id(entry.id)
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                            .onTapGesture { requestSelection(entry.id) }
                            .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity.combined(with: .move(edge: .top))
                            ))
                    }
                    .onMove(perform: moveRows)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .controlBackgroundColor))
                .animation(.easeInOut(duration: 0.22), value: listEntries.map(\.id))
                .onChange(of: tempDraftID) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Button {
                    requestBeginAdd()
                } label: {
                    Image(systemName: "plus")
                }
                .help(L10n.tr("添加服务器"))

                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedHost?.isEditable != true)
                .help(L10n.tr("删除手动服务器"))

                Spacer()

                Button {
                    moveSelected(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(selectedID == nil || selectedID == app.hosts.first?.id || selectedID == tempDraftID)
                .help(L10n.tr("上移"))

                Button {
                    moveSelected(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(selectedID == nil || selectedID == app.hosts.last?.id || selectedID == tempDraftID)
                .help(L10n.tr("下移"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: 270)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            if selectedID == nil {
                ContentUnavailableView(L10n.tr("未选择服务器"), systemImage: "server.rack")
            } else {
                sourceHeader
                Form {
                    TextField(L10n.tr("名称"), text: $draft.alias)
                        .disabled(!draft.isEditable)
                    TextField(L10n.tr("地址 / IP"), text: $draft.hostName)
                        .disabled(!draft.isEditable)
                    TextField(L10n.tr("端口"), text: $draft.port)
                        .disabled(!draft.isEditable)
                    TextField(L10n.tr("用户名"), text: $draft.user)
                        .disabled(!draft.isEditable)

                    if draft.isEditable {
                        SecureField(draft.isNew ? L10n.tr("密码") : L10n.tr("密码（留空保持不变）"), text: $draft.password)
                    } else {
                        TextField(L10n.tr("身份文件"), text: $draft.identityFile)
                            .disabled(true)
                    }
                }
                .formStyle(.grouped)

                HStack(spacing: 10) {
                    Button {
                        testDraft()
                    } label: {
                        if isTesting {
                            Label(L10n.tr("测试中…"), systemImage: "hourglass")
                        } else {
                            Label(L10n.tr("测试连接"), systemImage: "bolt.horizontal")
                        }
                    }
                    .disabled(isTesting || !draft.canBuildHost)

                    Spacer()

                    Button(L10n.tr("保存")) {
                        _ = saveDraft()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isEditable || !draft.canBuildHost)
                }

                if let statusText {
                    Label(statusText, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(statusIsError ? .red : .green)
                        .lineLimit(3)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sourceHeader: some View {
        HStack(spacing: 8) {
            Text(draft.isEditable ? (draft.isNew ? L10n.tr("新服务器") : L10n.tr("手动服务器")) : L10n.tr("SSH 配置"))
                .font(.subheadline.weight(.semibold))
            Text(draft.isEditable ? L10n.tr("可编辑，密码保存到钥匙串") : L10n.tr("只读，可通过刷新同步 ~/.ssh/config"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.tr("完成")) { requestClose() }
        }
        .padding(14)
    }

    private func refreshSSHConfig() {
        app.refreshSSHConfigHosts()
        if let selectedID, selectedID != tempDraftID, !app.hosts.contains(where: { $0.id == selectedID }) {
            select(app.hosts.first?.id)
        } else if selectedID != tempDraftID {
            loadSelectedHost()
        }
        showStatus(L10n.tr("已刷新 SSH 配置条目"))
    }

    private func requestSelection(_ id: HostEntry.ID?) {
        guard id != selectedID else { return }
        runOrConfirm(.select(id))
    }

    private func requestBeginAdd() {
        runOrConfirm(.add)
    }

    private func requestClose() {
        runOrConfirm(.close)
    }

    private func runOrConfirm(_ action: PendingAction) {
        if hasUnsavedChanges {
            pendingAction = action
            showUnsavedAlert = true
        } else {
            run(action)
        }
    }

    private func run(_ action: PendingAction) {
        switch action {
        case .select(let id):
            if draft.isNew { removeTemporaryDraft() }
            select(id)
        case .add:
            beginAdd()
        case .close:
            dismiss()
        }
    }

    private func select(_ id: HostEntry.ID?) {
        selectedID = id
        loadSelectedHost()
    }

    private func loadSelectedHost() {
        if draft.isNew, selectedID == tempDraftID { return }
        guard let host = selectedHost else {
            draft = ServerDraft()
            originalDraft = draft
            statusText = nil
            statusIsError = false
            return
        }
        draft = ServerDraft(host: host)
        originalDraft = draft
        statusText = nil
        statusIsError = false
    }

    private func beginAdd() {
        if draft.isNew {
            select(tempDraftID)
            return
        }

        let id = UUID().uuidString
        let newDraft = ServerDraft(
            id: id,
            isNew: true,
            source: .manual,
            alias: "",
            hostName: "",
            user: NSUserName(),
            port: "22",
            identityFile: "",
            password: ""
        )

        withAnimation(.easeInOut(duration: 0.2)) {
            tempDraftID = id
            selectedID = id
            draft = newDraft
            originalDraft = newDraft
            statusText = nil
            statusIsError = false
        }
    }

    private func saveDraft() -> Bool {
        do {
            let host = try draft.makeHost()
            let password = draft.password.isEmpty && !draft.isNew ? nil : draft.password
            try app.saveManualHost(host, password: password)
            withAnimation(.easeInOut(duration: 0.2)) {
                tempDraftID = nil
                selectedID = host.id
            }
            draft = ServerDraft(host: host)
            originalDraft = draft
            showStatus(L10n.tr("已保存服务器"))
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func saveThenRunPendingAction() {
        guard let action = pendingAction else { return }
        if saveDraft() {
            pendingAction = nil
            run(action)
        }
    }

    private func discardThenRunPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        if draft.isNew {
            removeTemporaryDraft()
        }
        run(action)
    }

    private func removeTemporaryDraft() {
        guard tempDraftID != nil else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            tempDraftID = nil
        }
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        app.deleteManualHost(id)
        select(app.hosts.first?.id)
        showStatus(L10n.tr("已删除服务器"))
    }

    private func moveSelected(_ delta: Int) {
        guard let id = selectedID else { return }
        app.moveHost(id, by: delta)
    }

    private func moveRows(from source: IndexSet, to destination: Int) {
        guard tempDraftID == nil || !source.contains(app.hosts.count) else { return }
        app.moveHosts(fromOffsets: source, toOffset: min(destination, app.hosts.count))
    }

    private func testDraft() {
        do {
            let host = try draft.makeHost()
            let password = draft.isEditable && !draft.password.isEmpty ? draft.password : nil
            if draft.isNew && password == nil {
                throw PasswordVaultError.missingPassword
            }
            isTesting = true
            statusText = nil
            Task {
                let result = await app.testConnection(host: host, password: password)
                isTesting = false
                switch result {
                case .success:
                    showStatus(L10n.tr("连接测试成功"))
                case .failure(let error):
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func showStatus(_ text: String, isError: Bool = false) {
        statusText = text
        statusIsError = isError
    }
}

private enum PendingAction {
    case select(HostEntry.ID?)
    case add
    case close
}

private enum ServerListEntry: Identifiable {
    case host(HostEntry)
    case draft(id: HostEntry.ID, draft: ServerDraft)

    var id: HostEntry.ID {
        switch self {
        case .host(let host): return host.id
        case .draft(let id, _): return id
        }
    }

    var source: HostEntry.Source {
        switch self {
        case .host(let host): return host.source
        case .draft: return .manual
        }
    }

    var title: String {
        switch self {
        case .host(let host):
            return host.alias
        case .draft(_, let draft):
            let alias = draft.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            return alias.isEmpty ? L10n.tr("新服务器") : alias
        }
    }

    var subtitle: String {
        switch self {
        case .host(let host):
            return "\(host.user)@\(host.hostName):\(host.port)"
        case .draft(_, let draft):
            let host = draft.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty { return L10n.tr("正在添加，尚未保存") }
            return "\(draft.user)@\(host):\(draft.port)"
        }
    }

    var isDraft: Bool {
        if case .draft = self { return true }
        return false
    }
}

private struct ServerListRow: View {
    let entry: ServerListEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if entry.isDraft {
                Spacer(minLength: 4)
                Text(L10n.tr("未保存"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(borderColor, lineWidth: 0.75)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if entry.isDraft {
            return Color.accentColor.opacity(0.07)
        }
        return Color(nsColor: .textBackgroundColor).opacity(0.72)
    }

    private var borderColor: Color {
        if isSelected { return Color.accentColor.opacity(0.35) }
        if entry.isDraft { return Color.accentColor.opacity(0.2) }
        return Color(nsColor: .separatorColor).opacity(0.18)
    }

    private var iconColor: Color {
        if isSelected || entry.isDraft { return .accentColor }
        return .secondary
    }

    private var symbol: String {
        if entry.isDraft { return "plus.circle" }
        return entry.source == .manual ? "person.crop.circle.badge.key" : "terminal"
    }
}

private struct ServerDraft: Equatable {
    var id: HostEntry.ID?
    var isNew = false
    var source: HostEntry.Source = .manual
    var alias = ""
    var hostName = ""
    var user = NSUserName()
    var port = "22"
    var identityFile = ""
    var password = ""

    init() {}

    init(
        id: HostEntry.ID?,
        isNew: Bool,
        source: HostEntry.Source,
        alias: String,
        hostName: String,
        user: String,
        port: String,
        identityFile: String,
        password: String
    ) {
        self.id = id
        self.isNew = isNew
        self.source = source
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.password = password
    }

    init(host: HostEntry) {
        id = host.id
        isNew = false
        source = host.source
        alias = host.alias
        hostName = host.hostName
        user = host.user
        port = "\(host.port)"
        identityFile = host.identityFile ?? ""
        password = ""
    }

    var isEditable: Bool { source == .manual }

    var canBuildHost: Bool {
        !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && Int(port).map { (1...65535).contains($0) } == true
    }

    func makeHost() throws -> HostEntry {
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlias.isEmpty, !cleanHost.isEmpty, !cleanUser.isEmpty else {
            throw ServerDraftError.invalidRequiredFields
        }
        guard let portNumber = Int(port), (1...65535).contains(portNumber) else {
            throw ServerDraftError.invalidPort
        }
        return HostEntry(
            customID: id,
            alias: cleanAlias,
            hostName: cleanHost,
            user: cleanUser,
            port: portNumber,
            identityFile: isEditable || identityFile.isEmpty ? nil : identityFile,
            source: source,
            authentication: isEditable ? .password : .privateKey
        )
    }
}

private enum ServerDraftError: LocalizedError {
    case invalidRequiredFields
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidRequiredFields:
            return L10n.tr("名称、地址和用户名不能为空")
        case .invalidPort:
            return L10n.tr("端口必须是 1 到 65535 之间的数字")
        }
    }
}
