# Keyboard Shortcuts Configuration — Design Spec

## Overview

Add configurable keyboard shortcuts to Nook, allowing users to customize key bindings for common actions (open/close Notch, session navigation, page transitions). Shortcuts are configured via a dedicated sub-page within the Notch menu and persisted via `UserDefaults`.

## Architecture

### Navigation

Extend `NotchContentType` with `.shortcuts` case. Add a `navigationStack: [NotchContentType]` to `NotchViewModel` for push/pop navigation:

```
Menu → Tap "Keyboard Shortcuts..." → Shortcuts page (push)
                         └→ 点击 "← 返回设置" (pop)
```

### Component Breakdown

| Component | Role | Location |
|-----------|------|----------|
| `ShortcutStore` | Data layer: load/save/validate/restore defaults | `Nook/Core/ShortcutStore.swift` |
| `ShortcutManager` | Global & local event routing | `Nook/Events/ShortcutManager.swift` |
| `ShortcutSettingsView` | SwiftUI settings page in Notch | `Nook/UI/Views/ShortcutSettingsView.swift` |
| `ShortcutRow` | Single action row with chips + recording | `Nook/UI/Components/ShortcutRow.swift` |
| `KeyCombinationView` | Badge chip for a single key combo | `Nook/UI/Components/KeyCombinationView.swift` |

### Data Model

```swift
struct KeyCombination: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var flags: ModifierFlags  // wrapped Codable NSEvent.ModifierFlags
}

struct ShortcutBindings: Codable {
    var action: ShortcutAction
    var combinations: [KeyCombination]  // multiple per action
}

enum ShortcutAction: String, CaseIterable, Codable {
    case toggleNotch
    case closeNotch
    case selectPrevious
    case selectNext
    case enterSession
    case navigateBack
    case openSettings

    var displayName: String
    var defaultCombinations: [KeyCombination]
}
```

### Storage

- JSON-encoded `[ShortcutBindings]` stored under a single `UserDefaults` key
- `ShortcutStore` owns read/write; publishes changes via `@Published`
- On conflict detection, `ShortcutStore` checks all other actions' combinations before accepting a new one

### Shortcut Mappings (Default)

| Action | Default Combination(s) |
|--------|----------------------|
| toggleNotch | `⌥⌘L` |
| closeNotch | `Esc` (global, closes from any page) |
| selectPrevious | `⌃P`, `↑` |
| selectNext | `⌃N`, `↓` |
| enterSession | `Enter` |
| navigateBack | `⌃H` |
| openSettings | `⌘,` |

### Event Routing

**Notch closed (background):**
- `ShortcutManager` registers Carbon `RegisterEventHotKey` for `toggleNotch` only
- All other shortcuts are inactive when Notch is closed

**Notch open (panel active):**
- `ShortcutManager` installs `NSEvent.localMonitor` on the Notch window
- Captures all navigation keys
- Routes Esc to `closeNotch` action (except during recording mode, where first Esc cancels recording, second Esc closes)
- Routes all other bound combos to their respective actions

**Esc priority stack (Notch open):**

```
1. Recording mode active? → Cancel recording
2. In shortcuts/chat/menu page? → Close Notch (closeNotch)
```

### Recording UI

```
┌─ NotchPanel ──────────────────────────────┐
│  [← Back]                                  │
│  ───────────────────────────────────────── │
│  Tap a shortcut to record · Backspace to   │
│  remove                                    │
│                                            │
│  Open Notch                      [⌥⌘L]   │
│  Close Notch                     [Esc]    │
│  Previous Session              [⌃P] [↑]  │
│  Next Session                  [⌃N] [↓]  │
│  Open Session                   [Enter]   │
│  Go Back                         [⌃H]     │
│  Open Settings                   [⌥⌘S]   │
│                                            │
│  ───────────────────────────────────────── │
│  Restore Defaults                          │
└────────────────────────────────────────────┘
```

**Interaction per row:**
1. Tap row → row highlights (recording state)
2. Press key combo → adds to `combinations` array, auto-saves, exits recording
3. Press `Backspace` during recording → removes last combination from this row
4. Press `Esc` during recording → cancels recording, no change
5. Conflict detected → flash chip red, reject binding, stay in recording
6. `×` on chip → remove that specific combination

**"Restore Defaults" button:** Shows confirmation alert, then resets all actions to `defaultCombinations`.

### Dependencies

- None new. Carbon `RegisterEventHotKey` is a system framework, already available.
- No external shortcut libraries needed.

### Files to Create

| File | Purpose |
|------|---------|
| `Nook/Core/ShortcutBindings.swift` | `KeyCombination`, `ShortcutAction`, `ShortcutBindings` models |
| `Nook/Core/ShortcutStore.swift` | Load/save/validate/conflict detection |
| `Nook/Events/ShortcutManager.swift` | Carbon global hotkey + local monitor event routing |
| `Nook/UI/Components/KeyCombinationView.swift` | Badge chip view |
| `Nook/UI/Components/ShortcutRow.swift` | Action row with recording logic |
| `Nook/UI/Views/ShortcutSettingsView.swift` | Full-page shortcuts list |

### Files to Modify

| File | Change |
|------|--------|
| `Nook/Core/NotchViewModel.swift` | Add `.shortcuts` content type case + `navigationStack` |
| `Nook/Core/Settings.swift` | Add `shortcutsKey` to `AppSettings` |
| `Nook/UI/Views/NotchView.swift` | Add switch case for `.shortcuts` |
| `Nook/UI/Views/NotchMenuView.swift` | Add "Keyboard Shortcuts..." menu row with push navigation |

### Out of Scope

- Settings page keyboard navigation (deferred)
- Music shortcuts (deferred)
- Custom action names (YAGNI)
- Global hotkey for anything other than toggleNotch (security/simplicity)
