import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    /// 底部「传输状态」栏是否由用户展开（记忆到偏好设置）。
    @AppStorage("transfer.statusExpanded") private var statusExpanded = true
    /// 结果提醒 toast（自动淡出）。
    @State private var toast: TransferEngine.Outcome?
    @State private var toastDismiss: Task<Void, Never>?

    /// 实际是否展开：用户展开，或正在传输时强制展开（传输结束自动回到用户设置）。
    private var statusVisible: Bool { statusExpanded || app.engine.isRunning }

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 8) {
            topBar
            HSplitView {
                FilePaneView(pane: app.local)
                    .frame(minWidth: 360)
                FilePaneView(pane: app.remote)
                    .frame(minWidth: 360)
            }
            .frame(maxHeight: .infinity)
            transferButtons
            statusSection
        }
        .padding(10)
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

    private var topBar: some View {
        @Bindable var app = app
        return HStack(spacing: 10) {
            Text("服务器")
            Picker("", selection: $app.selectedHostID) {
                ForEach(app.hosts) { host in
                    Text(host.display).tag(Optional(host.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360)
            .disabled(app.state != .disconnected)

            if app.state == .connected {
                Button("断开") { app.disconnect() }
            } else {
                Button("连接") { app.connect() }
                    .disabled(app.selectedHost == nil || app.state == .connecting)
            }

            if app.state == .connecting { ProgressView().controlSize(.small) }

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(app.statusText)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch app.state {
        case .disconnected: return .gray
        case .connecting:   return .orange
        case .connected:    return .green
        }
    }

    private var transferButtons: some View {
        HStack {
            Spacer()
            Button {
                app.uploadSelection()
            } label: {
                Label("上传选中", systemImage: "arrow.right")
            }
            .disabled(!app.isConnected || app.engine.isRunning || app.local.selection.isEmpty)

            Button {
                app.downloadSelection()
            } label: {
                Label("下载选中", systemImage: "arrow.left")
            }
            .disabled(!app.isConnected || app.engine.isRunning || app.remote.selection.isEmpty)

            Button(role: .cancel) {
                app.cancelTransfer()
            } label: {
                Label("取消", systemImage: "xmark.circle")
            }
            .disabled(!app.engine.isRunning)
            Spacer()
        }
    }

    private var statusSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        statusExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: statusVisible ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
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

                if statusVisible {
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
            }
            .padding(4)
            .animation(.easeInOut(duration: 0.2), value: statusVisible)
        }
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
