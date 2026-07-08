//
//  ScreenPickerRow.swift
//  Nook
//
//  Screen selection picker for settings menu
//

import SwiftUI

struct ScreenPickerRow: View {
    @ObservedObject var screenSelector: ScreenSelector
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    var onToggle: ((Bool, CGFloat) -> Void)? = nil

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: { screenSelector.isPickerExpanded },
            set: { screenSelector.isPickerExpanded = $0 }
        )
    }

    /// Compile-time layout for this picker's expanded content.
    /// "Automatic" + one entry per available screen; subRows use
    /// `verticalSublabel: true` (label + sublabel stacked), so
    /// `rowHeight` is 46.91pt (font-metric-derived: 12pt label + 1pt
    /// spacing + 10pt sublabel + 20pt vertical padding).
    static var pickerLayout: PickerLayout {
        PickerLayout(
            rowCount: 1 + ScreenSelector.shared.availableScreens.count,
            rowHeight: settingsSubPickerRowVerticalSublabelHeight
        )
    }

    var body: some View {
        ExpandableSettingsRow(
            icon: "display",
            label: "Screen",
            trailingText: currentSelectionLabel,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            isFocused: isFocused,
            isExpanded: isExpandedBinding,
            targetHeight: Self.pickerLayout.expandedHeight,
            onToggle: onToggle
        ) {
            VStack(spacing: 2) {
                SettingsSubPickerRow(
                    label: "Automatic",
                    sublabel: "Built-in or Main",
                    verticalSublabel: true,
                    isSelected: screenSelector.selectionMode == .automatic,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor
                ) {
                    screenSelector.selectAutomatic()
                    triggerWindowRecreation()
                    collapseAfterDelay()
                }

                ForEach(screenSelector.availableScreens, id: \.self) { screen in
                    SettingsSubPickerRow(
                        label: screen.localizedName,
                        sublabel: screenSublabel(for: screen),
                        verticalSublabel: true,
                        isSelected: screenSelector.selectionMode == .specificScreen &&
                                    screenSelector.isSelected(screen),
                        primaryTextColor: primaryTextColor,
                        secondaryTextColor: secondaryTextColor
                    ) {
                        screenSelector.selectScreen(screen)
                        triggerWindowRecreation()
                        collapseAfterDelay()
                    }
                }
            }
        }
    }

    private var currentSelectionLabel: String {
        switch screenSelector.selectionMode {
        case .automatic:
            return "Auto"
        case .specificScreen:
            if let screen = screenSelector.selectedScreen {
                return screen.localizedName
            }
            return "Auto"
        }
    }

    private func screenSublabel(for screen: NSScreen) -> String? {
        var parts: [String] = []
        if screen.isBuiltinDisplay {
            parts.append("Built-in")
        }
        if screen == NSScreen.main {
            parts.append("Main")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func triggerWindowRecreation() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Collapse with the same animation curve used by the row's
            // own toggle so the panel height and picker frame stay in
            // lock-step. Target height comes from `Self.pickerLayout` —
            // no measurement feedback.
            withAnimation(.easeInOut(duration: 0.2)) {
                screenSelector.isPickerExpanded = false
                onToggle?(false, Self.pickerLayout.expandedHeight)
            }
        }
    }
}
