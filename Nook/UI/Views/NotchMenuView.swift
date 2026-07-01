//
//  NotchMenuView.swift
//  Nook
//
//  Minimal menu matching Dynamic Island aesthetic
//

import ApplicationServices
import Combine
import SwiftUI
import ServiceManagement

// MARK: - Content Height Measurement

private struct MenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - NotchMenuView

struct NotchMenuView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var soundSelector = SoundSelector.shared
    @State private var launchAtLogin: Bool = false
    @State private var didAppear = false
    @State private var isAppearancePickerExpanded = false
    /// Measured content heights for each picker row, populated by
    /// ExpandableSettingsRow's onToggle callback. Used by keyboard
    /// handlers to predict the final height synchronously (same frame
    /// as isExpanded.toggle()), so the panel starts animating at T+0
    /// instead of waiting for the delayed onPreferenceChange fire.
    @State private var screenPickerMeasuredHeight: CGFloat = 0
    @State private var soundPickerMeasuredHeight: CGFloat = 0
    @State private var appearancePickerMeasuredHeight: CGFloat = 0
    @AppStorage(AppSettings.notchAppearanceStyleKey) private var notchAppearanceStyleRaw = NotchAppearanceStyle.adaptiveArtwork.rawValue
    @AppStorage(AppSettings.musicEdgeGlowEnabledKey) private var musicEdgeGlowEnabled = true
    @AppStorage(AppSettings.vibeGlowEnabledKey) private var vibeGlowEnabled = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                // Back button
                MenuRow(
                    icon: "chevron.left",
                    label: "Back",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 0
                ) {
                    viewModel.toggleMenu()
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // Appearance settings
                ScreenPickerRow(
                    screenSelector: screenSelector,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 1,
                    onToggle: { isExpanded, contentHeight in
                        screenPickerMeasuredHeight = contentHeight
                        viewModel.menuContentHeight += isExpanded ? contentHeight : -contentHeight
                    }
                )
                SoundPickerRow(
                    soundSelector: soundSelector,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 2,
                    onToggle: { isExpanded, contentHeight in
                        soundPickerMeasuredHeight = contentHeight
                        viewModel.menuContentHeight += isExpanded ? contentHeight : -contentHeight
                    }
                )

                MenuRow(
                    icon: "terminal",
                    label: "Agents...",
                    trailingIcon: "chevron.right",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 3
                ) {
                    viewModel.pushTo(.agents)
                }

                MenuRow(
                    icon: "gauge.with.dots.needle.33percent",
                    label: "Performance...",
                    trailingIcon: "chevron.right",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 4
                ) {
                    viewModel.pushTo(.performanceSettings)
                }

                MenuRow(
                    icon: "keyboard",
                    label: "Keyboard Shortcuts...",
                    trailingIcon: "chevron.right",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 5
                ) {
                    viewModel.pushTo(.shortcuts)
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // Music settings
                AppearanceStylePickerRow(
                    selectedStyle: selectedAppearanceStyle,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 6,
                    isExpanded: $isAppearancePickerExpanded,
                    onToggle: { isExpanded, contentHeight in
                        appearancePickerMeasuredHeight = contentHeight
                        viewModel.menuContentHeight += isExpanded ? contentHeight : -contentHeight
                    }
                ) { style in
                    setAppearanceStyle(style)
                }

                MenuToggleRow(
                    icon: "music.note",
                    label: "Music Edge Glow",
                    isOn: musicEdgeGlowEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 7
                ) {
                    musicEdgeGlowEnabled.toggle()
                }

                MenuToggleRow(
                    icon: "sparkles",
                    label: "Vibe Glow",
                    isOn: vibeGlowEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 8
                ) {
                    vibeGlowEnabled.toggle()
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // System settings
                MenuToggleRow(
                    icon: "power",
                    label: "Launch at Login",
                    isOn: launchAtLogin,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 9
                ) {
                    do {
                        if launchAtLogin {
                            try SMAppService.mainApp.unregister()
                            launchAtLogin = false
                        } else {
                            try SMAppService.mainApp.register()
                            launchAtLogin = true
                        }
                    } catch {
                        print("Failed to toggle launch at login: \(error)")
                    }
                }

                AccessibilityRow(isEnabled: AXIsProcessTrusted(), primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor, isFocused: viewModel.settingsFocusedIndex == 10)

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                MenuRow(
                    icon: "star",
                    label: "Star on GitHub",
                    trailingLabel: appVersion,
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 11
                ) {
                    if let url = URL(string: "https://github.com/oa1mgo/nook") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                MenuRow(
                    icon: "xmark.circle",
                    label: "Quit",
                    trailingLabel: "⌘Q",
                    isDestructive: true,
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 12
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                GeometryReader { g in
                    Color.clear
                        .preference(key: MenuContentHeightKey.self, value: g.size.height)
                }
            )
        }
        .onPreferenceChange(MenuContentHeightKey.self) { height in
            // The onToggle callback (inside ExpandableSettingsRow.Button) has
            // already started the panel height animation alongside the
            // picker's frame animation (both share the 0.2s easeInOut curve).
            // This preference fires 1+ frames later with intermediate
            // heights during the animation. We update `menuContentHeight` in
            // the same animation transaction so the panel tracks the VStack
            // throughout — keeping the OUTER ScrollView's overflow constant
            // at the 2pt buffer's `-2pt` and the scrollbar hidden.
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.menuContentHeight = height
            }
            // DIAGNOSTIC: log scrollbar visibility state
            let headerHeight = max(24, viewModel.geometry.deviceNotchRect.height)
            let visibleArea = viewModel.openedSize.height - headerHeight - 12
            let overflow = height - visibleArea
            let willScroll = overflow > 0.5
            DebugLog.shared.write("[menu-pref] vstack=\(String(format: "%.1f", height))pt menuHeight=\(String(format: "%.1f", viewModel.menuContentHeight))pt openedSize=\(String(format: "%.1f", viewModel.openedSize.height))pt visibleArea=\(String(format: "%.1f", visibleArea))pt overflow=\(String(format: "%.1f", overflow))pt scrollbar=\(willScroll ? "VISIBLE" : "hidden")")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            didAppear = true
            refreshStates()
        }
        .onChange(of: viewModel.contentType) { _, newValue in
            if newValue == .menu {
                didAppear = true
                refreshStates()
            }
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            performFocusedAction()
        }
    }

    private func performFocusedAction() {
        let i = viewModel.settingsFocusedIndex
        switch i {
        case 0: viewModel.toggleMenu()
        case 1:
            toggleScreenPickerFromKeyboard()
        case 2:
            toggleSoundPickerFromKeyboard()
        case 3: viewModel.pushTo(.agents)
        case 4: viewModel.pushTo(.performanceSettings)
        case 5: viewModel.pushTo(.shortcuts)
        case 6:
            toggleAppearancePickerFromKeyboard()
        case 7: musicEdgeGlowEnabled.toggle()
        case 8: vibeGlowEnabled.toggle()
        case 9:
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.unregister()
                    launchAtLogin = false
                } else {
                    try SMAppService.mainApp.register()
                    launchAtLogin = true
                }
            } catch {
                print("Failed to toggle launch at login: \(error)")
            }
        case 10:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case 11:
            if let url = URL(string: "https://github.com/oa1mgo/nook") {
                NSWorkspace.shared.open(url)
            }
        case 12: NSApplication.shared.terminate(nil)
        default: break
        }
    }

    /// Keyboard-driven picker toggle. Animate BOTH the panel height and
    /// the picker's frame inside the same `withAnimation` block so they
    /// share the 0.2s easeInOut curve and the OUTER ScrollView's
    /// contentView tracks the VStack's contentSize throughout the
    /// transition. With the 2pt `panelContentBuffer`, the overflow
    /// stays at -2pt — no scrollbar flicker in either direction.
    ///
    /// Snapping the panel (disablesAnimations) was tried and rejected:
    /// on collapse, the VStack content animates from `expanded` down to
    /// `collapsed` while contentView stays snapped at the lower value,
    /// so VStack > contentView for the entire 200ms and the scrollbar
    /// gutter flashes the whole time.
    private func toggleScreenPickerFromKeyboard() {
        let newExpanded = !screenSelector.isPickerExpanded
        withAnimation(.easeInOut(duration: 0.2)) {
            screenSelector.isPickerExpanded = newExpanded
            viewModel.menuContentHeight += newExpanded ? screenPickerMeasuredHeight : -screenPickerMeasuredHeight
        }
    }

    private func toggleSoundPickerFromKeyboard() {
        let newExpanded = !soundSelector.isPickerExpanded
        withAnimation(.easeInOut(duration: 0.2)) {
            soundSelector.isPickerExpanded = newExpanded
            viewModel.menuContentHeight += newExpanded ? soundPickerMeasuredHeight : -soundPickerMeasuredHeight
        }
    }

    private func toggleAppearancePickerFromKeyboard() {
        let newExpanded = !isAppearancePickerExpanded
        withAnimation(.easeInOut(duration: 0.2)) {
            isAppearancePickerExpanded = newExpanded
            viewModel.menuContentHeight += newExpanded ? appearancePickerMeasuredHeight : -appearancePickerMeasuredHeight
        }
    }

    private func refreshStates() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        screenSelector.refreshScreens()
        notchAppearanceStyleRaw = AppSettings.notchAppearanceStyle.rawValue
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }

    private var selectedAppearanceStyle: NotchAppearanceStyle {
        (NotchAppearanceStyle(rawValue: notchAppearanceStyleRaw) ?? AppSettings.notchAppearanceStyle)
            .resolvedForCurrentSystem
    }

    private func setAppearanceStyle(_ style: NotchAppearanceStyle) {
        let resolvedStyle = style.resolvedForCurrentSystem
        withAnimation(.easeInOut(duration: 0.2)) {
            AppSettings.notchAppearanceStyle = resolvedStyle
            notchAppearanceStyleRaw = resolvedStyle.rawValue
        }
    }
}

// MARK: - Update Row

struct UpdateRow: View {
    @ObservedObject var updateManager: UpdateManager
    @State private var isHovered = false
    @State private var isSpinning = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    if case .installing = updateManager.state {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                            .foregroundColor(TerminalColors.blue)
                            .rotationEffect(.degrees(isSpinning ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                            .onAppear { isSpinning = true }
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundColor(iconColor)
                    }
                }
                .frame(width: 16)

                // Label
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(labelColor)

                Spacer()

                // Right side: progress or status
                rightContent
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered && isInteractive ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: updateManager.state)
    }

    // MARK: - Right Content

    @ViewBuilder
    private var rightContent: some View {
        switch updateManager.state {
        case .idle:
            Text(appVersion)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(TerminalColors.green)
                Text("Up to date")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .checking, .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)

        case .found(let version, _):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.blue)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.blue)
                    .frame(width: 32, alignment: .trailing)
            }

        case .extracting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.amber)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
                    .frame(width: 32, alignment: .trailing)
            }

        case .readyToInstall(let version):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .error:
            Text("Retry")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Computed Properties

    private var icon: String {
        switch updateManager.state {
        case .idle:
            return "arrow.down.circle"
        case .checking:
            return "arrow.down.circle"
        case .upToDate:
            return "checkmark.circle.fill"
        case .found:
            return "arrow.down.circle.fill"
        case .downloading:
            return "arrow.down.circle"
        case .extracting:
            return "doc.zipper"
        case .readyToInstall:
            return "checkmark.circle.fill"
        case .installing:
            return "gear"
        case .error:
            return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch updateManager.state {
        case .idle:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking:
            return .white.opacity(0.7)
        case .upToDate:
            return TerminalColors.green
        case .found, .readyToInstall:
            return TerminalColors.green
        case .downloading:
            return TerminalColors.blue
        case .extracting:
            return TerminalColors.amber
        case .installing:
            return TerminalColors.blue
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var label: String {
        switch updateManager.state {
        case .idle:
            return "Check for Updates"
        case .checking:
            return "Checking..."
        case .upToDate:
            return "Check for Updates"
        case .found:
            return "Download Update"
        case .downloading:
            return "Downloading..."
        case .extracting:
            return "Extracting..."
        case .readyToInstall:
            return "Install & Relaunch"
        case .installing:
            return "Installing..."
        case .error:
            return "Update failed"
        }
    }

    private var labelColor: Color {
        switch updateManager.state {
        case .idle, .upToDate:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking, .downloading, .extracting, .installing:
            return .white.opacity(0.9)
        case .found, .readyToInstall:
            return TerminalColors.green
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var isInteractive: Bool {
        switch updateManager.state {
        case .idle, .upToDate, .found, .readyToInstall, .error:
            return true
        case .checking, .downloading, .extracting, .installing:
            return false
        }
    }

    // MARK: - Actions

    private func handleTap() {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            updateManager.checkForUpdates()
        case .found:
            updateManager.downloadAndInstall()
        case .readyToInstall:
            updateManager.installAndRelaunch()
        default:
            break
        }
    }
}

// MARK: - Accessibility Permission Row

struct AccessibilityRow: View {
    let isEnabled: Bool
    let primaryTextColor: Color
    let secondaryTextColor: Color
    var isFocused: Bool = false

    @State private var isHovered = false
    @State private var refreshTrigger = false

    private var currentlyEnabled: Bool {
        // Re-check on each render when refreshTrigger changes
        _ = refreshTrigger
        return isEnabled
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)

            Text("Accessibility")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)

            Spacer()

            if isEnabled {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)

                Text("On")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
            } else {
                Button(action: openAccessibilitySettings) {
                    Text("Enable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrigger.toggle()
        }
    }

    private var textColor: Color {
        primaryTextColor.opacity(isHovered ? 1.0 : 0.82)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct MenuRow<Icon: View>: View {
    let icon: String
    /// Optional override for the leading icon. When provided, replaces
    /// the SF Symbol `icon`. Use this when a row needs a brand logo
    /// (e.g. Codex / Cursor / OpenCode marks) instead of an SF Symbol.
    ///
    /// `MenuRow` is generic over `Icon` so the brand logo's concrete
    /// type is preserved end-to-end — no `AnyView` heap allocation, no
    /// SwiftUI view-diffing penalty. The most common call sites don't
    /// pass `customIcon` and use the convenience init in the
    /// `Icon == EmptyView` extension below; they pay nothing for the
    /// extra type parameter.
    var customIcon: Icon? = nil
    let label: String
    var trailingLabel: String? = nil
    /// Design for the trailing label. Defaults to `.default`; pass
    /// `.monospaced` for things like file paths where fixed-width
    /// alignment matters.
    var trailingLabelDesign: Font.Design = .default
    /// When true, trailing label is rendered dimmer than the default
    /// (0.35 vs 0.55 of the text color). Use for secondary status text
    /// like "Not installed" that should recede visually.
    var trailingLabelDimmed: Bool = false
    var trailingIcon: String? = nil
    var isDestructive: Bool = false
    var primaryTextColor: Color = .white
    var isFocused: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    init(
        icon: String,
        customIcon: Icon? = nil,
        label: String,
        trailingLabel: String? = nil,
        trailingLabelDesign: Font.Design = .default,
        trailingLabelDimmed: Bool = false,
        trailingIcon: String? = nil,
        isDestructive: Bool = false,
        primaryTextColor: Color = .white,
        isFocused: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.customIcon = customIcon
        self.label = label
        self.trailingLabel = trailingLabel
        self.trailingLabelDesign = trailingLabelDesign
        self.trailingLabelDimmed = trailingLabelDimmed
        self.trailingIcon = trailingIcon
        self.isDestructive = isDestructive
        self.primaryTextColor = primaryTextColor
        self.isFocused = isFocused
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                iconView

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                if let trailingLabel {
                    Text(trailingLabel)
                        .font(.system(size: 11, design: trailingLabelDesign))
                        .foregroundColor(textColor.opacity(trailingLabelDimmed ? 0.35 : 0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFocused ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var iconView: some View {
        if let customIcon {
            customIcon.frame(width: 16)
        } else {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)
        }
    }

    private var textColor: Color {
        if isDestructive {
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
        return primaryTextColor.opacity(isHovered ? 1.0 : 0.82)
    }
}

/// Convenience init for the common case (no `customIcon`). Pins
/// `Icon` to `EmptyView` so existing call sites don't need to
/// specify the generic parameter — they keep their old argument
/// shape and just get a slightly more efficient `MenuRow` under
/// the hood.
extension MenuRow where Icon == EmptyView {
    init(
        icon: String,
        label: String,
        trailingLabel: String? = nil,
        trailingLabelDesign: Font.Design = .default,
        trailingLabelDimmed: Bool = false,
        trailingIcon: String? = nil,
        isDestructive: Bool = false,
        primaryTextColor: Color = .white,
        isFocused: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            icon: icon,
            customIcon: nil,
            label: label,
            trailingLabel: trailingLabel,
            trailingLabelDesign: trailingLabelDesign,
            trailingLabelDimmed: trailingLabelDimmed,
            trailingIcon: trailingIcon,
            isDestructive: isDestructive,
            primaryTextColor: primaryTextColor,
            isFocused: isFocused,
            action: action
        )
    }
}

struct MenuToggleRow: View {
    let icon: String
    let label: String
    let isOn: Bool
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Circle()
                    .fill(isOn ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(isOn ? "On" : "Off")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFocused ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        primaryTextColor.opacity(isHovered ? 1.0 : 0.82)
    }
}

struct AppearanceStylePickerRow: View {
    let selectedStyle: NotchAppearanceStyle
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    @Binding var isExpanded: Bool
    var onToggle: ((Bool, CGFloat) -> Void)? = nil
    let action: (NotchAppearanceStyle) -> Void

    var body: some View {
        ExpandableSettingsRow(
            icon: "circle.lefthalf.filled",
            label: "Appearance Style",
            trailingText: selectedStyle.displayName,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            isFocused: isFocused,
            isExpanded: $isExpanded,
            onToggle: onToggle
        ) {
            VStack(spacing: 2) {
                ForEach(NotchAppearanceStyle.availableCases) { style in
                    SettingsSubPickerRow(
                        label: style.displayName,
                        sublabel: sublabel(for: style),
                        verticalSublabel: true,
                        isSelected: selectedStyle == style,
                        primaryTextColor: primaryTextColor,
                        secondaryTextColor: secondaryTextColor
                    ) {
                        action(style)
                    }
                }
            }
        }
    }

    private func sublabel(for style: NotchAppearanceStyle) -> String {
        switch style {
        case .liquidGlass:
            return "macOS 26+ glass"
        case .adaptiveArtwork:
            return "Dynamic music colors"
        case .pureBlack:
            return "Solid black"
        }
    }
}
