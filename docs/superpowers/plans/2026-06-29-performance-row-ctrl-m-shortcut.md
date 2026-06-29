# Performance Row ⌃M Shortcut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `⌃M` keyboard shortcut to the `PerformanceSummaryRow` on the instances page that pushes the view model to `.performance(.overview)`, with a hover tooltip showing `⌃M`. Local-only — no changes to the configurable shortcuts system.

**Architecture:** Reuse the existing `NSEvent.addLocalMonitorForEvents` pattern from `MusicCardView` (which has `⌃O` for "open source app" and `⌃⌘←/→` for prev/next track). Copy the `shortcutTooltip` view modifier from `MusicCardView.swift` into `PerformanceMonitorViews.swift` as `private` (file-scoped) and apply it to the row. The row already has an `action: () -> Void` closure wired to `viewModel.pushTo(.performance(.overview))` — the key monitor simply invokes that same closure.

**Tech Stack:** Swift + SwiftUI + AppKit (`NSEvent`). No external dependencies. No new frameworks.

**Spec:** `docs/superpowers/specs/2026-06-29-performance-row-ctrl-m-shortcut-design.md`

---

### Task 1: Copy `shortcutTooltip` modifier into `PerformanceMonitorViews.swift`

**Files:**
- Modify: `Nook/UI/Views/PerformanceMonitorViews.swift` (append at end of file)

- [ ] **Step 1: Verify the source modifier to copy**

Read `Nook/UI/Views/MusicCardView.swift` lines 240–297. Confirm the following exist verbatim:

- `private struct ShortcutTooltip: ViewModifier` (around line 242)
- `private extension View { func shortcutTooltip(_ shortcut: String) -> some View { ... } }` (around line 293)

These are the exact constructs we will copy.

- [ ] **Step 2: Append the copied modifier to `PerformanceMonitorViews.swift`**

Open `Nook/UI/Views/PerformanceMonitorViews.swift`. The file currently ends with the last type in the file. Append the following block (verbatim copy from `MusicCardView.swift` lines 240–297) at the end of the file:

```swift
// MARK: - Shortcut Tooltip

private struct ShortcutTooltip: ViewModifier {
    let shortcut: String?

    @State private var showTooltip = false
    @State private var hoverTask: DispatchWorkItem?
    @State private var hoverPoint: CGPoint = .zero

    func body(content: Content) -> some View {
        if let shortcut {
            content
                .overlay(alignment: .topLeading) {
                    if showTooltip {
                        Text(shortcut)
                            .fixedSize()
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.black.opacity(0.65))
                            )
                            .offset(x: hoverPoint.x, y: hoverPoint.y + 16)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoverPoint = point
                        hoverTask?.cancel()
                        let task = DispatchWorkItem {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showTooltip = true
                            }
                        }
                        hoverTask = task
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
                    case .ended:
                        hoverTask?.cancel()
                        hoverTask = nil
                        withAnimation(.easeInOut(duration: 0.1)) {
                            showTooltip = false
                        }
                    }
                }
        } else {
            content
        }
    }
}

private extension View {
    func shortcutTooltip(_ shortcut: String) -> some View {
        modifier(ShortcutTooltip(shortcut: shortcut))
    }
}
```

Note: the `private` access level means this is file-scoped to `PerformanceMonitorViews.swift` and does not collide with the identically-named `private` types in `MusicCardView.swift`. If Swift later complains about duplicate symbols (it should not — `private` is file-scoped), demote the music-card copies to `fileprivate` instead.

- [ ] **Step 3: Build to verify the modifier compiles in isolation**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (or equivalent — no errors). This catches typos in the copy before we wire it up.

- [ ] **Step 4: Commit**

```bash
git add Nook/UI/Views/PerformanceMonitorViews.swift
git commit -m "feat(perf-row): add fileprivate shortcutTooltip modifier"
```

---

### Task 2: Wire key monitor + tooltip into `PerformanceSummaryRow`

**Files:**
- Modify: `Nook/UI/Views/PerformanceMonitorViews.swift` (`PerformanceSummaryRow` struct only)

- [ ] **Step 1: Add the `@State keyMonitor` property**

In `PerformanceSummaryRow` (around line 20–25), add a new `@State` next to `isHovered`:

```swift
struct PerformanceSummaryRow: View {
    @ObservedObject var monitor: PerformanceMonitor
    let action: () -> Void

    @State private var isHovered = false
    @State private var keyMonitor: Any?

    @AppStorage(AppSettings.performanceVisibleSectionsKey) private var visibleSectionsRaw: String = "cpu,memory,battery,network"
```

- [ ] **Step 2: Append `.shortcutTooltip("⌃M")`, `.onAppear`, and `.onDisappear` to `body`**

Find the current end of `body` in `PerformanceSummaryRow` (the `.onHover { isHovered = $0 }` line, around line 47). Append the three new modifiers in this order:

```swift
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ForEach(visibleSections, id: \.self) { section in
                    metricTile(for: section)
                }
            }
            .frame(height: 44)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .shortcutTooltip("⌃M")
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Pass through if a text input is focused (mirrors MusicCardView).
                if let window = event.window,
                   let responder = window.firstResponder,
                   responder.isKind(of: NSTextView.self)
                       || responder.isKind(of: NSTextField.self) {
                    return event
                }

                // ⌃M  (keyCode 46 = M; control modifier only, nothing else held)
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
    }
```

Do not modify any other type in the file (e.g. `PerformanceDetailView`, `PerformanceHomeMetric`).

- [ ] **Step 3: Build to verify the full change compiles**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. If the build fails, common causes:
- `NSEvent` not in scope → ensure `import AppKit` is at the top of the file (it is, line 8).
- `NSTextView` / `NSTextField` symbol not found → ensure `import AppKit` is present.
- Duplicate `ShortcutTooltip` symbol → see Task 1 Step 2 note about demoting the music-card copy.

- [ ] **Step 4: Commit**

```bash
git add Nook/UI/Views/PerformanceMonitorViews.swift
git commit -m "feat(perf-row): ⌃M opens Performance overview from instances page"
```

---

### Task 3: Manual smoke test + PROGRESS.md entry

**Files:**
- Modify: `PROGRESS.md` (add a single bullet to "Recently Completed")

- [ ] **Step 1: Run the app and execute the manual test plan**

Open the project in Xcode (`open Nook.xcodeproj`), run the app on macOS, and verify the seven checks below. The spec at `docs/superpowers/specs/2026-06-29-performance-row-ctrl-m-shortcut-design.md` lists them in the "Testing" section; reproduced here for convenience:

1. Open a session, ensure instances page shows the performance row.
2. Hover the row — `⌃M` tooltip appears in the top-left after ~200ms.
3. Press `⌃M` — view pushes to the Performance overview page (identical to tapping the row).
4. Focus a text input (if any is reachable in the current build) and press `⌃M` — the key is **not** swallowed.
5. Disable the performance monitor in settings — `⌃M` does nothing (row hidden, no monitor installed).
6. Close the notch, reopen — app remains responsive; no warnings in the console about leaked monitors.
7. Navigate to the Performance page via tap, then navigate back to instances — `⌃M` still works.

Mark each check pass/fail. If any fail, do not proceed — go back to Task 2, fix, recommit, and re-run.

- [ ] **Step 2: Add a `Recently Completed` entry to `PROGRESS.md`**

In `PROGRESS.md`, in the `## ✅ Recently Completed` section (around line 60), prepend a new bullet. Use the SHA from Task 2's commit, replacing `TBD` with the actual short SHA (e.g. `abc1234`):

```markdown
- **#TBD ⌃M 进入 performance 页面** — `PerformanceSummaryRow` 加本地 `NSEvent.addLocalMonitorForEvents` 监听 ⌃M → 调用现有的 `action` 闭包（即 `viewModel.pushTo(.performance(.overview))`）。卡片 hover 时显示 `⌃M` tooltip（复制 `shortcutTooltip` modifier 到本文件 `private` 命名空间）。完全模仿 `MusicCardView` 的 ⌃O 模式：不进 `ShortcutAction` / `ShortcutSettingsView`、不可定制。性能监视器关闭时行不渲染 → monitor 不安装 → ⌃M 自然不响应，无需额外守卫。NSTextView/NSTextField 聚焦时透传不抢键。
```

Run `git log -1 --pretty=%h` to get the short SHA, then replace `#TBD` with `#<short-sha>` in the entry.

- [ ] **Step 3: Final commit**

```bash
git add PROGRESS.md
git commit -m "docs(progress): record ⌃M performance row shortcut"
```

- [ ] **Step 4: Verify the branch is clean and on `main`**

Run: `git status`
Expected: `nothing to commit, working tree clean` and `On branch main`.

---

## Self-Review Notes

**Spec coverage:**
- "Add a ⌃M keyboard shortcut to PerformanceSummaryRow that pushes to .performance(.overview)" → Task 2 Step 2 (calls `action()` which is wired to `viewModel.pushTo(.performance(.overview))` in `SessionListView.swift:62-64, 69-71`).
- "Local key monitor, follows MusicCardView pattern" → Task 1 copies the modifier, Task 2 uses the same `NSEvent.addLocalMonitorForEvents` shape with text-input passthrough and onDisappear cleanup.
- "Not exposed in configurable shortcuts settings" → No `ShortcutAction` / `ShortcutBindings` / `ShortcutManager` / `ShortcutSettingsView` modifications anywhere in the plan.
- "Hover tooltip showing ⌃M" → Task 1 copies `shortcutTooltip`, Task 2 Step 2 applies it.
- "Visibility = row rendered = monitor installed" → row is conditionally rendered in `SessionListView` (line 23, 61, 68), so `.onAppear` only fires when visible — implicit guard, matches spec section 3.

**Placeholder scan:** No TBD/TODO/fill-in-later placeholders. The one `#TBD` in Task 3 Step 2 is a SHA that the executing engineer fills in from the Task 2 commit (intentional, with explicit resolution steps).

**Type consistency:**
- `keyMonitor: Any?` defined in Task 2 Step 1, used in Step 2 — consistent.
- `action()` reference — same `let action: () -> Void` parameter as in the original struct; consistent.
- `ShortcutTooltip` is `private` (file-scoped) in both files — no symbol clash.
