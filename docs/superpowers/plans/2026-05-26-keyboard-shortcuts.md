# Keyboard Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add configurable keyboard shortcuts for Notch actions with a dedicated settings page.

**Architecture:** Data layer (models + UserDefaults store) → Event routing (Carbon global hotkeys + NSEvent local monitor) → SwiftUI settings page (recording UI with multi-binding support). Navigation uses a simple stack on NotchViewModel.

**Tech Stack:** Swift + SwiftUI + AppKit + Carbon (for global hotkeys). No external dependencies.

---

### Task 1: Data Models — KeyCombination, ShortcutAction, ShortcutBindings

**Files:**
- Create: `Nook/Core/ShortcutBindings.swift`

- [ ] **Step 1: Create ShortcutBindings.swift with data models**

```swift
//
//  ShortcutBindings.swift
//  Nook
//
//  Data models for configurable keyboard shortcuts
//

import AppKit
import Carbon

struct KeyCombination: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var flags: ModifierFlagsWrapper

    var displayString: String {
        var parts: [String] = []
        let flag = flags.rawValue
        if flag & NSEvent.ModifierFlags.control.rawValue != 0 { parts.append("⌃") }
        if flag & NSEvent.ModifierFlags.option.rawValue != 0 { parts.append("⌥") }
        if flag & NSEvent.ModifierFlags.shift.rawValue != 0 { parts.append("⇧") }
        if flag & NSEvent.ModifierFlags.command.rawValue != 0 { parts.append("⌘") }

        if let char = keyCodeToCharacter(keyCode) {
            parts.append(char)
        } else {
            parts.append(keyCodeToSymbol(keyCode))
        }
        return parts.joined()
    }

    var carbonKeyCode: UInt16 { keyCode }
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        let flag = self.flags.rawValue
        if flag & NSEvent.ModifierFlags.command.rawValue != 0 { flags |= UInt32(cmdKey) }
        if flag & NSEvent.ModifierFlags.option.rawValue != 0  { flags |= UInt32(optionKey) }
        if flag & NSEvent.ModifierFlags.control.rawValue != 0 { flags |= UInt32(controlKey) }
        if flag & NSEvent.ModifierFlags.shift.rawValue != 0   { flags |= UInt32(shiftKey) }
        return flags
    }

    static func from(event: NSEvent) -> KeyCombination {
        KeyCombination(keyCode: event.keyCode, flags: ModifierFlagsWrapper(rawValue: event.modifierFlags.rawValue))
    }
}

struct ModifierFlagsWrapper: Codable, Equatable, Hashable {
    var rawValue: UInt64
}

enum ShortcutAction: String, CaseIterable, Codable {
    case toggleNotch
    case closeNotch
    case selectPrevious
    case selectNext
    case enterSession
    case navigateBack
    case openSettings

    var displayName: String {
        switch self {
        case .toggleNotch:     return "Open Notch"
        case .closeNotch:      return "Close Notch"
        case .selectPrevious:  return "Previous Session"
        case .selectNext:      return "Next Session"
        case .enterSession:    return "Open Session"
        case .navigateBack:    return "Go Back"
        case .openSettings:    return "Open Settings"
        }
    }

    var sfSymbolName: String {
        switch self {
        case .toggleNotch:     return "rectangle.and.pencil.and.ellipsis"
        case .closeNotch:      return "xmark.circle"
        case .selectPrevious:  return "chevron.up"
        case .selectNext:      return "chevron.down"
        case .enterSession:    return "arrow.forward"
        case .navigateBack:    return "arrow.uturn.left"
        case .openSettings:    return "gearshape"
        }
    }

    var defaultCombinations: [KeyCombination] {
        switch self {
        case .toggleNotch:
            return [KeyCombination(keyCode: 37, flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue))] // ⌥⌘L (keyCode 37 = L)
        case .closeNotch:
            return [KeyCombination(keyCode: 53, flags: ModifierFlagsWrapper(rawValue: 0))] // Esc (keyCode 53)
        case .selectPrevious:
            return [
                KeyCombination(keyCode: 126, flags: ModifierFlagsWrapper(rawValue: 0)), // ↑
                KeyCombination(keyCode: 35, flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.control.rawValue)) // ⌃P
            ]
        case .selectNext:
            return [
                KeyCombination(keyCode: 125, flags: ModifierFlagsWrapper(rawValue: 0)), // ↓
                KeyCombination(keyCode: 45, flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.control.rawValue)) // ⌃N
            ]
        case .enterSession:
            return [KeyCombination(keyCode: 36, flags: ModifierFlagsWrapper(rawValue: 0))] // Enter
        case .navigateBack:
            return [KeyCombination(keyCode: 4, flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.control.rawValue))] // ⌃H (keyCode 4 = H)
        case .openSettings:
            return [KeyCombination(keyCode: 1, flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue))] // ⌥⌘S (keyCode 1 = S)
        }
    }
}

struct ShortcutBindings: Codable {
    var action: ShortcutAction
    var combinations: [KeyCombination]
}

// MARK: - Key Code Helpers

/// Convert a key code to a printable character string (for alphanumeric keys)
private func keyCodeToCharacter(_ keyCode: UInt16) -> String? {
    switch keyCode {
    case 0:   return "A"
    case 1:   return "S"
    case 2:   return "D"
    case 3:   return "F"
    case 4:   return "H"
    case 5:   return "G"
    case 6:   return "Z"
    case 7:   return "X"
    case 8:   return "C"
    case 9:   return "V"
    case 11:  return "B"
    case 12:  return "Q"
    case 13:  return "W"
    case 14:  return "E"
    case 15:  return "R"
    case 16:  return "Y"
    case 17:  return "T"
    case 18:  return "1"
    case 19:  return "2"
    case 20:  return "3"
    case 21:  return "4"
    case 22:  return "6"
    case 23:  return "5"
    case 24:  return "="
    case 25:  return "9"
    case 26:  return "7"
    case 27:  return "-"
    case 28:  return "8"
    case 29:  return "0"
    case 30:  return "]"
    case 31:  return "O"
    case 32:  return "U"
    case 33:  return "["
    case 34:  return "I"
    case 35:  return "P"
    case 37:  return "L"
    case 38:  return "J"
    case 39:  return "\""
    case 40:  return "K"
    case 41:  return ";"
    case 42:  return "\\"
    case 43:  return ","
    case 44:  return "/"
    case 45:  return "N"
    case 46:  return "M"
    case 47:  return "."
    case 48:  return "Tab"
    case 49:  return " "
    case 50:  return "`"
    case 53:  return nil // Esc — handled by keyCodeToSymbol
    default:  return nil
    }
}

/// Convert a key code to a symbolic name for non-printable keys
private func keyCodeToSymbol(_ keyCode: UInt16) -> String {
    switch keyCode {
    case 53:  return "Esc"
    case 36:  return "⏎"
    case 48:  return "⇥"
    case 49:  return "Space"
    case 51:  return "⌫"
    case 117: return "⌦"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    case 116: return "PgUp"
    case 121: return "PgDn"
    case 115: return "Home"
    case 119: return "End"
    case 122: return "F1"
    case 120: return "F2"
    case 99:  return "F3"
    case 118: return "F4"
    case 96:  return "F5"
    case 97:  return "F6"
    case 98:  return "F7"
    case 100: return "F8"
    case 101: return "F9"
    case 109: return "F10"
    case 103: return "F11"
    case 111: return "F12"
    default:  return "Key\(keyCode)"
    }
}
```

- [ ] **Step 2: Verify no conflicts with existing types**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook build 2>&1 | head -50`
Expected: Build succeeds (or shows only unrelated errors)

---

### Task 2: ShortcutStore — Load/Save/Validate/Defaults

**Files:**
- Create: `Nook/Core/ShortcutStore.swift`
- Modify: `Nook/Core/Settings.swift`

- [ ] **Step 1: Create ShortcutStore.swift**

```swift
//
//  ShortcutStore.swift
//  Nook
//
//  Persistence and validation for keyboard shortcut bindings
//

import Foundation
import Combine

@MainActor
class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published var bindings: [ShortcutAction: [KeyCombination]] = [:]

    private let storageKey = "nook_shortcut_bindings"

    private init() {
        load()
    }

    // MARK: - Load / Save

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ShortcutBindings].self, from: data) else {
            resetToDefaults()
            return
        }
        var map: [ShortcutAction: [KeyCombination]] = [:]
        for item in decoded {
            map[item.action] = item.combinations
        }
        bindings = map
    }

    func save() {
        let items = bindings.map { ShortcutBindings(action: $0.key, combinations: $0.value) }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        objectWillChange.send()
    }

    func combinations(for action: ShortcutAction) -> [KeyCombination] {
        bindings[action] ?? action.defaultCombinations
    }

    // MARK: - Conflict Detection

    /// Returns the action that already uses this combination, or nil if free.
    func findConflict(_ combo: KeyCombination, excluding: ShortcutAction? = nil) -> ShortcutAction? {
        for (action, combos) in bindings {
            if let excluded = excluding, action == excluded { continue }
            if combos.contains(combo) { return action }
        }
        // Also check default bindings for actions not yet customized
        for action in ShortcutAction.allCases {
            if let excluded = excluding, action == excluded { continue }
            if bindings[action] != nil { continue } // already checked above
            if action.defaultCombinations.contains(combo) { return action }
        }
        return nil
    }

    /// Adds a combination to an action. Returns false if conflict.
    @discardableResult
    func addCombination(_ combo: KeyCombination, to action: ShortcutAction) -> Bool {
        if let conflict = findConflict(combo, excluding: action) {
            print("Shortcut conflict: \(combo) already bound to \(conflict.displayName)")
            return false
        }
        var combos = bindings[action] ?? action.defaultCombinations
        if !combos.contains(combo) {
            combos.append(combo)
            bindings[action] = combos
            save()
        }
        return true
    }

    /// Removes the last combination from an action.
    func removeLastCombination(from action: ShortcutAction) {
        var combos = bindings[action] ?? action.defaultCombinations
        guard !combos.isEmpty else { return }
        combos.removeLast()
        bindings[action] = combos
        save()
    }

    /// Removes a specific combination from an action.
    func removeCombination(_ combo: KeyCombination, from action: ShortcutAction) {
        var combos = bindings[action] ?? action.defaultCombinations
        combos.removeAll { $0 == combo }
        bindings[action] = combos
        save()
    }

    func resetToDefaults() {
        bindings = [:]
        save()
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        bindings[action] != nil
    }
}
```

- [ ] **Step 2: Add storage key to AppSettings**

Edit `Nook/Core/Settings.swift`, add inside `AppSettings`:

```swift
nonisolated static let shortcutsKey = "nook_shortcut_bindings"
```

---

### Task 3: ShortcutManager — Carbon Global Hotkeys + Local Monitor

**Files:**
- Create: `Nook/Events/ShortcutManager.swift`

- [ ] **Step 1: Create ShortcutManager.swift**

```swift
//
//  ShortcutManager.swift
//  Nook
//
//  Manages global (Carbon) and local (NSApp) keyboard shortcut routing
//

import AppKit
import Carbon
import Combine

@MainActor
class ShortcutManager {
    static let shared = ShortcutManager()

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyIDCounter: UInt32 = 0
    private var localMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    /// Set by ShortcutSettingsView to prevent Esc from closing notch during recording
    var isRecording: Bool = false

    private init() {
        installCarbonEventHandler()
        subscribeToStoreChanges()
    }

    // MARK: - Global Hotkeys (Carbon)

    private var toggleNotchCombo: KeyCombination? {
        ShortcutStore.shared.combinations(for: .toggleNotch).first
    }

    private func installCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, _) -> OSStatus in
                guard let event = event else return noErr
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if hotKeyID.signature == 0x4E4F4F4B { // "NOOK"
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .globalToggleNotch, object: nil)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    func registerGlobalHotkey() {
        unregisterAllHotkeys()
        guard let combo = toggleNotchCombo else { return }

        hotKeyIDCounter += 1
        var hotKeyID = EventHotKeyID(signature: 0x4E4F4F4B, id: hotKeyIDCounter)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref = ref {
            hotKeyRefs.append(ref)
        }
    }

    private func unregisterAllHotkeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    // MARK: - Local Monitor (Notch Open)

    func startLocalMonitor() {
        stopLocalMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // During recording, pass event to be handled by ShortcutSettingsView
            if self.isRecording {
                NotificationCenter.default.post(name: .shortcutKeyDown, object: event)
                return nil // swallow the event during recording
            }

            let combo = KeyCombination.from(event: event)

            // Esc — close notch (only consume if we handle it)
            if combo.keyCode == 53 {
                NotificationCenter.default.post(name: .shortcutAction, object: ShortcutAction.closeNotch)
                return nil
            }

            // Check all action bindings
            for action in ShortcutAction.allCases {
                let combos = ShortcutStore.shared.combinations(for: action)
                if combos.contains(combo) {
                    NotificationCenter.default.post(name: .shortcutAction, object: action)
                    return nil // consumed
                }
            }

            return event // not consumed, pass through
        }
    }

    func stopLocalMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Store Subscriptions

    private func subscribeToStoreChanges() {
        ShortcutStore.shared.$bindings
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.registerGlobalHotkey()
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let globalToggleNotch = Notification.Name("com.nook.globalToggleNotch")
    static let shortcutAction = Notification.Name("com.nook.shortcutAction")
    static let shortcutKeyDown = Notification.Name("com.nook.shortcutKeyDown")
}
```

---

### Task 4: KeyCombinationView + ShortcutRow — Recording UI Components

**Files:**
- Create: `Nook/UI/Components/KeyCombinationView.swift`
- Create: `Nook/UI/Components/ShortcutRow.swift`

- [ ] **Step 1: Create KeyCombinationView.swift**

```swift
//
//  KeyCombinationView.swift
//  Nook
//
//  Badge chip for a single key combination display
//

import SwiftUI

struct KeyCombinationView: View {
    let combination: KeyCombination
    var onRemove: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 2) {
            Text(combination.displayString)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))

            if onRemove != nil {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Remove this shortcut")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(isHovered ? 0.15 : 0.1))
        )
        .onHover { isHovered = $0 }
    }
}

struct KeyCombinationView_Previews: PreviewProvider {
    static var previews: some View {
        KeyCombinationView(
            combination: KeyCombination(
                keyCode: 37,
                flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.option.rawValue)
            ),
            onRemove: {}
        )
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
```

- [ ] **Step 2: Create ShortcutRow.swift**

```swift
//
//  ShortcutRow.swift
//  Nook
//
//  A single action row in the shortcuts settings page with recording support
//

import SwiftUI
import Combine

struct ShortcutRow: View {
    let action: ShortcutAction
    let primaryTextColor: Color
    let secondaryTextColor: Color
    @ObservedObject var store: ShortcutStore
    @Binding var recordingAction: ShortcutAction?
    var onConflict: ((ShortcutAction) -> Void)?

    @State private var isHovered = false

    private var combinations: [KeyCombination] {
        store.combinations(for: action)
    }

    private var isRecording: Bool {
        recordingAction == action
    }

    var body: some View {
        Button {
            if recordingAction == nil {
                recordingAction = action
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.sfSymbolName)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(action.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                if isRecording {
                    Text("Press shortcut...")
                        .font(.system(size: 11))
                        .foregroundColor(TerminalColors.green)
                        .transition(.opacity)
                } else if combinations.isEmpty {
                    Text("None")
                        .font(.system(size: 11))
                        .foregroundColor(secondaryTextColor)
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(combinations.enumerated()), id: \.offset) { _, combo in
                            KeyCombinationView(
                                combination: combo,
                                onRemove: { removeCombo(combo) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isRecording ? TerminalColors.green.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isRecording {
            return Color.white.opacity(0.12)
        }
        return isHovered ? Color.white.opacity(0.08) : Color.clear
    }

    private var textColor: Color {
        primaryTextColor.opacity(isHovered || isRecording ? 1.0 : 0.82)
    }

    private func removeCombo(_ combo: KeyCombination) {
        store.removeCombination(combo, from: action)
    }
}
```

---

### Task 5: ShortcutSettingsView — Full Settings Page

**Files:**
- Create: `Nook/UI/Views/ShortcutSettingsView.swift`

- [ ] **Step 1: Create ShortcutSettingsView.swift**

```swift
//
//  ShortcutSettingsView.swift
//  Nook
//
//  Settings page for configuring keyboard shortcuts
//

import SwiftUI
import Combine

struct ShortcutSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color
    @StateObject private var store = ShortcutStore.shared
    @State private var recordingAction: ShortcutAction?
    @State private var showResetConfirmation = false
    @State private var conflictFlash: ShortcutAction?
    private var cancellables = Set<AnyCancellable>()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                // Back button
                MenuRow(
                    icon: "chevron.left",
                    label: "Back",
                    primaryTextColor: primaryTextColor
                ) {
                    viewModel.navigateBack()
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // Tip
                Text("Tap a shortcut to record \u{00B7} Backspace to remove")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                // Action rows
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    ShortcutRow(
                        action: action,
                        primaryTextColor: primaryTextColor,
                        secondaryTextColor: secondaryTextColor,
                        store: store,
                        recordingAction: $recordingAction,
                        onConflict: { conflicting in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                conflictFlash = conflicting
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                withAnimation { conflictFlash = nil }
                            }
                        }
                    )
                    .overlay(
                        conflictFlash == action
                            ? RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red.opacity(0.6), lineWidth: 1)
                            : nil
                    )
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // Reset button
                Button {
                    showResetConfirmation = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                            .foregroundColor(secondaryTextColor)
                            .frame(width: 16)

                        Text("Restore Defaults")
                            .font(.system(size: 12))
                            .foregroundColor(secondaryTextColor)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .alert("Restore Default Shortcuts?", isPresented: $showResetConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Restore", role: .destructive) {
                        store.resetToDefaults()
                    }
                } message: {
                    Text("This will reset all keyboard shortcuts to their default values.")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: recordingAction) { _, newValue in
            ShortcutManager.shared.isRecording = (newValue != nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutKeyDown)) { notification in
            handleKeyDown(notification)
        }
    }

    private func handleKeyDown(_ notification: Notification) {
        guard let event = notification.object as? NSEvent,
              let recording = recordingAction else { return }

        let combo = KeyCombination.from(event: event)

        // Esc during recording — cancel
        if combo.keyCode == 53 {
            recordingAction = nil
            return
        }

        // Backspace — remove last combination
        if combo.keyCode == 51 {
            store.removeLastCombination(from: recording)
            recordingAction = nil
            return
        }

        // Add combination
        let success = store.addCombination(combo, to: recording)
        if success {
            recordingAction = nil
        } else {
            // Conflict — flash and stay in recording mode
            if let conflict = store.findConflict(combo) {
                conflictFlash = conflict
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation { conflictFlash = nil }
                }
            }
        }
    }
}
```

---

### Task 6: ViewModel — Navigation Stack + Shortcuts Content Type

**Files:**
- Modify: `Nook/Core/NotchViewModel.swift`

- [ ] **Step 1: Add shortcuts content type and navigation stack**

Edit `Nook/Core/NotchViewModel.swift`:

Add `.shortcuts` to `NotchContentType`:

```swift
enum NotchContentType: Equatable {
    case instances
    case menu
    case shortcuts
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .shortcuts: return "shortcuts"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}
```

Add navigation stack property to `NotchViewModel`:

```swift
@Published var navigationStack: [NotchContentType] = []
```

Add navigation methods:

```swift
func pushTo(_ contentType: NotchContentType) {
    navigationStack.append(contentType)
    self.contentType = contentType
}

func navigateBack() {
    guard !navigationStack.isEmpty else {
        // Fallback: go to instances
        contentType = .instances
        return
    }
    navigationStack.removeLast()
    contentType = navigationStack.last ?? .instances
}
```

Update `openedSize` for `.shortcuts`:

In the `openedSize` computed property, add a new case:

```swift
case .shortcuts:
    return CGSize(
        width: min(screenRect.width * 0.4, 480),
        height: 480
    )
```

Update `notchClose` to handle shortcuts page:

`notchClose()` already does:
```swift
func notchClose() {
    if case .chat(let session) = contentType {
        currentChatSession = session
    }
    ...
    contentType = .instances
}
```

We need to also reset the navigation stack when closing:

```swift
func notchClose() {
    if case .chat(let session) = contentType {
        currentChatSession = session
    }
    navigationStack.removeAll()
    ...
}
```

---

### Task 7: Wire Up NotchView + NotchMenuView — Content Dispatch + Menu Entry

**Files:**
- Modify: `Nook/UI/Views/NotchView.swift`
- Modify: `Nook/UI/Views/NotchMenuView.swift`

- [ ] **Step 1: Add `.shortcuts` case to NotchView contentView**

In `NotchView.swift`, in the `contentView` switch, add:

```swift
case .shortcuts:
    ShortcutSettingsView(
        viewModel: viewModel,
        primaryTextColor: expandedPrimaryTextColor,
        secondaryTextColor: expandedSecondaryTextColor,
        separatorColor: expandedSeparatorColor
    )
```

- [ ] **Step 2: Add "Keyboard Shortcuts..." row to NotchMenuView**

In `NotchMenuView.swift`, after the "Appearance" section divider (before Music settings), add:

```swift
MenuRow(
    icon: "keyboard",
    label: "Keyboard Shortcuts...",
    primaryTextColor: primaryTextColor
) {
    viewModel.pushTo(.shortcuts)
}
```

Place it after the Appearance divider and before the Music divider:

```swift
Divider()
    .background(separatorColor)
    .padding(.vertical, 4)

MenuRow(
    icon: "keyboard",
    label: "Keyboard Shortcuts...",
    primaryTextColor: primaryTextColor
) {
    viewModel.pushTo(.shortcuts)
}

Divider()
    .background(separatorColor)
    .padding(.vertical, 4)
```

---

### Task 8: Wire Up ShortcutManager Lifecycle in NotchWindowController

**Files:**
- Modify: `Nook/UI/Window/NotchWindowController.swift`
- Modify: `Nook/App/AppDelegate.swift` or `Nook/App/NookApp.swift` (to start listening to global toggle)

- [ ] **Step 1: Start/stop local monitor when notch opens/closes**

In `NotchWindowController.swift`, inside the `viewModel.$status` sink in init:

```swift
viewModel.$status
    .receive(on: DispatchQueue.main)
    .sink { [weak notchWindow, weak viewModel, weak self] status in
        // ... existing code ...
        
        // Start/stop shortcut monitor
        switch status {
        case .opened:
            ShortcutManager.shared.startLocalMonitor()
        case .closed, .popping:
            ShortcutManager.shared.stopLocalMonitor()
        }
    }
```

Also register global hotkey at launch:

In init, after setting up the status sink, add:

```swift
ShortcutManager.shared.registerGlobalHotkey()
```

- [ ] **Step 2: Listen to global toggle notch notification**

In `NookApp.swift` or `AppDelegate.swift`, subscribe to `.globalToggleNotch`:

```swift
NotificationCenter.default.addObserver(
    forName: .globalToggleNotch,
    object: nil,
    queue: .main
) { [weak viewModel] _ in
    guard let viewModel = viewModel else { return }
    if viewModel.status == .opened {
        viewModel.notchClose()
    } else {
        viewModel.notchOpen(reason: .click)
    }
}
```

This needs a reference to the view model. In `NotchWindowController`, after creating the view model, we can store a weak reference. Simplest approach: subscribe in `NotchWindowController` init:

```swift
NotificationCenter.default.addObserver(
    forName: .globalToggleNotch,
    object: nil,
    queue: .main
) { [weak self] _ in
    guard let self = self else { return }
    if self.viewModel.status == .opened {
        self.viewModel.notchClose()
    } else {
        self.viewModel.notchOpen(reason: .click)
    }
}
```
