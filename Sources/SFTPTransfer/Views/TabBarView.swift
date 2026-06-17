import SwiftUI
import AppKit

/// 横向滚动 tab 栏的滚动状态。用 @Observable class（而非一堆 @State）的关键原因：
/// 滚轮事件靠 `NSEvent` 本地监听器处理，其闭包会长期存活——必须捕获引用类型才能读到
/// "实时"的 isHovering / offset，捕获值类型会定格在安装监听器的那一刻。
@MainActor
@Observable
final class TabScrollModel {
    var offsetX: CGFloat = 0          // 内容相对容器的横向位移，<= 0
    var contentWidth: CGFloat = 0     // 所有 tab 的总宽
    var containerWidth: CGFloat = 0   // 可视滚动区宽
    var isHovering = false            // 指针是否在 tab 栏内（决定滚轮是否归我处理）
    var centers: [Int: CGFloat] = [:] // 每个 tab 在内容坐标系里的水平中心，用于自动居中

    /// 可滚动的最大距离；内容比容器窄时为 0（无需滚动）。
    var maxOffset: CGFloat { max(0, contentWidth - containerWidth) }

    var canScroll: Bool { maxOffset > 0.5 }
    /// 左 / 右是否还有被遮住的 tab（用于两端的渐隐提示）。
    var hasLeading: Bool { offsetX < -0.5 }
    var hasTrailing: Bool { canScroll && offsetX > -maxOffset + 0.5 }

    func clamp() { offsetX = min(0, max(-maxOffset, offsetX)) }

    func scrollBy(_ delta: CGFloat) {
        offsetX = min(0, max(-maxOffset, offsetX + delta))
    }

    /// 把第 index 个 tab 滚到可视区中央（够不到则贴边，由 clamp 保证）。
    func center(_ index: Int) {
        guard let c = centers[index], containerWidth > 0 else { return }
        offsetX = min(0, max(-maxOffset, containerWidth / 2 - c))
    }
}

/// 通用 tab 栏：左侧可横向滚动的 tab 行 + 右侧独立固定的 + 区域。
/// 对比度靠"灰底 tab 栏 + 白色活动 tab"实现；滚轮（含鼠标纵向滚轮）映射为横向滚动；
/// 两端用渐隐提示还有未露出的 tab。
///
/// 之所以自己写横向滚动而不用 SwiftUI `ScrollView`：需要鼠标滚轮纵向→横向的映射、两端
/// 渐隐、以及切换 tab 时把活动项滚到中央——这些用系统 ScrollView 都不好做。
///
/// `Drag: Transferable` 泛型支持让调用方决定每个 tab 是否可拖、拖什么。返回 nil 表示
/// 该 tab 不可拖。配合 `dropDestination` 可以实现跨列移动 tab。
struct TabBarView<Item: Identifiable, Title: View, Accessory: View, AddLabel: View, Drag: Transferable>: View {
    let items: [Item]
    @Binding var selectedIndex: Int
    let title: (Item) -> Title
    let accessory: (Item) -> Accessory
    let addLabel: () -> AddLabel
    let onClose: (Int) -> Void
    var onSelect: ((Int) -> Void)? = nil
    /// 返回非 nil 时该 tab 可被拖拽，nil 时不可拖。
    var draggable: ((Item) -> Drag?)? = nil

    @State private var hovered: Int? = nil
    @State private var scroll = TabScrollModel()
    @State private var monitor: Any? = nil

    /// tab 栏背景：旧系统接近 Finder 的浅灰工具栏；macOS 26+ 走更轻的材质感。
    private var barColor: Color {
        if #available(macOS 26.0, *) {
            return Color(nsColor: .windowBackgroundColor).opacity(0.72)
        }
        return Color(nsColor: .windowBackgroundColor)
    }

    var body: some View {
        HStack(spacing: 0) {
            scrollingTabs
                .frame(maxWidth: .infinity, alignment: .leading)
            addSection
        }
        .frame(height: 32)
        .background(tabBarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.42))
                .frame(height: 0.5)
        }
        .onHover { scroll.isHovering = $0 }
        .onAppear { installScrollMonitor() }
        .onDisappear { removeScrollMonitor() }
        .onChange(of: selectedIndex) { _, new in
            withAnimation(.easeInOut(duration: 0.2)) { scroll.center(new) }
        }
    }

    @ViewBuilder
    private var tabBarBackground: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(barColor)
        } else {
            barColor
        }
    }

    // MARK: 可滚动的 tab 行

    private var scrollingTabs: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let chip = TabChip(
                            title: title(item),
                            accessory: accessory(item),
                            isSelected: index == selectedIndex,
                            isHovered: hovered == index,
                            showClose: items.count > 1,
                            onTap: {
                                if let onSelect { onSelect(index) } else { selectedIndex = index }
                            },
                            onClose: items.count > 1 ? { onClose(index) } : nil,
                            onHover: { hovering in
                                hovered = hovering ? index : (hovered == index ? nil : hovered)
                            }
                        )
                        .background(
                            // 记录该 tab 在内容坐标系中的中心，供自动居中使用。
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: TabCentersKey.self,
                                    value: [index: g.frame(in: .named("tabContent")).midX]
                                )
                            }
                        )
                        if let payload = draggable?(item) {
                            chip.draggable(payload)
                        } else {
                            chip
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .coordinateSpace(name: "tabContent")
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { scroll.contentWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in
                                scroll.contentWidth = w; scroll.clamp()
                            }
                    }
                )
                .offset(x: scroll.offsetX)

                edgeFades
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .onAppear { scroll.containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in scroll.containerWidth = w; scroll.clamp() }
            .onPreferenceChange(TabCentersKey.self) { scroll.centers = $0 }
        }
    }

    /// 两端提示"这个方向还有没露出的 tab"：底色渐隐遮住 tab 边缘 + 一个雪佛龙箭头明确指向。
    /// 渐隐加宽、加深（叠到接近不透明），再压一个 chevron，使提示一眼可见而非若隐若现。
    private var edgeFades: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                LinearGradient(colors: [barColor, barColor, barColor.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 34)
                Image(systemName: "chevron.compact.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 3)
            }
            .opacity(scroll.hasLeading ? 1 : 0)

            Spacer(minLength: 0)

            ZStack(alignment: .trailing) {
                LinearGradient(colors: [barColor.opacity(0), barColor, barColor],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 34)
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 3)
            }
            .opacity(scroll.hasTrailing ? 1 : 0)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: scroll.hasLeading)
        .animation(.easeOut(duration: 0.15), value: scroll.hasTrailing)
    }

    // MARK: 独立的 + 区域（与 tab 滚动区互不重叠）

    private var addSection: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.38))
                .frame(width: 0.5, height: 18)
                .padding(.leading, 3)
            addLabel()
                .padding(.horizontal, 6)
        }
        .frame(maxHeight: .infinity)
        .background(tabBarBackground)
    }

    // MARK: 滚轮 → 横向滚动

    /// 用本地 `NSEvent` 监听器把滚轮事件（含鼠标纵向滚轮）转成横向位移。
    /// 仅当指针位于本 tab 栏内、且确实可滚动时才接管并吞掉事件，否则放行给系统。
    private func installScrollMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard scroll.isHovering, scroll.canScroll else { return event }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // 横向手势优先用 dx；纯纵向滚轮则用 dy 驱动横向。
            let primary = abs(dx) >= abs(dy) ? dx : dy
            if primary != 0 { scroll.scrollBy(primary) }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

/// 收集各 tab 在内容坐标系中的水平中心。
private struct TabCentersKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 单个 tab：贴近 Finder 的标签页外观，选中项与下方内容面板相连。
private struct TabChip<Title: View, Accessory: View>: View {
    let title: Title
    let accessory: Accessory
    let isSelected: Bool
    let isHovered: Bool
    let showClose: Bool
    let onTap: () -> Void
    let onClose: (() -> Void)?
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 5) {
            accessory
            title
                .lineLimit(1)
                .truncationMode(.middle)
            if showClose, let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(closeColor)
                        .frame(width: 15, height: 15)
                        .background(
                            Circle().fill(Color.primary.opacity(isHovered ? 0.10 : 0))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isSelected ? 1 : 0)
                .help("关闭")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, showClose ? 5 : 10)
        .padding(.vertical, 5)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .frame(height: 28)
        .background(
            tabShape
                .fill(fillColor)
                .shadow(color: .black.opacity(selectedShadowOpacity),
                        radius: isSelected ? 2.5 : 0,
                        y: isSelected ? 0.8 : 0)
        )
        .overlay(
            tabShape
                .strokeBorder(strokeColor, lineWidth: 0.6)
        )
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color(nsColor: .textBackgroundColor))
                    .frame(height: 1)
            }
        }
        .contentShape(tabShape)
        .onTapGesture(perform: onTap)
        .onHover(perform: onHover)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var tabShape: some InsettableShape {
        UnevenRoundedRectangle(
            topLeadingRadius: 7,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 7,
            style: .continuous
        )
    }

    private var fillColor: Color {
        if isSelected {
            if #available(macOS 26.0, *) {
                return Color(nsColor: .textBackgroundColor).opacity(0.88)
            }
            return Color(nsColor: .textBackgroundColor)
        }
        if isHovered {
            if #available(macOS 26.0, *) {
                return Color.primary.opacity(0.075)
            }
            return Color.primary.opacity(0.055)
        }
        return .clear
    }

    private var strokeColor: Color {
        if isSelected {
            return Color(nsColor: .separatorColor).opacity(0.72)
        }
        if isHovered {
            return Color(nsColor: .separatorColor).opacity(0.32)
        }
        return .clear
    }

    private var selectedShadowOpacity: Double {
        if #available(macOS 26.0, *) { return 0.08 }
        return 0.045
    }

    private var closeColor: Color {
        if isHovered || isSelected { return .secondary }
        return Color.secondary.opacity(0.75)
    }
}

// MARK: - 通用列 tab 栏

/// 统一列 tab 栏：可承载任意混合的本地 / 远程 tab。+ 菜单可同时新建本地 tab 和打开远程连接。
/// 取代了原来的 `LocalTabBarView` / `RemoteTabBarView`。
struct ColumnTabBarView: View {
    @Environment(AppModel.self) private var app
    @Bindable var column: PaneColumnModel
    @State private var duplicateHostPrompt: HostEntry?

    var body: some View {
        let app = app
        // 整个 tab 栏作为 drop 目标：跨列移动 tab 在此处理。
        // 同列 no-op（app.moveTab 内已做检查）。
        TabBarView(
            items: column.tabs,
            selectedIndex: Binding(
                get: { column.selectedIndex },
                set: { column.selectedIndex = $0 }
            ),
            title: { tab in
                Text(tab.title)
                    .font(.system(size: 11.5, weight: tabIndex(tab) == column.selectedIndex ? .semibold : .regular))
            },
            accessory: { tab -> AnyView in
                switch tab {
                case .local:
                    return AnyView(
                        Image(systemName: "folder")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    )
                case .remote(let rtab):
                    return AnyView(
                        Circle()
                            .fill(statusColor(rtab.state))
                            .frame(width: 6, height: 6)
                    )
                }
            },
            addLabel: {
                AddMenuButton(help: "新建标签或打开新连接") {
                    Button("新建本地标签") {
                        app.setFocus(to: column)
                        app.addLocalTab(in: column)
                    }
                    if !app.hosts.isEmpty {
                        Divider()
                        ForEach(app.hosts) { host in
                            Button(host.display) { openOrFocusHost(host) }
                        }
                    } else {
                        Divider()
                        Button("未发现 ~/.ssh/config 中的主机") {}
                            .disabled(true)
                    }
                }
                .popover(item: $duplicateHostPrompt, arrowEdge: .bottom) { host in
                    DuplicateRemoteHostPopover(
                        host: host,
                        onConfirm: { createAndConnect(host) },
                        onJump: { focusFirstInstance(of: host) },
                        onCancel: { duplicateHostPrompt = nil }
                    )
                }
            },
            onClose: { index in
                closeTab(at: index)
            },
            onSelect: { index in
                column.select(index)
                // tab 切换 → 焦点切到本列
                app.setFocus(to: column)
            },
            draggable: { tab in
                TabTransferRef(sourceColumnID: column.id, tabID: tab.id)
            }
        )
        .dropDestination(for: TabTransferRef.self) { refs, _ in
            guard let ref = refs.first else { return false }
            // 来自其它列的 tab 移到本列，同时切焦点
            app.moveTab(fromSourceColumnID: ref.sourceColumnID, tabID: ref.tabID, to: column)
            app.setFocus(to: column)
            return true
        }
    }

    private func tabIndex(_ tab: BrowserTab) -> Int {
        column.tabs.firstIndex(where: { $0.id == tab.id }) ?? -1
    }

    private func closeTab(at index: Int) {
        // 通过 column 自己的 close 方法（其内部会处理 remote tab 的断开）。
        column.close(at: index, minCount: 1)
        // 顶栏 picker 跟随当前列剩余的活跃会话。
        app.setFocus(to: column)
    }

    private func openOrFocusHost(_ host: HostEntry) {
        // 重复检测只看本列：左右两侧可以同时各有一个相同 host 的 tab。
        let existsInThisColumn = column.tabs.contains { tab in
            if case .remote(let rtab) = tab, rtab.host?.id == host.id { return true }
            return false
        }
        if existsInThisColumn {
            duplicateHostPrompt = host
        } else {
            createAndConnect(host)
        }
    }

    private func createAndConnect(_ host: HostEntry) {
        duplicateHostPrompt = nil
        // 新建 + 连接：始终建在本列（用户在哪个列点 +，就建到哪个列）。
        app.setFocus(to: column)
        app.addRemoteTab(host: host, in: column)
        app.connect()
    }

    private func focusFirstInstance(of host: HostEntry) {
        duplicateHostPrompt = nil
        // 在本列内查找匹配项
        for (idx, tab) in column.tabs.enumerated() {
            if case .remote(let rtab) = tab, rtab.host?.id == host.id {
                column.select(idx)
                app.setFocus(to: column)
                return
            }
        }
    }

    private func statusColor(_ s: RemoteTab.ConnectionState) -> Color {
        switch s {
        case .disconnected: return Color.gray.opacity(0.55)
        case .connecting:   return .orange
        case .connected:    return .green
        }
    }
}

private struct DuplicateRemoteHostPopover: View {
    let host: HostEntry
    let onConfirm: () -> Void
    let onJump: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已存在连接会话")
                .font(.headline)
            Text("已经存在这个服务器的连接会话，确定新建吗？")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(host.display)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Button("取消", role: .cancel) { onCancel() }
                Spacer()
                Button("跳转至") { onJump() }
                Button("确定") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - tab 栏内的 + 按钮

/// `+` 按钮的统一外观（本地 / 远程两侧共用，确保完全一致）。
private struct AddGlyph: View {
    let hovered: Bool
	    var body: some View {
	        Image(systemName: "plus")
	            .font(.system(size: 10.5, weight: .semibold))
	            .foregroundStyle(.secondary)
	            .frame(width: 24, height: 22)
	            .background(
	                RoundedRectangle(cornerRadius: 6, style: .continuous)
	                    .fill(addFill)
	            )
	            .overlay(
	                RoundedRectangle(cornerRadius: 6, style: .continuous)
	                    .strokeBorder(Color(nsColor: .separatorColor).opacity(hovered ? 0.28 : 0),
	                                  lineWidth: 0.6)
	            )
	            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
	    }

	    private var addFill: Color {
	        if hovered {
	            if #available(macOS 26.0, *) {
	                return Color.primary.opacity(0.095)
	            }
	            return Color.primary.opacity(0.075)
	        }
	        return .clear
	    }
	}

/// 普通 `+` 按钮（用于本地 tab 栏）。
private struct AddButton: View {
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            AddGlyph(hovered: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// 弹出菜单的 `+` 按钮（用于远程 tab 栏）。外观与 `AddButton` 保持完全一致：
/// 用 `.menuStyle(.borderlessButton)` + `.menuIndicator(.hidden)` + `.fixedSize()` 去掉
/// 系统菜单默认的箭头与额外内边距，使其与普通按钮像素级对齐。
private struct AddMenuButton<MenuContent: View>: View {
    let help: String
    @ViewBuilder let menuContent: () -> MenuContent
    @State private var hovered = false

    var body: some View {
        Menu {
            menuContent()
        } label: {
            AddGlyph(hovered: hovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help(help)
    }
}
