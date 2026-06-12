import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    /// 底部「传输状态」栏是否由用户展开（记忆到偏好设置）。
    @AppStorage("transfer.statusExpanded") private var statusExpanded = true
    /// 结果提醒 toast（自动淡出）。
    @State private var toast: TransferEngine.Outcome?
    @State private var toastDismiss: Task<Void, Never>?
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
                    tabBar: LocalTabBarView(),
                    pane: app.activeLocalPane
                )
                .frame(minWidth: 360)
                paneSide(
                    tabBar: RemoteTabBarView(),
                    pane: app.activeRemoteTab?.pane
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
        // 未知主机 TOFU 确认
        .alert("未知主机", isPresented: Binding(get: { app.hostKeyPrompt != nil },
                                          set: { if !$0 { app.cancelUnknownHost() } }),
               presenting: app.hostKeyPrompt) { _ in
            Button("信任并继续") { app.confirmUnknownHost() }
            Button("取消", role: .cancel) { app.cancelUnknownHost() }
        } message: { prompt in
            Text("主机 \(prompt.info.host) 不在 known_hosts 中。\n指纹：\(prompt.info.fingerprint)\n\n确认指纹无误后再信任，信任后会写入 known_hosts。")
        }
        // 错误
        .alert("出错了", isPresented: Binding(get: { app.errorMessage != nil },
                                          set: { if !$0 { app.errorMessage = nil } })) {
            Button("好") {}
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
            Text("服务器")
            Picker("", selection: Binding(
                get: { app.selectedHostID },
                set: { app.selectHost($0) }
            )) {
                Text("（无）").tag(Optional<HostEntry.ID>.none)
                ForEach(app.hosts) { host in
                    Text(host.display).tag(Optional(host.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360)

            Button {
                app.serverConfigPresented = true
            } label: {
                Label("配置服务器", systemImage: "slider.horizontal.3")
            }
            .help("配置服务器")

            if let tab = app.activeRemoteTab, tab.state == .connected {
                Button("断开") { app.disconnect() }
            } else {
                Button(app.activeRemoteTab?.state == .connecting ? "连接中…" : "连接") {
                    app.connect()
                }
                .disabled(!app.canConnect)
            }
            if app.activeRemoteTab?.state == .connecting { ProgressView().controlSize(.small) }

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(app.activeRemoteTab?.statusText ?? "未连接")
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch app.activeRemoteTab?.state {
        case .connected:    return .green
        case .connecting:   return .orange
        case .disconnected: return .gray
        case .none:         return .gray
        }
    }

    // MARK: 传输按钮

    private var transferButtons: some View {
        HStack {
            Spacer()
            Button {
                app.uploadSelection()
            } label: {
                Label("上传选中", systemImage: "arrow.right")
            }
            .disabled(!app.isActiveRemoteTabConnected
                      || app.engine.isRunning
                      || (app.activeLocalPane?.selection.isEmpty ?? true))

            Button {
                app.downloadSelection()
            } label: {
                Label("下载选中", systemImage: "arrow.left")
            }
            .disabled(!app.isActiveRemoteTabConnected
                      || app.engine.isRunning
                      || (app.activeRemoteTab?.pane.selection.isEmpty ?? true))

            Button(role: .cancel) {
                app.cancelTransfer()
            } label: {
                Label("取消", systemImage: "xmark.circle")
            }
            .disabled(!app.engine.isRunning)
            Spacer()
        }
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
                    Text("传输状态").font(.subheadline.weight(.semibold))
                    if !statusVisible && app.engine.queueTotal > 0 {
                        Text("· 上次 \(app.engine.queueIndex)/\(app.engine.queueTotal)")
                            .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(statusExpanded ? "收起（传输时会自动展开）" : "展开")
            Spacer()
        }
    }

    private var statusDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(app.engine.isRunning ? app.engine.currentName : "等待传输…")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                if app.engine.queueTotal > 0 {
                    Text("总进度 \(app.engine.queueIndex) / \(app.engine.queueTotal)")
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progressFraction)
            logView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressFraction: Double {
        let total = app.engine.currentTotal
        guard total > 0 else { return 0 }
        return min(1, Double(app.engine.currentBytes) / Double(total))
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
            Text("私钥需要口令")
                .font(.headline)
            Text("\(host.alias) 使用的私钥带有口令，请输入以解锁（口令只用于本地解密，不会保存）。")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("私钥口令", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(passphrase) }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                Button("解锁并连接") { onSubmit(passphrase) }
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
