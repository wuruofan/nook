# Performance Row ⌃M Shortcut

**Date:** 2026-06-29
**Status:** Approved (pending review)

## Summary

Add a `⌃M` keyboard shortcut to the `PerformanceSummaryRow` (the compact
performance monitor tile shown on the instances page) that pushes the view model
to `.performance(.overview)`, matching the existing tap behavior.

The shortcut is **local to the row**, follows the exact pattern already used by
`MusicCardView` for its own key monitor, and is **not** exposed in the
configurable shortcuts settings. A hover tooltip shows `⌃M` to teach the user
the binding.

## Goals

- Press `⌃M` on the instances page to open the Performance detail page
- Hover the performance row to see the `⌃M` tooltip
- Follow the existing `MusicCardView` local-monitor pattern verbatim — no new
  architecture
- Zero changes to `ShortcutAction` / `ShortcutBindings` / `ShortcutManager` /
  `ShortcutSettingsView`

## Non-Goals

- Making the binding user-configurable
- Adding new pages, sections, or settings
- Cross-platform key handling beyond macOS
- Animations on the tooltip beyond what the shared modifier already does

## Design

### File: `Nook/UI/Views/PerformanceMonitorViews.swift`

#### 1. `PerformanceSummaryRow` additions

Add a `@State` monitor handle and an `onAppear` / `onDisappear` pair that
install and remove a local key event monitor.

```swift
struct PerformanceSummaryRow: View {
    @ObservedObject var monitor: PerformanceMonitor
    let action: () -> Void
    @State private var isHovered = false
    @State private var keyMonitor: Any?

    // ... existing @AppStorage / computed properties unchanged ...
```

Append to the `body` modifier chain:

```swift
    .onAppear {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Skip if a text input is focused (mirrors MusicCardView)
            if let window = event.window,
               let responder = window.firstResponder,
               responder.isKind(of: NSTextView.self)
                   || responder.isKind(of: NSTextField.self) {
                return event
            }

            // ⌃M  (keyCode 46 = M, control modifier only)
            let relevant = event.modifierFlags
                .intersection([.command, .control, .option, .shift])
            if relevant == .control && event.keyCode == 46 {
                action()
                return nil
            }
            return event
        }
    }
    .onDisappear {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
```

#### 2. Visibility guard

`PerformanceSummaryRow` is only rendered when
`SessionListView.showsPerformanceRow == true` (i.e. `isPerformanceMonitorEnabled`
is on — see `SessionListView.swift:23, 61, 68`). The `.onAppear` lifecycle
fires only when the view is in the hierarchy, so the monitor is automatically
inactive when the row is hidden — no extra guard is needed.

#### 3. Defensive `contentType` guard (optional, recommended)

A `PerformanceSummaryRow` is currently only hosted by `SessionListView` (i.e.
`contentType == .instances`), so the row only exists when we are on the
instances page. To future-proof against the row appearing on other pages, the
monitor body can additionally gate on the view model state — but doing so
requires the row to see `viewModel`. Since the row's `action: () -> Void`
closure already encapsulates "what to do", we **do not** add a view model
dependency. The existing tap handler in `SessionListView` (lines 62–64, 69–71)
also has no such guard, and the user has confirmed this scenario does not
exist.

#### 4. Tooltip — reuse the `shortcutTooltip` modifier

The `shortcutTooltip(_:)` modifier is currently `private` inside
`MusicCardView.swift` (lines 242–297 + 293–297 extension). To avoid coupling
the performance view to the music view's internals, copy the modifier into
`PerformanceMonitorViews.swift` as `private` (file-scoped). If a third caller appears,
promote it to a shared `UI/Components/ShortcutTooltip.swift` in a follow-up.

Apply to the row body:

```swift
    var body: some View {
        Button(action: action) {
            // ... existing HStack ...
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .shortcutTooltip("⌃M")          // ← new
        .onAppear { /* key monitor */ } // ← new
        .onDisappear { /* cleanup */ }  // ← new
    }
```

#### 5. No changes elsewhere

- `Nook/Core/ShortcutBindings.swift` — untouched
- `Nook/Core/ShortcutStore.swift` — untouched
- `Nook/Events/ShortcutManager.swift` — untouched
- `Nook/UI/Views/ShortcutSettingsView.swift` — untouched
- `Nook/UI/Views/SessionListView.swift` — untouched (the row's existing
  `action` closure already does the right thing)
- `Nook/Core/NotchViewModel.swift` — untouched

## Behavior

| State | ⌃M result |
| --- | --- |
| On instances page, row visible, no text input focused | Push to `.performance(.overview)` |
| On instances page, row visible, NSTextView/NSTextField focused | Pass key through unchanged |
| Performance monitor disabled (row not rendered) | Monitor never installed — no effect |
| On any other page | Row not rendered — no effect |
| Notch closed | Row not rendered — no effect |

## Testing

Manual verification (no automated tests for SwiftUI key monitors in this
project — see `docs/superpowers/specs/2026-05-26-keyboard-shortcuts-design.md`
for precedent).

1. Build and run the app.
2. Open a session, ensure instances page is showing with the performance row
   visible.
3. Hover the row — confirm `⌃M` tooltip appears in the top-left after ~200ms.
4. Press `⌃M` — confirm the view pushes to the Performance overview page
   (identical to tapping the row).
5. Open a text input somewhere (if available) and press `⌃M` — confirm the
   key is **not** swallowed.
6. Disable the performance monitor in settings — confirm `⌃M` does nothing
   (the row is hidden, no monitor is installed).
7. Close the notch, reopen — confirm no leaked monitor (Xcode → Debug → View
   Debugging should not show stale event taps; in practice just verify the
   app remains responsive and the build emits no warnings).

## Risk & Mitigations

| Risk | Mitigation |
| --- | --- |
| Key monitor leaks if `onDisappear` doesn't fire | `onDisappear` runs when the row leaves the hierarchy (page change, monitor disabled, notch closed). The monitor also has a `weak` capture pattern only by being a `NSEvent.addLocalMonitorForEvents` closure; no captured strong refs to `self` that would outlive the view. |
| Conflicts with the user's `⌃M` binding in some other app | Local monitor only sees events delivered to this process's windows — same scope as `MusicCardView`'s existing `⌃O` binding. |
| Future change hosts the row on a non-instances page | Not a problem — the tap action already encapsulates "navigate to performance"; the shortcut will simply do the same. |

## Compatibility

- macOS only (NSEvent). No iOS-specific branches needed.
- No changes to the configurable shortcuts system means existing users'
  shortcut bindings are unaffected.
- No migration / settings versioning needed — no persisted state added.
