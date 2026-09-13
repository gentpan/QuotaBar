import SwiftUI
import ServiceManagement
import QuotaCore

// MARK: - Presentation

struct PresentationPane: View {
    @ObservedObject var store: UsageStore
    /// Re-read when a display comes or goes, so the picker lists what is
    /// actually there.
    @State private var screens = NSScreen.screens

    var body: some View {
        SettingsCard(L10n.t("Where the panel lives", "面板位置")) {
            SettingRow(L10n.t("Style", "样式")) {
                GlassSegmented(
                    options: Presentation.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.presentation,
                    onSelect: { store.setPresentation($0) })
                .frame(maxWidth: 320)
            }

            // Only a question on a Mac with more than one display.
            if screens.count > 1 {
                SettingRow(
                    L10n.t("Screen", "屏幕"),
                    caption: L10n.t(
                        "Automatic follows the menu bar's screen; the island, the screen with the notch. Desktop cards go along.",
                        "自动跟随菜单栏所在的屏幕，刘海岛跟随带刘海的屏幕。桌面卡片同屏。"))
                {
                    GlassSegmented(
                        options: ScreenChoice.options,
                        selection: ScreenChoice.selection,
                        onSelect: { store.setDisplayScreen($0) })
                    .frame(maxWidth: 440)
                }
            }

            if store.presentation == .island {
                SettingRow(
                    L10n.t("Per side", "每侧显示"),
                    caption: L10n.t(
                        "How many providers sit either side of the notch, in the order they are enabled. Hover to open the full panel.",
                        "刘海两侧各显示几个服务商，按启用顺序排列。悬停即从顶部展开完整面板。"))
                {
                    GlassSegmented(
                        options: [1, 2, 3].map { (value: $0, label: L10n.t("\($0)", "\($0) 个")) },
                        selection: store.islandSlots,
                        onSelect: { store.setIslandSlots($0) })
                    .frame(maxWidth: 200)
                }
            SettingToggle(
                L10n.t("Glow", "光晕"), caption: L10n.t("A halo that turns amber or red near the limit, and a light that orbits the outline.", "轮廓外的柔光，接近上限时变琥珀或红色，另有一道光沿轮廓环绕。"),
                isOn: Binding(
                    get: { store.experience.islandGlow },
                    set: { value in store.updateExperience { $0.islandGlow = value } }))
            SettingToggle(
                L10n.t("Low power", "低功耗"), caption: L10n.t("Glow only while refreshing, hovered or alerting.", "只在刷新、悬停或告警时发光。"),
                isOn: Binding(
                    get: { store.experience.lowPowerGlow },
                    set: { value in store.updateExperience { $0.lowPowerGlow = value } }))
            .disabled(!store.experience.islandGlow)
            .opacity(!store.experience.islandGlow ? 0.45 : 1)
            SettingToggle(
                L10n.t("Open when a limit nears", "越线时自动弹出"), caption: L10n.t("Opens for four seconds when a window crosses its warning.", "额度第一次超过告警线时展开 4 秒。"),
                isOn: Binding(
                    get: { store.experience.islandAutoPeek },
                    set: { value in store.updateExperience { $0.islandAutoPeek = value } }))
            SettingRow(L10n.t("Chart", "图表样式"), caption: L10n.t("⌘-click the open panel to cycle.", "在展开的面板上按住 ⌘ 点击也能切换。")) {
                GlassSegmented(
                    options: IslandChartStyle.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.experience.islandChart,
                    onSelect: { value in store.updateExperience { $0.islandChart = value } })
                .frame(maxWidth: 380)
            }
            }

            if store.presentation == .edgeDock {
                SettingRow(
                    L10n.t("Docked edge", "停靠边缘"),
                    caption: L10n.t(
                        "Drag the dock up or down to move it; the position is remembered. Click a ring to open the panel for that provider.",
                        "上下拖动可移动停靠条，位置会被记住。点击圆环可打开该服务商的完整面板。"))
                {
                    GlassSegmented(
                        options: DockEdge.allCases.map { (value: $0, label: $0.displayName) },
                        selection: store.dockEdge,
                        onSelect: { store.setDockEdge($0) })
                    .frame(maxWidth: 200)
                }
                SettingToggle(
                    L10n.t("Keep the dock visible", "常驻显示（不自动隐藏）"),
                    isOn: Binding(
                        get: { store.dockAlwaysVisible },
                        set: { store.setDockAlwaysVisible($0) }))
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }

        SettingsCard(
            L10n.t("What each place shows", "各处显示的服务商"),
            help: L10n.t(
                "Hiding a provider only takes it off that place: it is still read, still alerts, and still counts in spend. Turning it off in Providers stops reading it.",
                "隐藏只是不在那里显示：该服务商仍会读取数据、发提醒、计入花费。在「服务商」里停用才会停止读取。"))
        {
            if store.enabled.isEmpty {
                SettingFootnote(L10n.t("No providers are on.", "还没有开启服务商。"))
            } else {
                VStack(spacing: Design.space1) {
                    ForEach(store.enabled) { id in
                        SurfaceVisibilityRow(store: store, id: id)
                    }
                }
            }
        }

        SettingsCard(
            L10n.t("Desktop cards", "桌面卡片"),
            help: L10n.t(
                "Cards sit on the desktop, below your windows, unless kept above. Drag one to move it, double-click for the menu panel, right-click to change its style, size or provider, or to remove it.",
                "卡片默认位于桌面、在窗口之下，可改为置顶。拖动移动位置，双击打开下拉面板，右键可更换样式、尺寸、服务商或删除。"))
        {
            SettingToggle(
                L10n.t("Show on the desktop", "在桌面显示"),
                isOn: Binding(
                    get: { store.widgetEnabled },
                    set: { store.setWidgetEnabled($0) }))
            ForEach(Array(store.experience.deskCards.enumerated()), id: \.element.id) { index, card in
                DeskCardSettingsRow(store: store, card: card, number: index + 1)
                    .disabled(!store.widgetEnabled)
                    .opacity(store.widgetEnabled ? 1 : 0.45)
            }
            SettingRow(L10n.t("Add", "添加")) {
                HStack(spacing: Design.space2) {
                    GlassMenuButton(
                        title: L10n.t("Add a card", "添加卡片"),
                        systemImage: "plus",
                        items: DeskCardStyle.allCases.map { style in
                            (style.displayName, { store.addDeskCard(style: style, near: store.experience.deskCards.last) })
                        })
                    Button(L10n.t("Restore the default pair", "恢复默认两张")) {
                        store.updateExperience { $0.deskCards = DeskCard.defaults(provider: nil) }
                        if !store.widgetEnabled { store.setWidgetEnabled(true) }
                        store.widgetRevision &+= 1
                    }
                    .glassAction()
                    Spacer(minLength: 0)
                }
            }
            SettingToggle(
                L10n.t("Keep above other windows", "置于其他窗口之上"),
                isOn: Binding(
                    get: { store.widgetAlwaysOnTop },
                    set: { store.setWidgetAlwaysOnTop($0) }))
                .disabled(!store.widgetEnabled)
                .opacity(store.widgetEnabled ? 1 : 0.45)
            SettingToggle(
                L10n.t("Classic card: closest to the limit first", "经典样式按紧迫度排序"),
                isOn: Binding(
                    get: { store.experience.widgetSortsByUrgency },
                    set: { value in store.updateExperience { $0.widgetSortsByUrgency = value } }))
        }
    }
}

/// One desktop card in Settings: its style, size and subject, and a way to
/// remove it.
private struct DeskCardSettingsRow: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard
    let number: Int

    var body: some View {
        SettingRow(L10n.t("Card \(number)", "卡片 \(number)")) {
            HStack(spacing: Design.space2) {
                GlassPopUp(
                    options: DeskCardStyle.allCases.map { (value: $0, label: $0.displayName) },
                    selection: card.style,
                    onSelect: { style in store.updateDeskCard(card.id) { $0.style = style } })
                .frame(width: 118)

                GlassSegmented(
                    options: DeskCardSize.allCases.map { (value: $0, label: $0.shortName) },
                    selection: card.size,
                    onSelect: { size in store.updateDeskCard(card.id) { $0.size = size } })
                .frame(width: 120)

                if card.style.readsLogs {
                    GlassPopUp(
                        options: [(value: CostSource?.none, label: L10n.t("Every CLI", "全部来源"))]
                            + CostSource.allCases.map { (value: Optional($0), label: $0.displayName) },
                        selection: card.source,
                        onSelect: { source in store.updateDeskCard(card.id) { $0.source = source } })
                    .frame(width: 128)
                } else {
                    GlassPopUp(
                        options: [(
                            value: ProviderID?.none,
                            label: card.style.singleProvider
                                ? L10n.t("Follow menu bar", "跟随菜单栏")
                                : L10n.t("Every provider", "全部服务商"))]
                            // A card pinned to a provider since switched off
                            // still names it, rather than showing a blank.
                            + (store.enabled + [card.provider].compactMap { $0 }.filter { !store.enabled.contains($0) })
                                .map { (value: Optional($0), label: $0.displayName) },
                        selection: card.provider,
                        onSelect: { provider in store.updateDeskCard(card.id) { $0.provider = provider } })
                    .frame(width: 128)
                }

                Button {
                    store.removeDeskCard(card.id)
                } label: {
                    Image(systemName: "trash")
                }
                .glassAction(compact: true)
                .help(L10n.t("Remove this card", "删除这张卡片"))
                Spacer(minLength: 0)
            }
        }
    }
}

/// One enabled provider and the places it is shown: a chip per surface, lit
/// where it shows, dimmed where it is hidden.
private struct SurfaceVisibilityRow: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    var body: some View {
        HStack(spacing: Design.space2) {
            ProviderGlyph(id: id, size: 16)
                .frame(width: 20)
            Text(id.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: Design.space2)
            ForEach(DisplaySurface.allCases) { surface in
                let shown = !store.experience.isHidden(id, on: surface)
                Button {
                    withAnimation(Motion.animation(.easeOut(duration: 0.15))) {
                        store.setHidden(shown, id, on: surface)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: shown ? "eye" : "eye.slash")
                            .font(.system(size: 10, weight: .medium))
                        Text(surface.displayName)
                            .font(.system(size: 11, weight: shown ? .medium : .regular))
                    }
                    .foregroundStyle(shown ? Design.ink : Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        Capsule().fill(shown ? Design.accent : Design.fieldFill))
                    .overlay(
                        Capsule().strokeBorder(shown ? Color.clear : Design.glassEdge, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(shown
                    ? L10n.t("Shown in \(surface.displayName) — click to hide", "显示在\(surface.displayName) · 点击隐藏")
                    : L10n.t("Hidden from \(surface.displayName) — click to show", "已在\(surface.displayName)隐藏 · 点击显示"))
            }
        }
        .frame(minHeight: 30)
    }
}
