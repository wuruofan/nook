//
//  PanelAnimationContract.swift
//  Nook
//
//  Single source of truth for every `.animation(_, value:)` modifier that
//  drives the notch panel. If a new piece of panel state needs an implicit
//  transition, the value goes into `PanelAnimationInputs` and the modifier
//  call goes into `panelAnimationContract(...)` — nowhere else.
//
//  ─────────────────────────────────────────────────────────────────────
//  ⚠️  DO NOT ADD `.animation(_, value:)` MODIFIERS ELSEWHERE  ⚠️
//  ─────────────────────────────────────────────────────────────────────
//
//  SwiftUI's `.animation(_, value:)` is a *view-tree global*. Once
//  attached to the panel root, ANY sibling-state change inside the same
//  transition window is forced onto that modifier's curve. Ad-hoc
//  `.animation(...)` calls elsewhere on the panel have historically
//  caused scrollbar flicker regressions (see below). Centralize here.
//
//  ─── Panel height: curve-matching requirement ──────────────────────
//
//  `notchSize` MUST use `.settingsExpand` (0.2s easeInOut) to stay in
//  sync with `ExpandableContent`'s picker frame animation. The picker
//  frame animates over 0.2s; if the panel animates with a DIFFERENT
//  curve (e.g. `.smooth`, a spring) the two animations drift apart
//  during the transition and the ScrollView briefly detects overflow
//  → scrollbar flicker.
//
//  Removing the panel animation entirely (panel height jumps instantly)
//  was tried and rejected: the visual "snap" on expand feels abrupt,
//  and during collapse the picker's still-animating frame creates a
//  brief overflow window that still produces scrollbar flicker.
//
//  How the chain works:
//    1. User toggles picker → `isExpanded` changes.
//    2. `ExpandableContent` animates `.frame(height:)` with `.settingsExpand`.
//    3. `GeometryReader` on the outer VStack measures new target height.
//    4. `onPreferenceChange(MenuContentHeightKey.self)` fires → updates
//       `viewModel.menuContentHeight`.
//    5. `viewModel.openedSize.height` recomputes from `menuContentHeight`.
//    6. `notchSize.height` (== `openedSize.height`) changes → panel's
//       `.animation(.settingsExpand, value: notchSize)` animates panel
//       height to new target over 0.2s, matching the picker's curve.
//
//  Steps 3-5 are async (onPreferenceChange fires after layout), so the
//  panel animation starts 1-2 frames after the picker animation. For
//  expand, this briefly puts content > panel (scrollbar could flash).
//  For collapse, panel > content throughout (no scrollbar).
//
//  History (see `docs/debug/2026-06-30-appearance-style-scrollbar-regression.md`):
//
//    - 2026-06-22 (`04756a8`): First scrollbar flash. Panel used
//      `openAnimation` (spring 0.45s) for `notchSize`, while picker
//      frames used `.settingsExpand` (0.2s easeInOut). Curve mismatch
//      caused the original flicker. Fix: switch panel to `.settingsExpand`.
//
//    - 2026-06-30 (Release 1.3.1 / `01420a1`): Added
//      `.animation(.smooth, value: notchAppearanceStyleRaw)` directly
//      on the panel. AppStorage default → UserDefaults transition
//      could fire in the same frame as `notchSize` changes (menu open),
//      pulling the panel onto `.smooth` curve. Re-introduced flicker.
//      Fix: centralized all panel animations here, changed
//      `notchAppearanceStyleRaw` from `.smooth` to `.settingsExpand`.
//
//    - 2026-06-30 (rejected approach): Tried removing `.animation(_,
//      value: notchSize)` entirely (panel jumps instantly). Rejected:
//      expand feels abrupt ("panel 瞬间增大的效果不好"), and collapse
//      still flickers because the picker's still-animating frame
//      overflows the instantly-jumped panel.
//
//  How to add a new state-driven animation (READ BEFORE EDITING):
//
//    1. Add the value to `PanelAnimationInputs` below.
//
//    2. Add a matching `.animation(_, value: ...)` call inside
//       `panelAnimationContract(...)`, keeping entries in the same
//       order as the struct fields.
//
//    3. `notchSize` MUST use `.settingsExpand` — it drives the panel
//       height, which must stay in sync with the picker frame animation.
//
//    4. For other values, pick the curve by answering these:
//
//         (a) Does this value transition in the same frame as
//             `status`? → Use `openAnimation` / `closeAnimation`.
//
//         (b) Does this value drive a visual crossfade / fade-in?
//             → `.settingsExpand` (0.2s easeInOut) for clean feel.
//
//         (c) Does it drive a one-shot elastic effect (bounce)?
//             → `.spring(...)` with explicit response/damping.
//
//         (d) Otherwise: `.smooth` for general visual transitions
//             (icons fading, glow toggling). `.smooth(duration:)`
//             when you need a longer fade (e.g. artwork swap).
//
//    5. In the commit message, link
//       `docs/debug/2026-06-30-appearance-style-scrollbar-regression.md`
//       so future readers can see the lineage.
//
//  ─────────────────────────────────────────────────────────────────────
//

import SwiftUI

/// Every animation-driving value used by the notch panel.
///
/// Adding a new field forces every call site of `panelAnimationContract(...)`
/// to update — which is intentional. The struct + modifier together form
/// the contract; you can't add a panel animation without touching both.
struct PanelAnimationInputs: Equatable {
    /// Panel's computed size (width / height).
    ///
    /// **MUST use `.settingsExpand`** — see file header. Drives the panel
    /// height animation, which must stay in lock-step with the picker
    /// frame animation in `ExpandableContent`. Any other curve (or no
    /// animation at all) causes the panel to drift from the picker's
    /// visual frame, creating a ScrollView overflow window → scrollbar
    /// flicker.
    var notchSize: CGSize

    /// Notch open/close state. Uses spring on status transition.
    var status: NotchStatus

    /// Multi-agent icon carousel state (which agent is at the front,
    /// whether the carousel is visible). Drives activity badge UI.
    var expandingActivity: ExpandingActivity

    /// True while a tool permission prompt is showing.
    var hasPendingPermission: Bool

    /// True while waiting for the user to answer AskUserQuestion.
    var hasWaitingForInput: Bool

    /// True while the music player card is visible.
    var showMusicActivity: Bool

    /// Vibe glow toggle. Drives panel edge glow effect.
    var vibeGlowEnabled: Bool

    /// Notch appearance style raw value (UserDefaults via AppStorage).
    ///
    /// Drives the background crossfade (`notchBackground` switch on
    /// `notchAppearanceStyle`). Animated at `.settingsExpand` for a
    /// clean 0.2s feel — no longer coupled to panel height animation
    /// (since 2026-06-30 Step B, panel height snaps instantly).
    var notchAppearanceStyleRaw: String

    /// Current track's artwork bytes. `nil` when no track is loaded.
    /// `.smooth(duration: 0.45)` is intentional — matches the crossfade
    /// feel of artwork swaps and does not transition with `notchSize`.
    var artworkData: Data?

    /// Carousel bounce state (one-shot spring on agent switch).
    /// `.spring(response: 0.3, dampingFraction: 0.5)` — pure visual.
    var isBouncing: Bool
}

extension View {
    /// Apply every panel state-driven `.animation(_, value:)` modifier.
    ///
    /// This is the **only** place on the notch panel where implicit
    /// state-change animations are attached. Do not inline new
    /// `.animation(_, value:)` modifiers on the panel — extend
    /// `PanelAnimationInputs` and add a call here instead.
    ///
    /// - Parameters:
    ///   - inputs: All state values driving panel animations.
    ///   - openAnimation: Spring used for `status` transitioning to `.opened`.
    ///   - closeAnimation: Spring used for `status` transitioning out of `.opened`.
    func panelAnimationContract(
        inputs: PanelAnimationInputs,
        openAnimation: Animation,
        closeAnimation: Animation
    ) -> some View {
        self
            // ─── Panel size — MUST use `.settingsExpand` ────────────
            //
            // The ScrollView outside the menu uses the **visual** size
            // of the picker frame (not the logical/target size) for
            // its contentSize. So the picker's frame *visually* animates
            // 0 → contentHeight (or contentHeight → 0) over 0.2s, and
            // the ScrollView's contentSize tracks that visual value
            // over the same 0.2s window.
            //
            // If the panel animates with a DIFFERENT curve (or jumps
            // instantly), the ScrollView's contentSize and the panel's
            // height drift apart — and during `collapse` you briefly
            // get `panel < content` (scrollbar appears for ~100ms,
            // then hides when the animation finishes). During `expand`
            // the asymmetry is the other way (visual contentSize starts
            // small because the picker visual frame starts at 0, so
            // `panel > content` throughout — no scrollbar) — but
            // matching the curve keeps both directions flicker-free.
            //
            // **Curve MUST stay `.settingsExpand`** — it must match the
            // curve used by `ExpandableContent`'s `.animation(_, value:
            // isExpanded)`. Any other curve (e.g. `.smooth`, a spring,
            // a custom animation) breaks the sync and reintroduces the
            // flicker.
            .animation(.settingsExpand, value: inputs.notchSize)

            // ─── Status (open/close — separate physics) ─────────────
            .animation(
                inputs.status == .opened ? openAnimation : closeAnimation,
                value: inputs.status
            )

            // ─── Activity badges (visual, no height impact) ──────────
            .animation(.smooth, value: inputs.expandingActivity)
            .animation(.smooth, value: inputs.hasPendingPermission)
            .animation(.smooth, value: inputs.hasWaitingForInput)
            .animation(.smooth, value: inputs.showMusicActivity)
            .animation(.smooth, value: inputs.vibeGlowEnabled)

            // ─── Appearance style (background transition only) ───────
            // When `notchAppearanceStyleRaw` changes (user picks a
            // different style), the background view tree changes
            // (`notchBackground` switch on `notchAppearanceStyle`).
            // 0.2s easeInOut for a clean crossfade feel. No relation
            // to panel height anymore.
            .animation(.settingsExpand, value: inputs.notchAppearanceStyleRaw)

            // ─── Music artwork (visual crossfade, no height impact) ─
            .animation(.smooth(duration: 0.45), value: inputs.artworkData)

            // ─── Carousel bounce (pure spring, no height impact) ─────
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: inputs.isBouncing)
    }
}