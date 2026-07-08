//
//  ButtonStyles.swift
//  Nook
//
//  Shared ButtonStyle definitions. Centralized so visual button behavior
//  stays consistent across the app — adding a new style here is preferred
//  over inline `.buttonStyle(...)` calls so future fixes only touch one
//  file.
//
//  Why this file exists:
//  ─────────────────────────────────────────────────────────────────────
//  `.buttonStyle(.plain)` does NOT fully suppress the macOS native
//  pressed highlight. On macOS 14+, SwiftUI Button still dispatches
//  `isPressed` to NSButton, which renders a system-level dark overlay
//  during mouse-down — visible as a "flash" when the user clicks a row.
//  This overlay is independent of `.background()` inside the label, so
//  the row's hover background briefly darkens on click before the
//  action fires. See settings rows (`MenuToggleRow` /
//  `ExpandableSettingsRow` / `SettingsSubPickerRow`) for the affected
//  call sites.
//
//  Fix: `NoPressButtonStyle` wraps the label without inspecting
//  `configuration.isPressed`, so the native pressed overlay is never
//  rendered. Hover state is handled by the view's own `.onHover` —
//  which already exists on every settings row — so visual feedback
//  during mouse-down is the same as mouse-hover (no double-darken).
//
//  Apply via `.buttonStyle(NoPressButtonStyle())` instead of
//  `.buttonStyle(.plain)` everywhere a row should not flash on click.
//  ─────────────────────────────────────────────────────────────────────
//

import SwiftUI

/// `ButtonStyle` that renders no visual change on press.
///
/// SwiftUI's `.plain` button style lets the underlying NSButton apply
/// its native pressed highlight (a subtle dark overlay) on mouse-down.
/// For our settings rows, where hover state is already communicated
/// via the view's own `.onHover` + `.background()`, the native pressed
/// overlay appears as a one-frame "double darken" — a click flash.
///
/// `NoPressButtonStyle` ignores `configuration.isPressed` entirely,
/// so the row's appearance stays identical between hover and press.
/// All other Button semantics (keyboard activation, accessibility,
/// focus) are preserved because we still go through the ButtonStyle
/// protocol instead of dropping `Button` for a tap gesture.
struct NoPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}