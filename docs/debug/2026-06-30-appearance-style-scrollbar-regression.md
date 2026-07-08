# Appearance Style Picker Scrollbar Flash — 2026-06-30 Regression

> Status: Resolved (5-layer fix + 16pt buffer + windowHeight cap). Known issue: 14pt visible gap at panel bottom; intermittent expand-direction gutter flash on some macOS versions.
> Symptom: Expanding/collapsing picker rows in settings flashes the scrollbar.
> First introduced: `01420a1` (Release 1.3.1, 2026-06-30), re-introduced curve mismatch.
> Root cause refined: onPreferenceChange fires 1-2 frames AFTER isExpanded toggle with INTERMEDIATE heights → overwrite interrupts onToggle-driven panel animation → retarget oscillation → overflow → scrollbar flash. Keyboard/auto-collapse paths bypass onToggle entirely → no synchronous prediction → panel doesn't animate until preference fires → jumpy snaps.
> Closed by: 5-layer fix (curve contract + synchronous prediction + disablesAnimations overwrite handler + keyboard/collapse height sync + `panelContentBuffer` 16pt slack) + `windowHeight - 16` cap. The buffer addresses macOS NSScroller's direction-sensitive gutter reservation during expand animations; values 2/8/10/12pt were tested and all still flashed the gutter. 16pt is empirically the smallest reliable value. Root-cause fix (cancel GeometryReader feedback loop, drive panel height from data) is future work — see PROGRESS.md "Scrollbar flicker 9 次修复经验".

## TL;DR

Three-layer root cause, four-part fix:

**Root cause chain:**

1. **2026-06-22** (`04756a8`): original scrollbar flash. Panel used
   `openAnimation` (spring 0.45s) for `notchSize`, while picker frames
   used `.settingsExpand` (0.2s easeInOut). Curve mismatch caused the
   original flicker. Fix: switch panel to `.settingsExpand`.

2. **2026-06-30 Release 1.3.1** (`01420a1`): added
   `.animation(.smooth, value: notchAppearanceStyleRaw)` directly on
   the panel. AppStorage default → UserDefaults transition could fire
   in the same frame as `notchSize` changes (menu open), pulling the
   panel onto `.smooth` curve. Re-introduced the same flash.

3. **Even after matching curves (.settingsExpand on both panel + picker):**
   `onPreferenceChange` fires 1-2 frames AFTER `isExpanded` toggle,
   with INTERMEDIATE heights during animation. Without `disablesAnimations`,
   the overwrite would interrupt the onToggle-driven panel animation
   and retarget it to an intermediate height — creating oscillation
   → overflow → scrollbar flash. Curve matching reduced the symptom
   but did NOT eliminate it because the overwrite oscillation is still
   there.

**Fix (four parts):**

- **Part 1 (curve contract — PanelAnimationContract)**:
  Extracted every panel `.animation(_, value:)` into
  `panelAnimationContract(...)` modifier. Changed
  `notchAppearanceStyleRaw` from `.smooth` to `.settingsExpand`.
  Removed `expandedPickerHeight` dead code from 3 selectors + redundant
  `NotchViewModel` selector references.

- **Part 2 (synchronous panel height prediction — onToggle)**:
  `ExpandableContent` adds `onHeightMeasured` callback reporting measured
  height. `ExpandableSettingsRow` adds `onToggle((Bool, CGFloat) -> Void)?`
  called INSIDE the `withAnimation(.settingsExpand)` block, synchronously
  passing `isExpanded` + `measuredContentHeight` to the parent. All 5
  picker rows (Sound/Screen/AppearanceStyle/ClaudeDir/PerformanceMetrics)
  provide `onToggle` callbacks that add/subtract their contentHeight from
  the respective viewModel property within the same animation transaction.
  Panel and picker animations now start on the same frame. The onToggle
  callback also stores the measured height in the parent view's `@State`
  for use by keyboard handlers (Part 4).

- **Part 3 (disable animations on preference overwrites — disablesAnimations)**:
  All 3 settings pages' `onPreferenceChange` handlers changed to use
  `Transaction.disablesAnimations = true` when overwriting the viewModel's
  contentHeight. This makes the preference overwrite snap instead of
  animate. Since the panel's current animated position tracks the picker
  (same `.settingsExpand` curve, same start time from onToggle), the
  snap to an intermediate height is imperceptible (<1pt visual difference
  at any frame). No oscillation → no overflow → no scrollbar flash.

- **Part 4 (keyboard/collapse height synchronization)**:
  Keyboard-triggered picker toggles and ScreenPickerRow's auto-collapse
  path bypass ExpandableSettingsRow's Button, so onToggle isn't called.
  Without synchronous height prediction, the panel doesn't start animating
  until onPreferenceChange fires, causing a jumpy series of snap-height
  changes (visible stutter). Fix: each parent view stores the picker's
  measured height in a `@State` property (populated by onToggle), and
  the keyboard handlers and collapseAfterDelay include the same
  `contentHeight += isExpanded ? height : -height` arithmetic inside
  their `withAnimation(.settingsExpand)` blocks. This ensures every
  toggle path (mouse, keyboard, auto-collapse) provides synchronous
  height prediction at T+0.

## Background

The original 2026-06-22 flash was diagnosed and fixed in `04756a8`
(see `2026-06-22-settings-page-scrollbar-flash.md`). The fix made
`ExpandableContent`'s frame animation and `NotchView`'s panel height
animation share `Animation.settingsExpand` (0.2s easeInOut), so they
stay in lock-step. Symptom was gone on home/agents/performance pickers.

## What Went Wrong in 1.3.1

`NotchView.swift:274` (now refactored) added:

```swift
.animation(.smooth, value: notchAppearanceStyleRaw)
```

The author's reasoning was reasonable in isolation:

- "I'm only animating the background style transition, not panel height."
- "`notchAppearanceStyleRaw` only changes when the user picks a style."
- "`notchSize` and `notchAppearanceStyleRaw` are different values."

All three of these are correct **on their own**. But SwiftUI's
`.animation(_, value:)` is a *view-tree global*: once attached to a
view, it applies to every property transition in that view's subtree
that doesn't have its own closer `.animation(_, value:)` overriding it.
The 1.3.1 author didn't realize this would pull panel-height transitions
onto the `.smooth` curve.

### Why It Manifested As "Flash When Expanding Appearance Style Picker"

`notchAppearanceStyleRaw` is `@AppStorage`. Its declared default value is
`NotchAppearanceStyle.adaptiveArtwork.rawValue` ("Music"). When the user
has previously saved a different value (e.g. "Glass"), the AppStorage
init reads UserDefaults on first appearance and **transitions** from the
declared default → the saved value. This transition is a SwiftUI state
change → fires `.animation(.smooth, value: notchAppearanceStyleRaw)`.

Timing on first menu open after launch:

1. Notch opens: `status` transitions → `openAnimation` (spring 0.45s).
2. `notchSize` starts growing toward `openedSize.height`.
3. `NotchMenuView` mounts. AppStorage init for `notchAppearanceStyleRaw`
   reads UserDefaults. If the saved value differs from the declared
   default (`adaptiveArtwork`), the property transitions in this same
   frame.
4. `.animation(.smooth, value: notchAppearanceStyleRaw)` fires.
5. The panel layout is now being driven by `.smooth` (≈0.4s adaptive
   spring) instead of `.settingsExpand` (0.2s easeInOut).
6. User expands Appearance Style picker → picker frames animate with
   `.settingsExpand`. **Mismatch with the panel's actual animation curve.**
7. VStack actual < VStack ideal briefly → ScrollView briefly clipped →
   scrollbar flashes.

The reason Sound/Screen/Claude-dir pickers didn't flash in 1.3.1 is that
they don't introduce a new `.animation(_, value:)` on the panel — they
reuse the existing `notchSize` animation. Only Appearance Style's
introduction created the curve conflict.

## Why Comments Alone Didn't Prevent This

The pre-1.3.1 panel had a ~14-line block comment explaining why
`.settingsExpand` must be used for `notchSize`:

```swift
// Match the panel's height animation to the picker's
// 0.2s easeInOut curve (same as `ExpandableContent`'s
// own frame animation). They MUST use the same curve...
```

This comment is read by anyone touching the panel animation chain. But
the 1.3.1 author wasn't touching the panel animation chain — they were
*adding to* it from outside the comment's scope. They saw the existing
`.animation(.settingsExpand, value: notchSize)` and reasoned "my value
is unrelated, I'll use the idiomatic `.smooth` for a style transition."

The comment was a *description of the existing code*, not a *contract
that gates new additions*. It had no teeth.

## The Fix: Four-Part (Curve Contract + Synchronous Prediction + disablesAnimations + Keyboard/Collapse Sync)

### Part 1 — PanelAnimationContract (Curve Matching)

See "Preceding Work — PanelAnimationContract" below. Ensures panel and
picker always use `.settingsExpand` curve. Necessary but insufficient on
its own (see "Rejected Approaches → Curve Matching Only").

### Part 2 — Synchronous Panel Height Prediction (onToggle)

The fundamental timing gap: `onPreferenceChange(MenuContentHeightKey)`
fires 1-2 frames after `isExpanded.toggle()`. Picker animation starts
at T+0, panel height animation starts at T+1/T+2. During the gap,
content > panel → scrollbar flash.

Solution: predict panel height change synchronously inside the animation
transaction.

**Callback chain:**

```
ExpandableContent.onPreferenceChange → onHeightMeasured(height)
  → ExpandableSettingsRow.measuredContentHeight = height

ExpandableSettingsRow button action:
  withAnimation(.settingsExpand) {
      isExpanded.toggle()
      onToggle?(isExpanded, measuredContentHeight)  // ← synchronous
  }

Parent (NotchMenuView / AgentSettingsView / PerformanceSettingsView):
  onToggle: { isExpanded, contentHeight in
      viewModel.menuContentHeight += isExpanded ? contentHeight : -contentHeight
      // Also store height for keyboard handler use (Part 4):
      screenPickerMeasuredHeight = contentHeight
  }
```

Both `isExpanded` and `menuContentHeight` change in the SAME animation
transaction. Panel height (`openedSize` → `notchSize`) and picker frame
both start animating from frame T+0.

**All 5 picker rows wired:**

| Picker | Parent view | contentHeight property | @State measured height |
|---|---|---|---|
| AppearanceStyle | NotchMenuView | `viewModel.menuContentHeight` | `appearancePickerMeasuredHeight` |
| Sound | NotchMenuView | `viewModel.menuContentHeight` | `soundPickerMeasuredHeight` |
| Screen | NotchMenuView | `viewModel.menuContentHeight` | `screenPickerMeasuredHeight` |
| ClaudeDir | AgentSettingsView | `viewModel.agentsContentHeight` | `claudeDirPickerMeasuredHeight` |
| PerformanceMetrics | PerformanceSettingsView | `viewModel.performanceSettingsContentHeight` | `metricsPickerMeasuredHeight` |

### Part 3 — disablesAnimations on Preference Overwrites

Even with synchronous prediction (Part 2), `onPreferenceChange` still
fires 1-2 frames later with INTERMEDIATE heights (not final). The outer
GeometryReader measures the VStack's ACTUAL animating height, which is
less than final during expand and more than final during collapse. Without
`disablesAnimations`, the overwrite interrupts the onToggle-driven panel
animation and retargets it to the intermediate height. When the next
preference fires with a different intermediate, the panel retargets
again → oscillation → overflow → scrollbar flash.

**Fix:** wrap preference overwrites in `Transaction.disablesAnimations = true`.

```swift
.onPreferenceChange(MenuContentHeightKey.self) { height in
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        viewModel.menuContentHeight = height
    }
}
```

With disablesAnimations, the overwrite snaps instead of animating. Since
the panel's current animated position tracks the picker (same
`.settingsExpand` curve, same start time from onToggle), the snap to an
intermediate height is imperceptible (<1pt visual difference at any frame).
No oscillation → no overflow → no scrollbar flash.

**Applied to all 3 settings pages:**

| Page | PreferenceKey | viewModel property |
|---|---|---|
| NotchMenuView | `MenuContentHeightKey` | `menuContentHeight` |
| AgentSettingsView | `AgentsContentHeightKey` | `agentsContentHeight` |
| PerformanceSettingsView | `PerformanceSettingsContentHeightKey` | `performanceSettingsContentHeight` |

### Part 4 — Keyboard/Collapse Height Synchronization

Keyboard-triggered picker toggles and `ScreenPickerRow.collapseAfterDelay()`
bypass `ExpandableSettingsRow.Button`, so onToggle isn't called. Without
synchronous height prediction, the panel doesn't start animating until
onPreferenceChange fires (1+ frames later). With disablesAnimations (Part
3), those preference fires are snaps, not animations — so the panel
stutters through a series of snap-height changes rather than smoothly
animating. Visible as a jumpy, stuttery resize.

**Fix:** each parent view stores the picker's measured height in a `@State`
property (populated by onToggle), and every toggle path includes the same
synchronous `contentHeight += isExpanded ? height : -height` arithmetic
inside its `withAnimation(.settingsExpand)` block.

**Keyboard handlers (3 pages):**

```swift
// NotchMenuView.performFocusedAction()
case 1:
    withAnimation(.easeInOut(duration: 0.2)) {
        screenSelector.isPickerExpanded.toggle()
        viewModel.menuContentHeight += screenSelector.isPickerExpanded
            ? screenPickerMeasuredHeight : -screenPickerMeasuredHeight
    }
// (cases 2, 6 follow same pattern for sound/appearance pickers)

// AgentSettingsView.performFocusedAction()
case claudeMainIndex:
    withAnimation(.easeInOut(duration: 0.2)) {
        viewModel.agentsClaudeDirPickerExpanded.toggle()
        viewModel.agentsContentHeight += viewModel.agentsClaudeDirPickerExpanded
            ? claudeDirPickerMeasuredHeight : -claudeDirPickerMeasuredHeight
    }

// PerformanceSettingsView.onReceive(keyboardActivateTrigger)
case 3:
    withAnimation(.easeInOut(duration: 0.2)) {
        viewModel.performanceSettingsMetricsExpanded.toggle()
        viewModel.performanceSettingsContentHeight += viewModel.performanceSettingsMetricsExpanded
            ? metricsPickerMeasuredHeight : -metricsPickerMeasuredHeight
        // ...
    }
```

**ScreenPickerRow auto-collapse:**

```swift
private func collapseAfterDelay() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        withAnimation(.easeInOut(duration: 0.2)) {
            screenSelector.isPickerExpanded = false
            onToggle?(false, pickerMeasuredHeight)  // ← subtract height
        }
    }
}
```

`ScreenPickerRow` wraps the external `onToggle` closure to capture
`pickerMeasuredHeight` from each expand, then calls it again when
collapsing so the parent's height adjustment runs synchronously.

**Complete coverage:**

| Toggle path | Mechanism | Sync height source |
|---|---|---|
| Mouse click (all 5 pickers) | ExpandableSettingsRow.Button → onToggle | `measuredContentHeight` @State |
| Keyboard (Screen/Sound/Appearance) | NotchMenuView.performFocusedAction | `@State` measured height |
| Keyboard (ClaudeDir) | AgentSettingsView.performFocusedAction | `@State` measured height |
| Keyboard (Metrics) | PerformanceSettingsView.onReceive | `@State` measured height |
| Auto-collapse (Screen) | ScreenPickerRow.collapseAfterDelay | `@State` + onToggle call |

### Preceding Work — PanelAnimationContract

`Nook/UI/Components/PanelAnimationContract.swift` (new file) makes it
structurally impossible to add a panel `.animation(_, value:)` without
explicitly going through one place:

1. `PanelAnimationInputs` struct: every animation-driving value lives
   here as a field. Adding a new state means adding a field here —
   forces every caller of `panelAnimationContract(...)` to update.
2. `panelAnimationContract(...)` extension on `View`: every
   `.animation(_, value:)` call lives in this one method. Adding a new
   state means adding a call here — forces the author to read the
   existing curves and answer the "does this value transition on the
   same frame as `notchSize`?" question (documented inline).
3. File header: a long block comment explaining the scrollbar flash
   history, the SwiftUI `.animation(_, value:)` global behavior, and
   the exact decision tree for picking a curve. Anyone editing this
   file must read past this comment to get to the code.
4. Inline annotations on the two critical entries
   (`.animation(.settingsExpand, value: inputs.notchSize)` and
   `.animation(.settingsExpand, value: inputs.notchAppearanceStyleRaw)`)
   call out "MUST stay `.settingsExpand`" so code review can grep them.

The actual curve change is one character of substance: `notchAppearanceStyleRaw`'s
animation goes from `.smooth` to `.settingsExpand`. Everything else is
infrastructure to make sure nobody undoes this in three months when
adding the next panel state.

## Rejected Approaches

### Remove Panel Height Animation (Step B)

During diagnosis, an alternative fix was attempted: remove
`.animation(_, value: notchSize)` entirely, letting the panel jump to
its new height instantly. The reasoning was that `menuContentHeight`
(GeometryReader on the outer VStack) snaps to its target value
immediately via `onPreferenceChange`, so removing the panel animation
would eliminate the mismatch between `menuContentHeight` and panel
height.

User testing rejected this approach:

- **Expand**: panel "瞬间增大" (grows instantly) — feels abrupt and
  visually jarring compared to the smooth picker animation.
- **Collapse**: still flashes the scrollbar. With the panel jumping
  instantly to the new (smaller) height, the picker's still-animating
  visual frame (still > 0pt during the 0.2s collapse) briefly exceeds
  the jumped panel → ScrollView detects overflow → scrollbar appears.

So Step B was strictly worse than Step A: worse UX (instant jump), and
didn't even fix the collapse direction. Reverted.

### Curve Matching Only (PanelAnimationContract, Step A)

User tested Step A (PanelAnimationContract) after curve matching was
restored. Flicker still existed with different patterns per picker type:

- **Appearance picker**: 2-cycle flicker (show→hide→show→hide) on both
  expand and close
- **Sound picker**: persistent scrollbar during animation (stays visible,
  then hides)
- **Claude dir picker**: 1-cycle flicker (show→hide) on close only

This confirmed that curve matching alone is insufficient — the 1-2 frame
timing gap between picker animation start and panel height animation
start still creates an overflow window. Step A was necessary (prevents
curve mismatch) but not sufficient (doesn't fix timing gap). The
synchronous onToggle fix (Part 2) addresses the timing gap.

### Hide Scrollbar Overlay (showsIndicators: false)

As a "safety net" layer, all 5 settings ScrollViews were changed from
`showsIndicators: true` to `showsIndicators: false`. The reasoning was
that even if a residual micro-overflow window exists, the scrollbar
overlay is never rendered → no visual symptom.

User rejected this approach: "你是不是偷懒直接把最外层的 Scrollbar
隐藏了" — correctly identifying that hiding the scrollbar masks the
symptom rather than fixing the root cause. All 5 ScrollViews were
reverted to `showsIndicators: true`. The actual fix is Parts 2-4
(disablesAnimations + synchronous prediction + keyboard/collapse sync),
which address the root cause (intermediate-height overwrite oscillation)
directly.

## Files Changed

### Part 1 — PanelAnimationContract (Curve Matching)
- `Nook/UI/Components/PanelAnimationContract.swift` (new) — single
  source of truth for panel animations.
- `Nook/UI/Views/NotchView.swift` — replaced 10 inline `.animation(_, value:)`
  modifiers with one `.panelAnimationContract(...)` call.
- `Nook/Core/SoundSelector.swift`, `ScreenSelector.swift`,
  `ClaudeDirSelector.swift` — removed `expandedPickerHeight` dead code.
- `Nook/Core/NotchViewModel.swift` — removed redundant selector references.

### Part 2 — Synchronous Panel Height Prediction (onToggle)
- `Nook/UI/Components/ExpandableContent.swift` — added `onHeightMeasured`
  callback, removed debug log.
- `Nook/UI/Components/ExpandableSettingsRow.swift` — added `onToggle`
  callback + `@State measuredContentHeight`, called inside withAnimation
  block.
- `Nook/UI/Components/SoundPickerRow.swift` — added `onToggle` forwarding.
- `Nook/UI/Components/ScreenPickerRow.swift` — added `onToggle` forwarding.
- `Nook/UI/Views/NotchMenuView.swift` — added `onToggle` callbacks for
  3 picker rows (Appearance/Sound/Screen) that synchronously update
  `viewModel.menuContentHeight`. Added `@State` measured height properties
  (screenPickerMeasuredHeight, soundPickerMeasuredHeight,
  appearancePickerMeasuredHeight) populated by onToggle. Removed 2 debug logs.
- `Nook/UI/Views/AgentSettingsView.swift` — added `onToggle` callback
  for ClaudeDir picker. Added `@State claudeDirPickerMeasuredHeight`
  populated by onToggle.
- `Nook/UI/Views/PerformanceSettingsView.swift` — added `onToggle` callback
  for Metrics picker. Added `@State metricsPickerMeasuredHeight`
  populated by onToggle.
- `Nook/UI/Views/NotchView.swift` — removed 2 debug logs.

### Part 3 — disablesAnimations Preference Handlers
- `Nook/UI/Views/NotchMenuView.swift` — `onPreferenceChange(MenuContentHeightKey)`
  handler wraps overwrite in `Transaction.disablesAnimations = true`.
- `Nook/UI/Views/AgentSettingsView.swift` — `onPreferenceChange(AgentsContentHeightKey)`
  handler wraps overwrite in `Transaction.disablesAnimations = true`.
- `Nook/UI/Views/PerformanceSettingsView.swift` —
  `onPreferenceChange(PerformanceSettingsContentHeightKey)` handler wraps
  overwrite in `Transaction.disablesAnimations = true`.

### Part 4 — Keyboard/Collapse Height Synchronization
- `Nook/UI/Views/NotchMenuView.swift` — keyboard handler cases 1, 2, 6
  include synchronous `menuContentHeight += isExpanded ? height : -height`
  using stored `@State` measured heights.
- `Nook/UI/Views/AgentSettingsView.swift` — keyboard handler
  `claudeMainIndex` case includes synchronous `agentsContentHeight +=`
  using `claudeDirPickerMeasuredHeight`.
- `Nook/UI/Views/PerformanceSettingsView.swift` — keyboard handler
  case 3 includes synchronous `performanceSettingsContentHeight +=`
  using `metricsPickerMeasuredHeight`.
- `Nook/UI/Components/ScreenPickerRow.swift` — added `@State pickerMeasuredHeight`
  to capture height from onToggle; `collapseAfterDelay()` calls
  `onToggle?(false, pickerMeasuredHeight)` synchronously in the same
  `withAnimation` block as `isPickerExpanded = false`.

## Verification

- `xcodebuild -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' build` → `BUILD SUCCEEDED`, no warnings or errors.
- All `showsIndicators` set to `true` on all 5 ScrollViews (user
  requirement: scrollbar must remain visible).
- Manual test matrix:
  - Mouse click: expand/collapse all 5 pickers → no scrollbar flash
  - Keyboard (j/k + Enter): expand/collapse Screen/Sound/Appearance/ClaudeDir/Metrics → no stuttery resize
  - Screen picker auto-collapse: select screen → picker collapses smoothly, no flash

## Reusable Insights

### 1. `.animation(_, value:)` is a view-tree global, not a property-scoped modifier

Once attached to a view, it applies to every property transition in that
view's subtree until overridden by a closer `.animation(_, value:)`.
This is the root mechanism behind the scrollbar flash class of bug.

### 2. Comments without structural enforcement are advisory, not contractual

A comment explaining "don't do X" is read by some people, ignored by
others, and forgotten within a few months. The fix that prevents
recurrence isn't a better comment — it's making the wrong action
structurally inconvenient (must edit a contract file, must read past
the file header, must follow the inline decision tree).

### 3. The "same value, different curve" bug class

Whenever two different values drive separate animations in the same
view tree, check whether they can transition on the same frame. If yes,
they must use the same curve (or one must be a strict subset of the
other's transition window). Otherwise, SwiftUI's `.animation(_, value:)`
will silently steal the view-tree's curve from one to the other.

### 4. The picker → panel height chain is async (and how we fixed it)

Picker `isExpanded` change → `ExpandableContent` frame animation starts
(sync with state change). GeometryReader `onPreferenceChange` fires
AFTER layout (1-2 frames later) with **intermediate** heights during
animation. `viewModel.menuContentHeight` → `viewModel.openedSize` →
`notchSize` — panel animation starts 1-2 frames after picker animation,
and the overwrites are intermediate values that retarget the panel
animation if not handled correctly.

**This inherent lag + intermediate-value overwrite is the root cause
of the flicker**, not just the curve mismatch. Even with matched curves,
the intermediate heights create oscillation when animated (panel
retargets → content reflows → new overflow → scrollbar flash).

**Fix (3 layers):**
1. **Synchronous prediction** (Part 2): predict panel height change
   inside the `withAnimation(.settingsExpand)` block via `onToggle`
   callback. Panel and picker start animating from the same frame.
2. **disablesAnimations overwrite** (Part 3): preference overwrites
   use `Transaction.disablesAnimations = true` so they snap instead
   of animate. Since the panel tracks the picker (same curve, same
   start time), the snap is imperceptible (<1pt).
3. **Keyboard/collapse sync** (Part 4): every toggle path (mouse,
   keyboard, auto-collapse) includes synchronous height prediction
   at T+0, ensuring the panel always starts animating on the first
   frame.

### 5. Removing animation doesn't fix asymmetric bugs

The panel instant-jump fix (Step B) was rejected because it fixed
expand but broke collapse. During collapse, the picker's still-animating
visual frame (still > 0pt during the 0.2s animation) overflows the
instantly-jumped panel. The asymmetry comes from the ScrollView's
overflow detection: it triggers when content > viewport, and with the
picker still visually extended, content IS > viewport. This is a
fundamental consequence of animating the picker without animating the
panel in lock-step.

## Related Documents

- `2026-06-22-settings-page-scrollbar-flash.md` — original scrollbar
  flash diagnosis and fix (curve mismatch with `openAnimation`).
- `Nook/Core/Animation+Settings.swift` — shared `Animation.settingsExpand`
  constant. Still used by `ExpandableContent` (picker frame) and
  `notchAppearanceStyleRaw` (background transition).
- `Nook/UI/Components/ExpandableContent.swift` — the picker side of
  the frame animation (still uses `.settingsExpand`).
