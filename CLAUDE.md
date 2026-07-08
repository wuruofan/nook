# Nook — AI Contributor Guide

> Entry point for Claude / other AI coding agents. **Pointers and hard constraints only — no spec duplication.** Read this to know which docs are mandatory and which pitfalls to avoid.

## 1. What Nook Is

Nook turns the MacBook notch into a compact desktop control layer. Agent sessions (Claude / Codex / OpenCode / Cursor) + music + system status. See [README.md](README.md) for features and screenshots.

## 2. Required Reading (by priority)

### 2.1 Cross-project SwiftUI / macOS architecture lessons (mandatory before any UI change)

**[`docs/architecture/swiftui-macos-lessons.md`](docs/architecture/swiftui-macos-lessons.md)** — 7 lessons distilled from Nook's real bugs.

**Top 3 (must know before touching UI code)**:
1. **Never use layout measurement to derive self-size** (GeometryReader feedback loop = flicker)
2. **Buffer is a platform behavior problem, not a geometry problem** (macOS NSScroller gutter is direction-sensitive)
3. **Extract helpers beats writing comments** (single source of truth — cross-file magic numbers must become functions)

### 2.2 Project-level specs (read on demand when touching the relevant module)

| Spec | When to read |
|---|---|
| [`docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md`](docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md) | Before changing any settings / agents / performance picker behavior |
| [`docs/specs/2026-07-01-picker-panel-height-redesign.md`](docs/specs/2026-07-01-picker-panel-height-redesign.md) | Before changing panel height / scrollbar code |
| [`docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md`](docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md) | Before changing opencode adapter / plugin |
| [`docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md`](docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md) | Before changing ChatItem middle layer / adding a provider |
| Other specs | See `docs/specs/` directory, pick by topic |

### 2.3 Project-level debug docs (read when diagnosing specific bugs)

- [`docs/debug/2026-06-23-bug-j-reasoning-flush.md`](docs/debug/2026-06-23-bug-j-reasoning-flush.md) — intermittent "reasoning block at end of chat" investigation
- More: `docs/debug/`

## 3. Hard Constraints (violating these regresses known bugs)

### 3.1 Picker Integration

When adding a picker, you **must**:
- Declare `PickerLayout` with compile-time `rowHeight` (must match the row's actual `verticalSublabel` flag)
- In `NotchMenuView` picker `onToggle`: **line 1** `markExplicitSet()` + **line 2** `viewModel.menuContentHeight = menuContentHeight`
- Same two lines in keyboard toggle handlers

You **must not**:
- Measure picker height with GeometryReader and write back to viewModel
- Adjust picker height anywhere outside the picker's `onToggle`
- Put picker state on viewModel without resetting it in the navigation API EXIT path

Full rules: [`docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md`](docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md) — "must do 3 + must not do 3".

### 3.2 Single Source of Truth (SOI)

Any **cross-file constant derived from data X** must be extracted as `func deriveFromX(_ x: X) -> CGFloat`. No inline magic numbers across files.

Example: header height = `settingsPageHeaderHeight(for: geometry)` (in `SettingsPageLayout.swift`). Do NOT inline `max(24, geometry.deviceNotchRect.height)` in `NotchViewModel` / `AgentSettingsView` / `NotchView` independently.

### 3.3 Cross-Process Event Compatibility

Before changing opencode adapter: read the v1.17 compatibility matrix. The PRIMARY vs DEFENSIVE detection paths have explicit design rationale (see `question.asked` dual-path) — do NOT casually merge them.

## 4. Progress Tracking (Critical)

PROGRESS.md is the canonical recent-work log. For day-to-day operations, **use the `progress-*` skills** registered at `~/.agents/skills/`.

### 4.1 Triggers

| When | Skill |
|---|---|
| Before `git commit` / `stash` / `push` / PR | `/progress-save` |
| Resuming work, new device, branch switch | `/progress-restore` |
| Major task complete, PROGRESS.md too long | `/progress-archive` |
| New session continuing previous work | `/progress-summary` |
| `git merge` / `rebase` / `cherry-pick` touching PROGRESS.md | `/progress-merge` |
| Conflict markers (`<<<<<<<`) detected in PROGRESS.md | `/progress-merge` |

### 4.2 Git merge / rebase / cherry-pick sequencing

When a git op produces conflicts and PROGRESS.md is one of the conflicted files:

1. **Resolve non-PROGRESS.md conflicts first.** Source code conflicts are mechanical; PROGRESS.md is a narrative doc with different rules.
2. **Verify code state.** Run tests / build, or sanity-check that post-conflict code compiles. PROGRESS.md reflects working state — fix code first, then describe it.
3. **Call `/progress-merge`** for the PROGRESS.md conflict. The skill knows how to merge narrative sides intelligently.
4. **Stage and complete the merge.** `git add PROGRESS.md` and finalize.

**Why this order matters**: if you `/progress-merge` first, you merge narratives about code states that haven't been reconciled. You'll describe the wrong state or have to redo the merge.

### 4.3 PROGRESS.md Is a Rolling Log

[PROGRESS.md](PROGRESS.md) is a recent-work log that gets archived periodically. PROGRESS holds 1-2 line pointers only — **architecture decisions and bug investigations must be persisted to `docs/specs/` / `docs/debug/` / `docs/architecture/` or code comments**, not just PROGRESS (it will get archived and the detail is lost).

### 4.4 Anti-patterns (workflow)

- ❌ Manually editing `<<<<<<<` / `=======` / `>>>>>>>` in PROGRESS.md — always use `/progress-merge`. Manual merge tends to lose entries.
- ❌ Skipping `/progress-save` before commit — the skill is fast, no reason to skip.

## 5. Diagnostic Logging

`/tmp/nook-debug.log` (10 MB rolling) is enabled when the user toggles "Debug log" in settings. Enable it before reproducing a bug.

## 6. Build & Run

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Nook-*/Build/Products/Debug/Nook.app
```

Dev workflow: see [README.md](README.md) "Development" section (if present).

---

**Reminder for AI agents**: This file is an entry pointer, not a knowledge base. **For specific decisions, read the linked spec / debug doc** — the summaries here are too short to be reliable.