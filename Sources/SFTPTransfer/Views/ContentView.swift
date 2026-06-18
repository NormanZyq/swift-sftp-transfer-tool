import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var app
    /// 底部「传输状态」栏是否由用户展开（记忆到偏好设置）。
    @AppStorage("transfer.statusExpanded") private var statusExpanded = true
    /// 用户是否已确认"远程中转会经本机临时文件"。
    @AppStorage("transfer.relayAcknowledged") private var relayAcknowledged = false
    /// 结果提醒 toast（自动淡出）。
    @State private var toast: TransferEngine.Outcome?
    @State private var toastDismiss: Task<Void, Never>?
    /// 待处理的传输请求（远程中转未确认时暂存）。
    @State private var pendingRelay: AppModel.TransferSnapshot?
    @State private var pendingMount: MountRequest?
    @State private var missingMountDependency: MountDependencyStatus?
    @State private var mountManagerPresented = false
    /// 折叠明细的自然高度（测量得到），折叠动画在 0 ↔ 该高度之间插值。
    @State private var detailHeight: CGFloat = 0

    /// 实际是否展开：用户展开，或正在传输时强制展开（传输结束自动回到用户设置）。
    private var statusVisible: Bool { statusExpanded || app.engine.isRunning }

    var body: some View {
        @Bindable var app = app
        return VStack(spacing: 8) {
            topBar
            HSplitView {
                paneSide(
                    tabBar: ColumnTabBarView(column: app.leftColumn),
                    pane: app.leftColumn.activePane
                )
                .frame(minWidth: 360)
                paneSide(
                    tabBar: ColumnTabBarView(column: app.rightColumn),
                    pane: app.rightColumn.activePane
                )
                .frame(minWidth: 360)
            }
            .frame(maxHeight: .infinity)
            transferButtons
            statusSection
        }
        .padding(10)
        .animation(.easeInOut(duration: 0.26), value: statusVisible)
        // 结果提醒：底部一角轻量 toast，自动淡出
        .overlay(alignment: .bottomTrailing) {
            if let toast {
                TransferToastView(outcome: toast)
                    .padding(20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onChange(of: app.engine.lastOutcome) { _, outcome in
            guard let outcome else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = outcome }
            toastDismiss?.cancel()
            toastDismiss = Task {
                try? await Task.sleep(for: .seconds(2.6))
                if !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.45)) { toast = nil }
                }
            }
        }
        // 私钥口令
        .sheet(item: $app.passphrasePrompt) { prompt in
            PassphraseSheet(host: prompt.host,
                            onSubmit: { app.submitPassphrase($0) },
                            onCancel: { app.passphrasePrompt = nil })
        }
        // 服务器配置
        .sheet(isPresented: $app.serverConfigPresented) {
            ServerConfigView()
        }
        // 挂载管理
        .sheet(isPresented: $mountManagerPresented) {
            MountManagementView()
        }
        // 挂载依赖缺失提示
        .alert(L10n.tr("无法开启挂载功能"), isPresented: Binding(
            get: { missingMountDependency != nil },
            set: { if !$0 { missingMountDependency = nil } }
        ), presenting: missingMountDependency) { _ in
            Button(L10n.tr("查看安装说明")) {
                openMountDependencyGuide()
                missingMountDependency = nil
            }
            Button(L10n.tr("好"), role: .cancel) { missingMountDependency = nil }
        } message: { dependency in
            Text(L10n.tr("%@\n\n安装说明目前在 README 中预留，后续会补充完整步骤。", dependency.message))
        }
        // 未知主机 TOFU 确认
        .alert(L10n.tr("未知主机"), isPresented: Binding(get: { app.hostKeyPrompt != nil },
                                          set: { if !$0 { app.cancelUnknownHost() } }),
               presenting: app.hostKeyPrompt) { _ in
            Button(L10n.tr("信任并继续")) { app.confirmUnknownHost() }
            Button(L10n.tr("取消"), role: .cancel) { app.cancelUnknownHost() }
        } message: { prompt in
            Text(L10n.tr("主机 %@ 不在 known_hosts 中。\n指纹：%@\n\n确认指纹无误后再信任，信任后会写入 known_hosts。", prompt.info.host, prompt.info.fingerprint))
        }
        // 错误
        .alert(L10n.tr("出错了"), isPresented: Binding(get: { app.errorMessage != nil },
                                          set: { if !$0 { app.errorMessage = nil } })) {
            Button(L10n.tr("好")) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    /// 一侧 = tab 栏 + 文件面板；面板可能为 nil（理论上不会发生，留作安全兜底）。
    @ViewBuilder
    private func paneSide<TabBar: View>(tabBar: TabBar, pane: PaneModel?) -> some View {
        VStack(spacing: 0) {
            tabBar
            if let pane {
                FilePaneView(pane: pane)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: 顶栏

    private var topBar: some View {
        @Bindable var app = app
        return HStack(spacing: 10) {
            // 顶栏的服务器选择下拉框与连接 / 断开按钮跟随焦点会话：
            // 远程会话聚焦时沿用原行为；本地会话聚焦时显示"本地目录"占位，
            // 用户选择服务器后，"连接"会在该本地会话的对侧新建远程会话。
            if app.focusedColumn.activeTab != nil {
                Text(L10n.tr("服务器"))
                Picker("", selection: Binding(
                    get: { app.selectedHostID },
                    set: { app.selectHost($0) }
                )) {
                    Text(app.isFocusedLocalTab ? L10n.tr("本地目录") : L10n.tr("（无）"))
                        .tag(Optional<HostEntry.ID>.none)
                    ForEach(app.hosts) { host in
                        Text(host.display).tag(Optional(host.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)

                Button {
                    app.serverConfigPresented = true
                } label: {
                    Label(L10n.tr("配置服务器"), systemImage: "slider.horizontal.3")
                }
                .help(L10n.tr("配置服务器"))

                if let tab = app.focusedActiveRemoteTab {
                    if tab.state == .connected {
                        Button(L10n.tr("断开")) { app.disconnectFocused() }
                    } else {
                        Button(tab.state == .connecting ? L10n.tr("连接中…") : L10n.tr("连接")) {
                            app.connectFocused()
                        }
                        .disabled(!app.canConnectFocused)
                    }
                    if tab.state == .connecting { ProgressView().controlSize(.small) }
                } else {
                    Button(L10n.tr("连接")) {
                        app.connectFocused()
                    }
                    .disabled(!app.canConnectFocused)
                }
            }

            Spacer()

            // 状态指示也跟随焦点列
            Circle()
                .fill(focusedStatusColor)
                .frame(width: 10, height: 10)
            Text(focusedStatusText)
                .foregroundStyle(.secondary)
        }
    }

    private var focusedStatusColor: Color {
        switch app.focusedActiveRemoteTab?.state {
        case .connected:    return .green
        case .connecting:   return .orange
        case .disconnected: return .gray
        case .none:         return .gray
        }
    }

    private var focusedStatusText: String {
        if let tab = app.focusedActiveRemoteTab {
            return tab.statusText
        }
        return L10n.tr("未连接")
    }

    // MARK: 传输按钮

    private var transferButtons: some View {
        HStack {
            Spacer()
            // "传输到左侧 ←"：把右侧活跃 tab 的选中项传到左侧活跃 tab 的当前目录。
            Button {
                handleTransferClick(direction: .toLeft)
            } label: {
                Label(app.transferToLeftTitle, systemImage: "arrow.left")
            }
            .disabled(!app.canTransferToLeft || app.engine.isRunning)

            // "传输到右侧 →"：把左侧活跃 tab 的选中项传到右侧活跃 tab 的当前目录。
            Button {
                handleTransferClick(direction: .toRight)
            } label: {
                Label(app.transferToRightTitle, systemImage: "arrow.right")
            }
            .disabled(!app.canTransferToRight || app.engine.isRunning)

            Button(role: .cancel) {
                app.cancelTransfer()
            } label: {
                Label(L10n.tr("取消"), systemImage: "xmark.circle")
            }
            .disabled(!app.engine.isRunning)

            Spacer()

            Button {
                beginMount()
            } label: {
                Label(L10n.tr("挂载"), systemImage: app.mountButtonSystemImage)
            }
            .disabled(!app.canMountCurrentPair)
            .help(L10n.tr("将当前远程目录挂载到当前本地空目录"))

            Button {
                openMountManager()
            } label: {
                Label(L10n.tr("管理挂载…"), systemImage: "externaldrive")
            }
        }
        .confirmationDialog(
            L10n.tr("远程中转提示"),
            isPresented: Binding(
                get: { pendingRelay != nil },
                set: { if !$0 { pendingRelay = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("继续")) {
                relayAcknowledged = true
                let snapshot = pendingRelay
                pendingRelay = nil
                if let snapshot { app.performTransferFromSnapshot(snapshot) }
            }
            Button(L10n.tr("取消"), role: .cancel) { pendingRelay = nil }
        } message: {
            Text(L10n.tr("本次传输会在两台远程服务器之间通过本机中转，会在硬盘上产生临时文件。\n\n确认后下次传输将不再询问。"))
        }
        .confirmationDialog(
            L10n.tr("确认挂载"),
            isPresented: Binding(
                get: { pendingMount != nil },
                set: { if !$0 { pendingMount = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingMount
        ) { request in
            Button(L10n.tr("挂载")) {
                pendingMount = nil
                app.performMount(request)
            }
            Button(L10n.tr("取消"), role: .cancel) { pendingMount = nil }
        } message: { request in
            Text(L10n.tr("将把远程目录\n%@\n挂载到本地空目录：\n%@\n\n不会删除、移动或覆盖本地目录。若目录不为空或已经是挂载点，操作会被拒绝。", request.expectedSource, request.localPath))
        }
    }

    private enum TransferDirection { case toLeft, toRight }

    /// 处理传输按钮点击：远程中转 + 未确认过 → 弹确认；其余直接执行。
    private func handleTransferClick(direction: TransferDirection) {
        let isRelay: Bool
        let from: PaneColumnModel
        let to: PaneColumnModel
        switch direction {
        case .toLeft:
            isRelay = app.isTransferToLeftRemoteRelay
            from = app.rightColumn
            to = app.leftColumn
        case .toRight:
            isRelay = app.isTransferToRightRemoteRelay
            from = app.leftColumn
            to = app.rightColumn
        }
        if isRelay, !relayAcknowledged {
            if let snapshot = app.makeTransferSnapshot(from: from, to: to) {
                pendingRelay = snapshot
            }
        } else {
            switch direction {
            case .toLeft: app.transferToLeft()
            case .toRight: app.transferToRight()
            }
        }
    }

    private func beginMount() {
        guard ensureMountDependenciesAvailable() else { return }
        do {
            pendingMount = try app.makeMountRequestForCurrentPair()
        } catch {
            app.presentError(error)
        }
    }

    private func openMountManager() {
        guard ensureMountDependenciesAvailable() else { return }
        app.mountManager.refreshStatuses()
        mountManagerPresented = true
    }

    private func ensureMountDependenciesAvailable() -> Bool {
        let status = app.mountManager.dependencyStatus
        guard status == .ready else {
            missingMountDependency = status
            return false
        }
        return true
    }

    private func openMountDependencyGuide() {
        guard let url = URL(string: "https://github.com/NormanZyq/swift-transfer-tool#%E6%8C%82%E8%BD%BD%E4%BE%9D%E8%B5%96%E5%AE%89%E8%A3%85wip") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: 传输状态栏

    private var statusSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                statusHeader
                statusDetail
                    .padding(.top, 6)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: DetailHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    )
                    .frame(height: statusVisible ? detailHeight : 0, alignment: .top)
                    .clipped()
                    .opacity(statusVisible ? 1 : 0)
                    .allowsHitTesting(statusVisible)
            }
            .padding(4)
        }
        .onPreferenceChange(DetailHeightKey.self) { detailHeight = $0 }
    }

    private var statusHeader: some View {
        HStack(spacing: 6) {
            Button {
                statusExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(statusVisible ? 90 : 0))
                    Text(L10n.tr("传输状态")).font(.subheadline.weight(.semibold))
                    if !statusVisible && app.engine.queueTotal > 0 {
                        Text(L10n.tr("· 上次 %d/%d", app.engine.queueIndex, app.engine.queueTotal))
                            .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(statusExpanded ? L10n.tr("收起（传输时会自动展开）") : L10n.tr("展开"))
            Spacer()
        }
    }

    private var statusDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(app.engine.isRunning ? app.engine.currentName : L10n.tr("等待传输…"))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                if app.engine.queueTotal > 0 {
                    Text(L10n.tr("总进度 %d / %d", app.engine.queueIndex, app.engine.queueTotal))
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progressFraction)
            HStack(spacing: 12) {
                if app.engine.isRunning, app.engine.bytesPerSecond > 0 {
                    Text("\(formatSpeed(app.engine.bytesPerSecond))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if app.engine.isRunning, app.engine.etaSeconds > 0 {
                    Text(L10n.tr("剩余 %@", formatEta(app.engine.etaSeconds)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.caption)
            logView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressFraction: Double {
        let total = app.engine.currentTotal
        guard total > 0 else { return 0 }
        return min(1, Double(app.engine.currentBytes) / Double(total))
    }

    private func formatSpeed(_ bps: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bps
        var i = 0
        while value >= 1024, i < units.count - 1 {
            value /= 1024
            i += 1
        }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", value, units[i])
    }

    private func formatEta(_ seconds: Int) -> String {
        if seconds < 60 { return L10n.tr("%d 秒", seconds) }
        let m = seconds / 60
        let s = seconds % 60
        if m < 60 { return L10n.tr("%d 分 %d 秒", m, s) }
        let h = m / 60
        let mm = m % 60
        return L10n.tr("%d 小时 %d 分", h, mm)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(app.engine.log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
            }
            .frame(height: 110)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onChange(of: app.engine.log.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}

/// 测量「传输状态」明细的自然高度，供折叠动画在 0 ↔ 自然高度间插值。
private struct DetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 私钥口令输入弹窗。
struct PassphraseSheet: View {
    let host: HostEntry
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var passphrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("私钥需要口令"))
                .font(.headline)
            Text(L10n.tr("%@ 使用的私钥带有口令，请输入以解锁（口令只用于本地解密，不会保存）。", host.alias))
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField(L10n.tr("私钥口令"), text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(passphrase) }
            HStack {
                Spacer()
                Button(L10n.tr("取消"), role: .cancel) { onCancel() }
                Button(L10n.tr("解锁并连接")) { onSubmit(passphrase) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// 传输结果的轻量提醒：半透明胶囊 + 图标，底部一角淡入、数秒后自动淡出。
struct TransferToastView: View {
    let outcome: TransferEngine.Outcome

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(outcome.message)
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    private var symbol: String {
        switch outcome.kind {
        case .success:   return "checkmark.circle.fill"
        case .failure:   return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    private var tint: Color {
        switch outcome.kind {
        case .success:   return .green
        case .failure:   return .red
        case .cancelled: return .secondary
        }
    }
}
