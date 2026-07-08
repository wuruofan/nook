# Picker Panel Height — Data-Driven Redesign

> 日期: 2026-07-01
> 状态: ⚠ **已存档（2026-07-02 决议:overlay 方案不可行,保留 16pt buffer 兜底）** — 详见顶部新增的「决策 0」失败记录
> 触发: [Scrollbar flicker 9 次修复经验](../../PROGRESS.md#scrollbar-flicker-9-次修复经验2026-07-01) — 当前 5 层修复 + 16pt buffer 是 workaround，存在 14pt 视觉空白 + 偶发 expand 方向 gutter 闪烁
> 目标: 取消 `GeometryReader → onPreferenceChange → viewModel → openedSize → panel maxHeight` 反馈回路，让 panel 高度从数据驱动
>
> **2026-07-02 决议**: 尝试 3 种方案启用 macOS 全局 overlay scrollbar 全部失败(详见「决策 0」失败记录)。**回退到 16pt `panelContentBuffer` 兜底**(2026-07-01 commit `55219a2` 的 5 层修复链路保持原样,仅 buffer 恢复为 16pt)。本 spec 描述的"取消反馈回路 + visualIsExpanded + Task cancellation"根治方案**保留作为长期方向**,但目前没有触发它的紧迫性(flicker 在 16pt buffer 下是偶发,不是必闪)。本文档保留作为决策档案,不再是当前实施计划。

## 决策 0（2026-07-02 决议, **尝试失败, 接受 16pt buffer 现状**）: Overlay Scrollbar 全局启用 — 不可行

**初衷**: 试过用 overlay scrollbar(不保留 gutter)从架构层根治 scrollbar flicker,这样就不必走本 spec 描述的"取消反馈回路"复杂方案。

**根因(为什么 overlay 理论上完美)**: SwiftUI `ScrollView` 在 macOS 上桥接 `NSScrollView`, NSScroller(legacy 样式)在 grow 方向主动保留 ~14pt gutter。picker 展开/折叠 → VStack contentSize 变化 → NSScroller "看清"未溢出 → 收掉 gutter → 布局宽度变化 → "咣"一下抖。Overlay scrollbar 浮在内容上不保留 gutter, 完美解决。

**3 种方案都失败(按时间顺序)**:

1. **方案 A(启动 crash, 已 revert)**: `NSScroller.perform(NSSelectorFromString("setPreferredScrollerStyle:"), with: .overlay.rawValue)` — 启动时 crash `+[NSScroller setPreferredScrollerStyle:]: unrecognized selector`。**根因**:该 selector 在 AppKit 公开 API **根本不存在**。`NSScroller.h` 行 68 只有 read-only `+preferredScrollerStyle`, 没有 class-level setter。NSScroller 没有"per-process set default"公开 API。

2. **方案 B(编译失败, 已 revert)**: `NSScrollView.appearance().scrollerStyle = .overlay` — 编译失败 3 个错误("instance member 'appearance' cannot be used on type")。**根因**: Swift 把 `NSScrollView.appearance` 解析成 `NSAppearanceCustomization.appearance` instance property(`@property (nullable, strong) NSAppearance *appearance`), 不是 `+appearance()` class method。`NSAppearance` 类没有 `+appearance`(只有 `+appearanceNamed:`), spec 之前记录"撞名 `NSAppearance.appearance()`"实际**误诊** ——但 `appearance` 这个 symbol 确实被 Swift 解析错了, 拿不到 proxy。`as NSScrollView` type cast 也没用, 因为问题在 `appearance` symbol 解析阶段。

3. **方案 C(运行时 crash, 已 revert)**: `NSClassFromString("NSScrollView")` + `perform("appearance")` — 编译通过, 启动时 crash `+[NSScrollView appearance]: unrecognized selector`。**根因**: `+appearance()` class method **在 AppKit 公开 API 根本不存在** —— 不是我之前假设的"Swift 不暴露"。检查 NSView.h, NSResponder.h, NSObject.h, NSAppearance.h 都没有该 selector 声明。所以走 `perform` 也找不到。AppKit 的"appearance proxy"实际是**通过其他机制**(NSAppearanceCustomization 协议 instance property + 每个类的私有 swizzling)实现, 公开 API 没有 class-level entry point。

**结论**: 公开 AppKit API **不允许**一个进程把自己的所有 NSScrollView 默认改成 overlay style, 而不影响其他 app 的 NSScrollView。可行但侵入大的路径:
- **Method swizzle** `-[NSScrollView init...]` 在构造时设 scrollerStyle: 侵入大, App Store 拒绝
- **`NSViewRepresentable` 包 NSScrollView** 替换所有 SwiftUI `ScrollView` 调用点: 侵入大, 要改 ~10 个文件
- **写 `AppleScrollerStyle` UserDefaults key** (值 1 = overlay): 公开文档没有这个 key, 实际是否被 AppKit 读取未验证, 且影响全局(改其他 app 的 scrollbar)

**当前接受**: 16pt `panelContentBuffer` 兜底(commit `55219a2` 的 5 层修复链路)已是 macOS 公开 API 限制下的最优解, 14pt 视觉空白是 trade-off, 用户在 PROGRESS.md 标记的"打补丁"评价准确。**没有绕路**。如果未来用户对 14pt 空白仍有抱怨, 可重新评估 method swizzle 路线(但需要接受 App Store 拒绝风险, 或改用 Developer ID 渠道分发)。

---

## Overview(**原 spec 入口, 仍是长期方向, 但当前不实施**)

当前架构用 9 次迭代把 scrollbar flicker 从"必闪"调到"偶尔闪"+14pt 视觉空白。**没有根治**——反馈回路在，每个 macOS 版本 / NSScroller 内部行为变化都可能让 buffer 失效。

**核心观察**：panel 的"应该多大"是从数据推出来的（picker 状态 + 静态行高），但当前架构让 panel 从 **layout 测量**（GeometryReader）反推自身尺寸。**layout 是结果，尺寸是输入**——本末倒置。

**核心收益**：
- ✅ 闪烁根除（VStack content 永不动画，NSScroller 永远不保留 gutter）
- ✅ 删 16pt buffer（panel 紧凑，无视觉空白）
- ✅ 不再依赖 SwiftUI layout 时序（可预测）
- ✅ 删 ~50 行 preference 反馈代码

## 架构关键决策

### 决策 1: Panel 高度 = sum(picker targetHeights) + staticRowHeight

**数据流向**（不经过 GeometryReader 反馈）：

```
isExpanded (父 → picker)  ─┐
                            ├─→  picker 内部 visualIsExpanded
measuredContentHeight ──────┘        ↓ instant（withTransaction disablesAnimations）
                              frame(height: visualIsExpanded ? measured : 0)
                                    ↓
                              VStack contentSize（instant，no animation）
                                    ↓
picker 上报 targetHeight 到父视图
                                    ↓
父视图 sum 所有 picker targetHeight + staticRowHeight
                                    ↓
viewModel.contentHeight（@Published，父视图写入）
                                    ↓
openedSize.height（computed）
                                    ↓
panel maxHeight（instant，data-driven，**PanelAnimationContract 中 notchSize 动画被移除**）
```

**关键点**：
- `measuredContentHeight` 是 picker 内部 GeometryReader **第一次测量**的结果，之后缓存（不重新测量）
- `targetHeight = visualIsExpanded ? measuredContentHeight : 0`（instant，picker 决定）
- panel 高度 = `Σ targetHeights + staticRowHeight`（纯加法，不测量）
- **panel 高度变化也是 instant**（PanelAnimationContract 移除 `notchSize` 动画，详见决策 1.1）
- 没有任何环节依赖 VStack 测量结果反推尺寸

### 决策 1.1: 移除 `PanelAnimationContract` 中 notchSize 动画

**遗漏警示**：之前版本（v1）的 spec 声称 "panel 永远在正确位置，没有 in-flight 状态"，但**忘了 PanelAnimationContract.swift:201 还有 `.animation(.settingsExpand, value: inputs.notchSize)`**。如果保留这条动画，picker frame 是 instant 但 panel 高度还在 0.2s 动画，**collapse 时 panel 提前收缩 → VStack contentSize > panel → scrollbar 闪**（问题方向反转，但本质没变）。

**修改**：`PanelAnimationContract.swift` 第 201 行附近删除：
```swift
.animation(.settingsExpand, value: inputs.notchSize)
```

**为什么新方案下可行**（之前 2026-06-30 regression doc 拒绝的方案）：
- 之前拒绝原因：picker 用 frame 动画，collapse 时 picker frame 还没塌缩完 panel 已经 instant 收缩 → overflow
- 现在 picker 改用 opacity 动画，**frame 不变**直到 visualIsExpanded 延迟 200ms 才塌缩
- collapse 的前 200ms：picker frame 不变，targetHeight 不变（跟 visualIsExpanded），panel 高度也不变 → 三者同步，无 overflow
- collapse 的 200ms 后：visualIsExpanded = false，picker frame → 0，targetHeight → 0，panel 高度 instant 收缩 → 三者同时变化，无时序差

**时序验证**（expand 方向）：

| 时刻 | isExpanded | visualIsExpanded | picker frame | targetHeight | panel height | VStack contentSize | overflow |
|------|------------|------------------|--------------|--------------|--------------|---------------------|----------|
| t=0- | false | false | 0 | 0 | H_static | H_static | 0 |
| t=0+ | **true** | **true** (instant via withTransaction disables) | **H_meas** (instant) | **H_meas** (instant via onChange) | **H_static + H_meas** (instant via removed animation) | H_static + H_meas | 0 |
| t=0+ ~ 200ms | true | true | H_meas | H_meas | H_static + H_meas | H_static + H_meas | 0 |
| t=200ms+ | true | true | H_meas | H_meas | H_static + H_meas | H_static + H_meas | 0 |

**时序验证**（collapse 方向）：

| 时刻 | isExpanded | visualIsExpanded | picker frame | targetHeight | panel height | VStack contentSize | overflow |
|------|------------|------------------|--------------|--------------|--------------|---------------------|----------|
| t=0- | true | true | H_meas | H_meas | H_static + H_meas | H_static + H_meas | 0 |
| t=0+ | **false** (in withAnimation) | true (delayed 200ms) | H_meas (unchanged) | H_meas (unchanged, onChange not fired) | H_static + H_meas (unchanged, no animation) | H_static + H_meas | 0 |
| t=0+ ~ 200ms | false | true (still) | H_meas | H_meas | H_static + H_meas | H_static + H_meas | 0 |
| t=200ms+ | false | **false** (Task fires) | **0** (instant) | **0** (instant via onChange) | **H_static** (instant) | H_static | 0 |

**关键不变量**：`targetHeight` 永远跟着 `visualIsExpanded`，**不是**跟着 `isExpanded`。这保证 panel 高度和 VStack contentSize 同步变化（同步 0 → 同步变化到 0），没有"先一个后一个"的时序差。

**其他 PanelAnimationContract 动画保留**（与 panel 高度无关）：
- `.animation(openAnimation/closeAnimation, value: status)` — panel open/close transition（从关闭到打开）
- `.animation(.smooth, ...)` — vibeGlow / expandingActivity / hasPendingPermission / hasWaitingForInput / showMusicActivity
- `.animation(.settingsExpand, value: inputs.notchAppearanceStyleRaw)` — background style 切换
- `.animation(.smooth(duration: 0.45), value: inputs.artworkData)` — 音乐 artwork 切换
- `.animation(.spring(...), value: inputs.isBouncing)` — 轮播 bounce

### 决策 2: 视觉动画用 opacity，不用 frame

**当前**：picker 的 frame 动画（0 ↔ measuredContentHeight）让 VStack content 跟着动 → ScrollView contentSize 跟着动 → NSScroller 在 grow 方向保留 gutter。

**新方案**：frame 是 instant（不在动画里），opacity 是 animated。同时 panel 高度也是 instant（决策 1.1）。

```swift
// Expand 路径（user 点击）
isExpanded.toggle()  // in withTransaction(disables)
visualIsExpanded = true  // instant，frame 立刻到位，targetHeight 立刻更新
opacity 0 → 1  // animated .easeInOut 0.2s

// Collapse 路径（user 再点击）
isExpanded.toggle()  // in withAnimation(.easeInOut)
opacity 1 → 0  // animated 0.2s（frame 还是 measuredContentHeight，能看到渐隐）
Task.sleep(200ms) → visualIsExpanded = false  // 渐隐完成后 frame 才塌缩，targetHeight 同步更新
```

**视觉差异**：
- 当前：picker 视觉上"长高"，panel 跟着"长高"，都是 0.2s easeInOut
- 新方案：panel 永远在正确位置，picker frame 也是 instant 跳到位，picker 内容渐显/渐隐，0.2s（expand） / 0.4s（collapse）

**取舍**：
- 失去 picker 视觉上的"长高感"——content 渐显替代
- 失去 panel 视觉上的"长高感"——panel 永远在正确位置（instant 跳到目标）
- Collapse 慢一倍（0.4s = 渐隐 0.2s + 塌缩 instant）
- 完全消除 NSScroller 抖动（panel 和 picker frame 都 instant，同步变化，无 in-flight 状态）

### 决策 2.1: Collapse 路径的 race condition 必须用 Task cancellation 兜住

`Task.sleep(200ms)` 是 best-effort：用户在 200ms 内再次点击会触发竞态。

**错误实现**（朴素 sleep，会 race）：
```swift
.onChange(of: isExpanded) { newValue in
    if newValue {
        visualIsExpanded = true
    } else {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            visualIsExpanded = false  // ← 如果用户 200ms 内又点了 expand，sleep 醒来后这里会把 visualIsExpanded 强行设回 false
        }
    }
}
```

**正确实现**（Task 引用 + cancellation + guard）：
```swift
@State private var collapseTask: Task<Void, Never>?

.onChange(of: isExpanded) { newValue in
    // 关键：toggle 时取消前一次的 sleep Task
    collapseTask?.cancel()
    collapseTask = nil

    if newValue {
        // Expand: frame 立刻到位（instant，因为 transaction disables animation）
        visualIsExpanded = true
    } else {
        // Collapse: 启动 200ms 延迟 task
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            // 防御：如果 task 在 sleep 期间被取消，直接 return
            guard !Task.isCancelled else { return }
            visualIsExpanded = false
        }
    }
}
```

**为什么需要双重保护**：
- `collapseTask?.cancel()` 取消 in-flight task（async cancellation signal）
- `guard !Task.isCancelled else { return }` 防止 task 已经过了 sleep 但还没执行到下一行（理论可能，实际极少，但 defensive 写法零成本）

**测试场景**：连点 Sound picker 5 次（开/关/开/关/开），最后状态是 "open"，`visualIsExpanded = true`，不应被前一次 collapse 的 sleep task 干扰。

### 决策 3: 静态行高 = 每次 onAppear 重新测量，picker 切换时复用缓存

menu 的非 picker 行总高（Back / Agents... / 各种 toggle / dividers）需要确定。

**方案**：
- 每次 `NotchMenuView.onAppear` 时用 GeometryReader 测一次，存到 `@State staticRowHeight: CGFloat`
- 测量完成后，picker 切换不重新测量（只 picker 区域变化，静态区域不变）
- 下次 menu 重新出现时（用户 push 进去再 pop 出来）重新测量（因为状态可能变化）

**实现**：
```swift
@State private var menuStaticHeight: CGFloat = 0

// 在 ScrollView 的 VStack 内部放一个隐藏的 GeometryReader，
// 只在静态行（不含 picker）外层包：
VStack(spacing: 4) {
    // Back, dividers, Agents..., Performance..., Keyboard..., 
    // dividers, Music Edge Glow, Vibe Glow, dividers,
    // Launch at Login, AccessibilityRow, dividers, 
    // Star on GitHub, dividers, Quit
    // ↑ 这些是静态行
}
.background(GeometryReader { g in
    Color.clear.preference(key: StaticMenuHeightKey.self, value: g.size.height)
})
.onPreferenceChange(StaticMenuHeightKey.self) { height in
    if menuStaticHeight == 0 {  // 只在首次捕获
        menuStaticHeight = height
    }
}
```

**为什么不连续测量**：
- 当前架构的 GeometryReader 是**外层**的（包整个 VStack，包括 picker）
- 新架构把 GeometryReader **内嵌到静态行**的 VStack——只测不含 picker 的部分
- picker 切换时静态行不会重新 layout，所以不需要重新测量
- menu push/pop 重新出现时，staticRowHeight 会被 reset（`@State` 默认 0），重新测量一次

**动态内容的情况**：
- AccessibilityRow 的 `isEnabled` 状态变化**不改变高度**（只是行内文本/图标变）
- 其他 toggle 行的 on/off **不改变高度**（checkmark 状态变而已）
- 当前 menu 没有"按状态增减行"的逻辑
- 如果未来加状态行（"updating..." / "error"），要么加到 picker 区域（用 picker targetHeight 机制），要么用最坏情况高度保守值

**风险**：开发者加新静态行时需要知道这个机制（不会自动更新）。但因为是 onAppear 测量，加新行后下次进 menu 就会重测，**不会留下隐藏 bug**。

**fallback**：如果 `menuStaticHeight == 0`（首次渲染未完成），`menuContentHeight` 用 0（panel 高度偏小但 1 帧后会修正）。也可以用 `defaultMenuHeight = 552`（当前默认）作为 fallback。

### 决策 4: Picker 内部有 visualIsExpanded（@State）+ 决策 2.1 的 Task cancellation

为了实现 "frame instant + opacity animated"，picker 内部需要两个状态：

- `isExpanded: Bool`（来自父视图，source of truth）
- `visualIsExpanded: Bool`（picker 内部 @State，layout 用的"是否占空间"）

**维护规则**（带 race condition 兜底，决策 2.1）：
- isExpanded → true：取消任何 in-flight collapseTask，visualIsExpanded 立即 = true（frame 立刻展开）
- isExpanded → false：取消任何 in-flight collapseTask，启动新 sleep task；200ms 后检查 `Task.isCancelled` 并设置 visualIsExpanded = false（frame 塌缩）

```swift
@State private var visualIsExpanded: Bool = false
@State private var collapseTask: Task<Void, Never>?

.onChange(of: isExpanded) { newValue in
    var txn = Transaction()
    txn.disablesAnimations = true

    // 关键：每次 toggle 取消 in-flight collapse sleep，
    // 否则用户在 200ms 内反复 toggle 会让前一次 sleep 醒来后把
    // visualIsExpanded 强行设回 false。
    collapseTask?.cancel()
    collapseTask = nil

    withTransaction(txn) {
        if newValue {
            // Expand：frame 立刻展开（instant，不动画）
            visualIsExpanded = true
        } else {
            // Collapse：等 200ms 让 opacity 渐隐完再塌缩
            collapseTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }  // 防御性
                withTransaction(txn) {
                    visualIsExpanded = false
                }
            }
        }
    }
}
```

**为何 `withTransaction(disables)`**：visualIsExpanded 变化触发 frame 变化。如果 frame 用 SwiftUI 默认动画（implicit），frame 会渐变。`disablesAnimations` 让 frame 变化 instant。

### 决策 5: Plan B 备选方案（matchedGeometryEffect / Animatable）

如果用户对决策 2 的 opacity 视觉 + 决策 1.1 的 panel-instant 不接受，备选方案是保留"长高/缩短"视觉：

**方案 B1: matchedGeometryEffect**
- picker 内部用 opacity（不参与 layout）
- picker frame 用 `matchedGeometryEffect` 让 panel 和 picker 的 frame 变化完全同步
- 复杂度高，可能有性能开销

**方案 B2: 显式 Animatable 协议**
- 自定义一个 `AnimatablePickerModifier`，让 picker 的 frame 变化显式用 `Animatable` 协议
- panel 用同样的 modifier 同步
- 复杂度高，需要重写 picker 的 layout

**Plan B 的取舍**：
- 保留"长高/缩短"视觉
- 但 panel 高度仍然有动画（虽然与 picker 同步），Reason A 的风险仍在
- 需要 16pt buffer（理由 A 不消除）

**先按决策 1.1 + 决策 2 走，Plan B 留作 fallback**。

### 决策 6: panelContentBuffer 保留为可调常量，初始 0（**用户 review 关键发现**）

**之前的错误**（spec 之前几版说"删 16pt buffer"）：把 buffer 当成单一原因处理（"macOS NSScroller gutter 保留"），结论"新架构下不需要了"。

**用户 review 指正**：16pt buffer 实际由**两个不同原因**叠加而成：

**原因 A：动画期间的时序错位 + NSScroller 预测式 gutter 保留**
- 当前架构：picker frame 动画 0.2s，panel 高度也动画 0.2s，onPreferenceChange 延迟 1-2 帧
- 在 1-2 帧延迟里，VStack contentSize 和 ScrollView visibleSize 不同步 → overflow 可能瞬间变正 → scrollbar 出现
- NSScroller 在 content 向 visible area **增长**动画中会主动保留 gutter（"预判"内容可能溢出）
- 2pt/8pt/12pt/16pt 的实测数据**全是在有动画的情况下做的**——buffer 必须在动画中超过 NSScroller 的预判阈值才能稳定

**原因 B：测量精度 / 浮点舍入**
- 当前架构中 menuContentHeight 来自 GeometryReader（测 VStack 实际高度），visibleSize 来自手动算术（openedSize - header - 12）
- 两条独立计算路径天然有 0.1-0.5pt 浮点偏差
- 即使时序完美同步（disableAnimations 生效），偏差也可能让 overflow 瞬间变正

**2026-07-02 决议更新（决策 0 之后）**: 走 overlay 方案后,Reason A 被**直接根治**——overlay 模式不保留 gutter,根本不存在"预判"的对象。但当时做这个 spec 时不知道 overlay 路径,以为只能走"取消反馈回路"或"加大 buffer"。所以下面"新架构下两个原因分别如何"是 spec 当时基于 picker-panel-height redesign 路径写的,实际**已不需要走那条路径**(picker 视觉动画保持 frame 动画,不再需要"instant + opacity")。Reason B 仍然适用——`panelContentBuffer` 仍保留为可调常量,初始 0pt。

**新架构下两个原因分别如何**（**原 spec 假设的"新架构"=取消反馈回路方案,已被 overlay 取代,本节保留作为历史档案**）：

**原因 A：完全消除**
- 新架构无 frame 动画——picker frame instant 展开/塌缩，panel 高度也 instant（决策 1.1 移除 notchSize 动画）
- 没有动画 = NSScroller 没有"增长动画中预判溢出"的理由
- **2pt/8pt/12pt/16pt 的旧实测数据不再适用**（前提是"有动画"，新架构无动画）

**原因 B：部分消除**
- 新架构 menuContentHeight = Σ targetHeights + staticRowHeight，两条数据路径共享 picker 内部 GeometryReader 一次性测量
- VStack 的实际高度由这些 targetHeights 决定
- 偏差**应该**比当前架构小（共享数据源）
- 但**不能保证 0**：
  - VStack 的 `spacing: 4pt` × N 个元素可能有累计舍入
  - picker 的 `.fixedSize(horizontal: false, vertical: true)` 后 GeometryReader 测的高度和 VStack 分配的高度可能有亚像素差异
  - staticRowHeight 也是一次性测量，同样有舍入风险

**结论**：新架构下 buffer **可以大幅缩小**，但**精确值未知**——是 0 还是需要 1-4pt 都需要实测。

**实施策略**：
- **保留 `panelContentBuffer` 作为可调常量**（不删除）——实施时容易调整
- **初始值 0pt**（不预设 16 或其他值）——基于"Reason A 消除"逻辑上 0pt 应该够
- **实施时实测**：在分阶段 rollout 时，**用 0/1/2/4pt 分别测试**，找到最小稳定值
- **Reason B 风险补偿**：如果 0pt 偶发 scrollbar 闪（浮点边界），加 1-2pt 即可；不需要 16pt

**测试方法**（加到测试计划 #10）：
- 第一阶段（单 picker pilot）完成后，分别用 panelContentBuffer = 0/1/2/4 测试
- 每个值测试 50 次 expand/collapse，记录是否闪烁
- 找到最小不闪烁的值

**对应改动**：文件 6 保留 `panelContentBuffer` 常量（不是删除），初始 0；测试阶段再调。

## 实施改动

### 文件 1: `ExpandableContent.swift`（重写）

```swift
struct ExpandableContent<Content: View>: View {
    let isExpanded: Bool
    /// Picker 内部测量的 content 高度（缓存）。父视图通过 binding 写入。
    @Binding var measuredContentHeight: CGFloat
    /// Picker 内部 @State。父视图通过 binding 读。
    @Binding var visualIsExpanded: Bool
    @ViewBuilder let content: Content

    @State private var internalMeasured: CGFloat = 0

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in
                Color.clear.preference(key: ExpandableContentHeightKey.self,
                                       value: g.size.height)
            })
            .opacity(isExpanded ? 1 : 0)  // 视觉动画
            .frame(height: visualIsExpanded ? measuredContentHeight : 0,
                   alignment: .top)  // layout，instant
            .clipped()
            .onPreferenceChange(ExpandableContentHeightKey.self) { height in
                if abs(internalMeasured - height) > 0.5 {
                    internalMeasured = height
                    measuredContentHeight = height
                }
            }
            .onChange(of: isExpanded) { newValue in
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) {
                    if newValue {
                        visualIsExpanded = true
                    } else {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            withTransaction(txn) {
                                visualIsExpanded = false
                            }
                        }
                    }
                }
            }
    }
}
```

**删除**：
- 单独的 `onHeightMeasured: ((CGFloat) -> Void)?` 回调（用 binding 替代）
- `.animation(.settingsExpand, value: isExpanded)`（frame 不再动画）
- 5 条 `[picker-height]` 诊断 log（不再需要）

### 文件 2: `ExpandableSettingsRow.swift`（接口变更）

```swift
struct ExpandableSettingsRow<Content: View, Icon: View>: View {
    let icon: String
    var customIcon: Icon? = nil
    let label: String
    var trailingText: String? = nil
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    @Binding var isExpanded: Bool
    /// picker 当前的目标高度（0 或 measuredContentHeight）。父视图写入。
    @Binding var targetHeight: CGFloat
    @ViewBuilder private var content: () -> Content

    @State private var measuredContentHeight: CGFloat = 0
    @State private var visualIsExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Button { isExpanded.toggle() } label: { ... }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            ExpandableContent(
                isExpanded: isExpanded,
                measuredContentHeight: $measuredContentHeight,
                visualIsExpanded: $visualIsExpanded,
                content: {
                    VStack(spacing: 2) { content() }
                        .padding(.leading, 28)
                        .padding(.top, 4)
                }
            )
        }
        .onChange(of: visualIsExpanded) { newValue in
            targetHeight = newValue ? measuredContentHeight : 0
        }
    }
}
```

**删除**：
- `onToggle: ((Bool, CGFloat) -> Void)?` 回调（不再需要 height 预测）
- `measuredContentHeight` 之前在 `ExpandableSettingsRow`，现在在 `ExpandableContent` 内部
- 5 条 `[picker-toggle]` 诊断 log（不再需要）

### 文件 3: `NotchMenuView.swift`（数据流重写）

**当前**：
```swift
ScrollView { VStack { ... }.background(GeometryReader { ... }) }
    .onPreferenceChange(MenuContentHeightKey.self) { height in
        viewModel.menuContentHeight = height
    }
```

**新**：
```swift
@State private var screenPickerTargetHeight: CGFloat = 0
@State private var soundPickerTargetHeight: CGFloat = 0
@State private var appearancePickerTargetHeight: CGFloat = 0
@State private var menuStaticHeight: CGFloat = 0  // 一次性测量

private var menuContentHeight: CGFloat {
    menuStaticHeight + screenPickerTargetHeight +
    soundPickerTargetHeight + appearancePickerTargetHeight
}

var body: some View {
    ScrollView { VStack { ... } }
        .onAppear {
            // 第一次渲染时测量静态行高
            if menuStaticHeight == 0 {
                menuStaticHeight = computeStaticHeight()
            }
            viewModel.menuContentHeight = menuContentHeight
        }
        .onChange(of: screenPickerTargetHeight) { _ in
            viewModel.menuContentHeight = menuContentHeight
        }
        .onChange(of: soundPickerTargetHeight) { _ in
            viewModel.menuContentHeight = menuContentHeight
        }
        .onChange(of: appearancePickerTargetHeight) { _ in
            viewModel.menuContentHeight = menuContentHeight
        }
}

private func computeStaticHeight() -> CGFloat {
    // 600pt 是当前 menu 的非 picker 行总高（Back + Agents... + 各种 toggle + dividers）
    // 如果 menu 加新行，这里需要更新
    return 600
}
```

**Picker 调用**：
```swift
ScreenPickerRow(
    screenSelector: screenSelector,
    ...
    isExpanded: $screenSelector.isPickerExpanded,
    targetHeight: $screenPickerTargetHeight
)
```

**删除**：
- `MenuContentHeightKey` PreferenceKey
- `onPreferenceChange` handler
- 6 个 `@State pickerMeasuredHeight` 字段（screenPickerMeasuredHeight / soundPickerMeasuredHeight / appearancePickerMeasuredHeight / claudeDirPickerMeasuredHeight / metricsPickerMeasuredHeight）
- `snapPanelHeight` helper
- `toggleScreenPickerFromKeyboard` / `toggleSoundPickerFromKeyboard` / `toggleAppearancePickerFromKeyboard` helper（直接更新 binding 即可）
- 5 条 `[menu-pref]` 诊断 log

### 文件 4: `AgentSettingsView.swift` / `PerformanceSettingsView.swift`（同 NotchMenuView）

相同的改造：
- 删 `onPreferenceChange` + `PreferenceKey`
- 加 picker target height @State
- 加 static row height @State
- `onChange(of: picker targetHeight)` 更新 viewModel

### 文件 5: `PanelAnimationContract.swift`（**关键：移除 notchSize 动画**）

```diff
- //  ─── Panel size — MUST use `.settingsExpand` ────────────
- //
- //  ...（200+ 行解释为什么 curve 必须匹配 picker frame 动画）
- .animation(.settingsExpand, value: inputs.notchSize)
```

**完整删除 `.animation(.settingsExpand, value: inputs.notchSize)` 这一行 + 整段过时注释**（决策 1.1）。

**保留**：
- `.animation(openAnimation/closeAnimation, value: status)` — panel open/close transition
- `.animation(.smooth, ...)` — vibeGlow / expandingActivity / hasPendingPermission / hasWaitingForInput / showMusicActivity
- `.animation(.settingsExpand, value: inputs.notchAppearanceStyleRaw)` — background style 切换
- `.animation(.smooth(duration: 0.45), value: inputs.artworkData)` — artwork
- `.animation(.spring(...), value: inputs.isBouncing)` — carousel bounce

**为什么**：
- panel 高度变化是 instant（数据驱动，不动画）
- 移除 `notchSize` 动画后，panel maxHeight 跟随数据 instant 变化
- 跟 picker frame instant 同步（决策 2 + 决策 1.1），无 overflow 窗口
- **如果保留 `notchSize` 动画，collapse 时 panel 提前收缩，picker frame 还在原位 → overflow 闪**（用户 review 关键发现）

### 文件 6: `NotchViewModel.swift`（`openedSize` 改 derived）

```swift
var openedSize: CGSize {
    switch contentType {
    case .chat:
        return CGSize(...)
    case .menu:
        let headerHeight = max(24, geometry.deviceNotchRect.height)
        // panelContentBuffer 在新架构下保留为常量，**默认 0pt**（决策 6），
        // 浮点舍入需要 0-4pt buffer 的精确值在实施时实测（见测试计划 #10）
        return CGSize(
            width: min(screenRect.width * 0.4, 480),
            height: menuContentHeight + headerHeight + 12 + panelContentBuffer
        )
    // ... agents, performanceSettings 类似
    }
}
```

**保留**（不删除）：
- `private let panelContentBuffer: CGFloat = 0`（决策 6：保留作为可调常量，初始值 0；浮点舍入保护见决策 6）
- `private let panelBottomMargin: CGFloat = 16`（防止小屏幕 clip，不依赖 buffer）

**改动**：
- `panelContentBuffer` 默认改为 0（**不预设**为 16 或其他值）
- 保留 `windowHeight - panelBottomMargin` cap（小屏幕保护）

### 文件 7: `NotchView.swift`（删 panel 诊断 log）

```swift
.onChange(of: notchSize) { oldValue, newValue in
    // 删掉 [notch-size] 诊断 log
}
```

**理由**：panel 高度不再有 timing 抖动，诊断 log 没必要。

### 文件 8: `ScreenPickerRow.swift`（删 onToggle）

```swift
ExpandableSettingsRow(
    ...
    isExpanded: isExpandedBinding,
    targetHeight: $targetHeight,  // 新参数
    // onToggle 删掉
) { ... }
```

需要在 `ScreenPickerRow` 加 `@State private var targetHeight: CGFloat = 0`（自身 state），通过 binding 传给 `ExpandableSettingsRow`。

### 文件 9: `SoundPickerRow.swift`（同 ScreenPickerRow）

### 文件 10: `ScreenSelector.swift` / `SoundSelector.swift` / `ClaudeDirSelector.swift`（无变化）

`expandedPickerHeight` 已经删了。不需要再改。

### 改动量

预计 **15 个文件**变更（包含 PanelAnimationContract.swift），~350-550 行净变更。

**诊断 log 数量修正**（用户 review 指正）：
当前代码实际有 **6 条**诊断 log（不是之前写的 5 条）：
- `[picker-height]` × 1（ExpandableContent）
- `[picker-toggle]` × 1（ExpandableSettingsRow）
- `[menu-pref]` × 1（NotchMenuView）
- `[agents-pref]` × 1（AgentSettingsView）
- `[perf-pref]` × 1（PerformanceSettingsView）
- `[notch-size]` × 1（NotchView）

根治方案实施时**全部删除**（不再需要——panel 高度确定性，不再有 timing 抖动需要诊断）。

### 当前 5 层架构的诚实陈述（用户 review 指正）

之前 PROGRESS.md / regression doc 描述的"层 3（disablesAnimations onPreferenceChange）"在最后一轮迭代（`55219a2` commit）已被**撤回**——当前代码用的是 `withAnimation(.easeInOut(duration: 0.2))`，**不是** `withTransaction(disablesAnimations)`。

之前 PROGRESS.md 描述的"层 1 PanelAnimationContract（曲线匹配）"在**根治方案中也必须变**——`.animation(.settingsExpand, value: inputs.notchSize)` 会被移除。所以根治方案实施后，PanelAnimationContract 不再管 panel 高度，只管其他视觉动画（status / vibeGlow / artwork 等）。

所以当前实际起作用的层：
- ✅ 层 1 PanelAnimationContract（曲线匹配）—— 有效（含 notchSize 动画，但根治后移除）
- ✅ 层 2 onToggle 同步预测 —— 有效
- ❌ ~~层 3 disablesAnimations onPreferenceChange~~ —— 已撤回
- ✅ 层 4 keyboard/collapse 高度同步 —— 有效
- ✅ 层 5 panelContentBuffer (16pt) —— **真正兜底闪烁的层**

**16pt buffer 是当前架构下唯一的"硬底"**。前面 4 层（去掉层 3）都重要但单独不够，必须靠 16pt buffer 才能在所有 macOS 版本上稳定。这正是为什么要做根治方案——buffer 是 workaround，根治才是正路。

### openedSize / @Published 关系澄清（用户 review 指正）

`NotchViewModel.openedSize` 是 **computed property**（不是 @Published），它从 `@Published var menuContentHeight` 派生。跨文件层面 `NotchMenuView` 不能改 `openedSize` 本身，只能改 `menuContentHeight`。

实际数据流：
```
@State pickerTargetHeights: [CGFloat]    ← 父视图 local state
    ↓ .onChange
viewModel.menuContentHeight               ← @Published（父视图写入）
    ↓ computed
openedSize.height                          ← computed property
    ↓ read
notchSize.height                           ← computed in NotchView
    ↓ read
panel.frame(maxHeight:)                    ← SwiftUI layout
```

父视图通过 `.onChange(of: pickerTargetHeights) { _ in viewModel.menuContentHeight = sum + static }` 写入。Spec 之前描述的"viewModel.contentHeight 是计算属性"措辞不准确——它**还是 @Published**，只是由父视图写入而非 GeometryReader 反馈。

### 分阶段实施计划（用户 review 建议）

**不要一次性改 14 个文件**。分三阶段，每阶段独立可测、可回退：

#### 第一阶段：单 picker 试点（验证 opacity 视觉）
- 目标：只改 `AppearanceStylePickerRow`（最简单，不涉及 selector 复杂逻辑）
- 改动：
  - `ExpandableContent` / `ExpandableSettingsRow` 加新接口（保留旧接口）
  - `NotchMenuView` 加 appearance picker 的 targetHeight state，其他两个 picker 暂时保留旧 onToggle 路径
  - 删 6 条诊断 log 暂缓（先看效果）
- 验证：点 Appearance picker，看 opacity 视觉是否可接受
- **回退成本**：1 个 picker revert 即可
- **决策点**：用户接受 opacity 视觉 → 继续；不接受 → 终止整个根治方案，16pt buffer 留作永久方案

#### 第二阶段：批量改 picker 和静态行高
- 目标：所有 picker 切换到新接口，删 GeometryReader 反馈回路
- 改动：
  - `ScreenPickerRow` / `SoundPickerRow` 改用新接口
  - `NotchMenuView` / `AgentSettingsView` / `PerformanceSettingsView` 加静态行高 GeometryReader
  - 删 onPreferenceChange handlers + PreferenceKeys
  - 删 keyboard handler 里的 `pickerMeasuredHeight` state
- 验证：所有 picker 行为一致，无闪烁
- **回退成本**：git revert 第二阶段 commit

#### 第三阶段：清理诊断 log + 完整测试
- 目标：删除所有 `[picker-height]` / `[picker-toggle]` / `[menu-pref]` / `[agents-pref]` / `[perf-pref]` / `[notch-size]` 6 条 log
- 改动：grep 上述 prefix 全删
- 验证：log 完全干净，scrollbar / gutter 行为稳定
- **回退成本**：git revert 第三阶段 commit（不删 log 也可接受，但留垃圾代码）

每阶段独立 commit + 独立可测。第一阶段是最关键的 gate（视觉是否可接受）。

## 风险评估

### 视觉差异（必须接受）

| 场景 | 当前 | 新方案 |
|---|---|---|
| Expand | panel 平滑 0.2s 长高，content 跟着扩张 | panel **instant 跳到位**，content 渐显 0.2s |
| Collapse | panel 平滑 0.2s 收缩，content 跟着收缩 | content 渐隐 0.2s，panel **instant 收缩** |
| 总时长 | 0.2s / 0.2s | 0.2s / 0.4s |
| 用户感受 | "长高/缩短" | "淡入/淡出" + panel 瞬间跳 |

**Panel instant 跳的感受**：expand 时 panel 突然从矮变高（"啪" 一下），collapse 时 panel 突然从高变矮（"啪" 一下）。这是与 16pt buffer 时代"panel 平滑长高"最大的视觉差异。**这是根治方案不可逆的副作用**。

如果用户更喜欢 "长高/缩短" 视觉，**不要做这个改动**。当前 16pt buffer 是视觉上更接近现状的妥协。

**Plan B 备选**（如果 panel-instant 视觉不被接受）：保留 frame 动画但用 `matchedGeometryEffect` 或显式 `Animatable` 协议让 panel 和 picker 完全同步。复杂度高很多，**但保留"长高/缩短"视觉**。先按 opacity 方案走，如果不行再切 Plan B。

**为什么之前 2026-06-30 拒绝过 panel instant 方案**（regression doc 记录）：
- 当时 picker 用 frame 动画，collapse 时 picker frame 还没塌缩完 panel 已经 instant 收缩 → overflow 闪
- 当时结论："panel 瞬间增大效果不好" 且 "collapse 仍闪"
- **现在 picker 改用 opacity 动画，frame 延迟 200ms 才塌缩**——这两个前提都不存在了
- 之前拒绝的理由在根治方案下**不成立**

### 时序风险（race condition）

**风险**：用户在 200ms collapse delay 内再次点击 picker，会触发竞态——前一次 sleep task 醒来后把 `visualIsExpanded` 强行设回 false。

**缓解**：决策 2.1 + 决策 4 已加 Task cancellation 双重保护：
- `collapseTask?.cancel()` 取消 in-flight task
- `guard !Task.isCancelled else { return }` 防御性检查

**PanelAnimationContract notchSize 动画移除相关的时序风险**（用户 review 关键发现）：

如果保留 `.animation(.settingsExpand, value: inputs.notchSize)`：
- t=200ms 时：visualIsExpanded = false → picker frame → 0 → targetHeight → 0
- 但 `notchSize` 还在动画中（从大到小，0.2s 内）
- t=200ms+ε 时：notchSize 还比 target 大（动画进行中），VStack contentSize 已经变小
- 但**反转**：t=200ms+ε 时，picker frame = 0，但 panel 高度还在收缩中（比 final 大）
- panel 高度比 VStack contentSize 大，**没有 overflow**
- 但等 panel 动画完成后：panel 高度 = final = static + 0，VStack contentSize = static
- 中间过程中 panel 高度始终 ≥ VStack contentSize
- **看起来没毛病？**

但等等，expand 方向：
- t=0：visualIsExpanded = true（instant） → picker frame = measuredContentHeight（instant）
- VStack contentSize 已经包含 measuredContentHeight
- 但 `notchSize` 还在动画中（从小到大，0.2s 内）
- t=0+ε：notchSize 还比 final 小，panel maxHeight 比 VStack contentSize 小
- **VStack contentSize > panel maxHeight → overflow → scrollbar 闪**

**结论**：保留 `notchSize` 动画会让 **expand 方向反而出现 overflow**（之前 16pt buffer 时代 panel 是从小到大，所以 content < panel 没闪；现在 panel 还在小但 content 已经是 final，content > panel 闪）。

**这就是为什么决策 1.1 必须移除 notchSize 动画**。

### 静态行高脆性

**风险**：`menuStaticHeight` 在 onAppear 时测量，picker 切换不重测。如果 menu 加新静态行，下次进 menu 会重测（@State reset）。**但加新行后第一次进 menu 会用旧的高度**——如果新行让总高度增加，panel 会装不下直到下次重进。

**缓解**：
- 当前 menu 静态行结构稳定（所有行 always rendered）
- 加新行时开发者需要知道要重测（明显 bug：panel 装不下）
- 决策 3 已经改用 "onAppear 重测" 而非 "首次永久缓存"

### Picker 内部内容变化不响应

`measuredContentHeight` 是 picker 第一次渲染时缓存的。如果 picker 内部内容动态变化（SoundPickerRow 加载更多 sound），高度不会更新。

**当前所有 picker 都是静态列表**，没有动态内容。如果未来加动态内容，需要 invalidate measurement 机制。

## 测试计划

1. **编译通过**：`xcodebuild -scheme Nook build` 无 warning
2. **expand 单一 picker**：
   - 点 Sound picker：panel **instant 跳到位**（无 0.2s 增长），Sound 内容渐显
   - 关闭：Sound 内容渐隐（200ms），panel **instant 收缩**
   - **关键断言**：expand/collapse 过程中 log 完全无 `overflow > 0.5pt`
3. **expand 多个 picker**：两个 picker 同时打开，panel 高度 = `static + 两个 targetHeights`
4. **快速连续点击**：连点 5 次 Sound picker，最后状态正确，无中间态 stuck（验证决策 2.1 race condition 兜底）
5. **键盘激活**：用键盘上下 + Enter 触发 picker toggle，视觉一致
6. **小屏幕**：把 window 缩到 800pt，Sound picker 展开 → panel 被 cap 到 windowHeight - 16，content 超出可滚动
7. **静态行高加新行**：临时往 menu 加一个 `MenuRow("Test")`，下次进 menu panel 装得下
8. **PanelAnimationContract notchSize 动画移除验证**：用 Animation Inspector 或加临时 log 确认 panel maxHeight 变化是 instant（不是 0.2s）
9. **对比 9 次修复的 log**：第三阶段后 log 应该完全干净
10. **panelContentBuffer 实测**（决策 6）：
    - 在新架构下，`panelContentBuffer` 默认 0pt
    - 实测 0/1/2/4pt 哪个稳定
    - 测试方法：第一阶段（单 picker pilot）后，分别设 panelContentBuffer = 0/1/2/4
    - 每个值测试 50 次 expand/collapse（手动或自动化）
    - 任何一个值出现 scrollbar 闪，加 1pt 重新测
    - 找到最小不闪烁的值
    - **预期**：新架构下 0pt 或 1pt 应该够（Reason A 消除），16pt 不需要
    - **如果意外需要 16pt 级别**：说明 Reason B 的浮点风险比预想大，回到决策 6 的"保留为可调常量"重新评估
7. **对比 9 次修复的 log**：当前 5 条诊断 log 全删，log 应该完全干净

## 回退方案

如果实施后发现视觉不可接受，回退到当前 commit `55219a2`。所有改动都是新增，没有删除现有 path。

> **2026-07-02 更新（决策 0 决议后）**: 本 spec **没有实施**——overlay 方案绕开了所有问题。回退方案对应"如果 overlay 在某个 macOS 版本回归"：删掉 `AppDelegate.swift` 那 4 行代码就回到 16pt buffer 状态（commit `55219a2`），picker 视觉、panel 动画、6 条诊断 log 都保持原状。

## 决策点

需要用户确认：

1. **接受"淡入/淡出"视觉替代"长高/缩短"**？这是最大的不可逆变化。
2. **接受 collapse 0.4s 总时长**？比当前 0.2s 慢一倍。
3. **接受静态行高需要开发者维护**？如果 menu 加新行，staticHeight 要更新。
4. **接受 picker 内部内容不动态变化**？所有当前 picker 都是静态列表。

如果对任意一条不接受，**不要做这个改动**。当前 16pt buffer 已经是次优解。

> **2026-07-02 决议（决策 0）**: 以上 4 个决策点**全部作废**——overlay 方案没有改 picker 视觉、没有改 panel 动画、没有加静态行高几何、没有限制 picker 内部内容变化。用户的痛点（"闪烁 + 14pt 空白"）通过"scrollbar 不再保留 gutter"这一条架构层修复消掉，picker 继续"长高/缩短"动画，panel 继续跟随动画。**所有原本的"取舍"都消失**。
