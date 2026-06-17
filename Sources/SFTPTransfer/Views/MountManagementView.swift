import SwiftUI

struct MountManagementView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pendingUnmount: MountRecord?
    @State private var pendingRemount: MountRecord?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 420)
        .onAppear {
            app.mountManager.refreshStatuses()
        }
        .confirmationDialog(
            "取消挂载",
            isPresented: Binding(
                get: { pendingUnmount != nil },
                set: { if !$0 { pendingUnmount = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnmount
        ) { record in
            Button("取消挂载", role: .destructive) {
                pendingUnmount = nil
                Task { await unmount(record) }
            }
            Button("保留", role: .cancel) { pendingUnmount = nil }
        } message: { record in
            Text("将只取消本应用记录的 sshfs 挂载：\n\(record.localPath)\n\n不会删除这个本地目录。")
        }
        .confirmationDialog(
            "重新挂载",
            isPresented: Binding(
                get: { pendingRemount != nil },
                set: { if !$0 { pendingRemount = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemount
        ) { record in
            Button("重新挂载") {
                pendingRemount = nil
                Task { await remount(record) }
            }
            Button("取消", role: .cancel) { pendingRemount = nil }
        } message: { record in
            Text("会再次把远程目录\n\(record.expectedSource)\n挂载到本地空目录：\n\(record.localPath)")
        }
    }

    private var header: some View {
        HStack {
            Text("管理挂载")
                .font(.headline)
            Spacer()
            Button {
                app.mountManager.refreshStatuses()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            Button("完成") { dismiss() }
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if app.mountManager.records.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("还没有通过本应用创建的挂载。")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(app.mountManager.records) { record in
                        MountRecordRow(
                            record: record,
                            isBusy: app.mountManager.busyRecordIDs.contains(record.id),
                            onOpenTerminal: { LocalFileSystem.openInTerminal(record.localPath) },
                            onOpenFinder: { LocalFileSystem.revealInFinder([record.localPath]) },
                            onCopy: { LocalFileSystem.copyPath(record.localPath) },
                            onUnmount: { pendingUnmount = record },
                            onRemount: { pendingRemount = record },
                            onDelete: { app.mountManager.deleteRecord(record) }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("只管理由本应用创建并记录的 sshfs 挂载；不会尝试接管其它系统挂载。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }

    private func unmount(_ record: MountRecord) async {
        do {
            try await app.mountManager.unmount(record)
            app.engine.appendLog("✓ 已取消挂载 \(record.localPath)")
        } catch {
            app.presentError(error)
        }
    }

    private func remount(_ record: MountRecord) async {
        do {
            try await app.mountManager.remount(record)
            app.engine.appendLog("✓ 已重新挂载 \(record.expectedSource) → \(record.localPath)")
        } catch {
            app.presentError(error)
        }
    }
}

private struct MountRecordRow: View {
    let record: MountRecord
    let isBusy: Bool
    let onOpenTerminal: () -> Void
    let onOpenFinder: () -> Void
    let onCopy: () -> Void
    let onUnmount: () -> Void
    let onRemount: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(record.localPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 12)

            if isBusy {
                ProgressView().controlSize(.small)
            }

            actionButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch record.state {
        case .active:
            Button { onOpenTerminal() } label: { Image(systemName: "terminal") }
                .help("在终端打开")
            Button { onOpenFinder() } label: { Image(systemName: "folder") }
                .help("在访达中打开")
            Button { onCopy() } label: { Image(systemName: "doc.on.doc") }
                .help("复制本地路径")
            Button(role: .destructive) { onUnmount() } label: { Image(systemName: "eject") }
                .help("取消挂载")
                .disabled(isBusy)
        case .stale:
            Button { onRemount() } label: { Image(systemName: "arrow.clockwise.circle") }
                .help("重新挂载")
                .disabled(isBusy)
            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                .help("删除记录")
                .disabled(isBusy)
        case .conflict:
            Button { onCopy() } label: { Image(systemName: "doc.on.doc") }
                .help("复制本地路径")
            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                .help("删除记录")
                .disabled(isBusy)
        }
    }

    private var statusText: String {
        switch record.state {
        case .active:
            return "已挂载"
        case .stale:
            return "已失效，可在确认后重新挂载"
        case .conflict:
            return "本地路径当前被其它挂载占用，已禁止取消挂载"
        }
    }

    private var statusIcon: String {
        switch record.state {
        case .active: return "checkmark.circle.fill"
        case .stale: return "exclamationmark.circle"
        case .conflict: return "lock.trianglebadge.exclamationmark"
        }
    }

    private var statusColor: Color {
        switch record.state {
        case .active: return .green
        case .stale: return .orange
        case .conflict: return .red
        }
    }
}
