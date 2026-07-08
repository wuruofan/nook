# Picker Height & Broadcast Pattern — How to Add a Picker Without Breaking the Panel

> 日期: 2026-07-07
> 状态: ✅ 已落地(macOS 公开 API 限制下,这是当前架构的最优形态)
> 适用: 任何要在 settings / agents / performance 页新增 `ExpandableSettingsRow` 风格的子选择控件的开发者
> 关联: [2026-07-01 Picker Panel Height Redesign](2026-07-01-picker-panel-height-redesign.md) · [PROGRESS.md](../../PROGRESS.md)

## TL;DR

新增 picker 时,**只需做 3 件事**,**绝不能做 3 件事**:

| 必须做 ✅ | 绝不能做 ❌ |
|---|---|
| 1. 在 page-specific View 里,用编译期 `PickerLayout` 公式声明展开高度(`static let pickerLayout = PickerLayout(rowCount: …, rowHeight: …)`) | 1. **不要** 用 GeometryReader 测量 picker 高度后回写到 `viewModel.contentHeight` |
| 2. picker 自身的 `frame(height:)` 必须跟着 `isExpanded` 同步/瞬时变化,不要动画这段高度 | 2. **不要** 在 picker `onToggle` 之外(如 `onChange(viewModel.xxx)`)调整 picker 高度 |
| 3. 在 `NotchMenuView` 上的 picker,`onToggle` 里**第一行**调用 `markExplicitSet()`,**第二行**调用 `viewModel.menuContentHeight = menuContentHeight`(menu 页编译期公式) | 3. **不要** 在 page View 的 `onAppear` / `onChange(contentType)` 里"补一次"测量 — 那会和新 View 的首次布局赛跑 |

第 1 个❌ 是已有 `ExpandableSettingsRow` + `PickerLayout` 帮你挡掉的(框架已经做对了);第 2、3 个❌ 是**picker 集成者**最容易踩的坑。

---

## 背景:为什么 picker 集成需要特殊规则

settings panel(`.menu` / `.agents` / `.performanceSettings`)的"应该多大"是从数据推出来的:

```
panel maxHeight = PageLayout.staticHeight
                + Σ (每个展开的 picker 的 PickerLayout.expandedHeight)
                + settingsPageHeaderHeight (= max(24, deviceNotchRect.height))
                + 12pt trailing gap
```

`PageLayout` / `PickerLayout` 的所有数字(rowHeight、rowSpacing、topPadding、dividerHeight、containerVerticalPadding)都是**编译期常量**,由 `SettingsPageLayout.swift` 里的 `fontLineHeight` / `textRenderHeight` 派生。**Panel 高度不需要测量**。

但是 SwiftUI 的 picker `frame(height:)` 动画在 0.2s 内会驱动 `documentView.frame.size.height` 经过中间值(771 → 770 → 659 → 597),ScrollViewOverlayHelper 的 10Hz 定时器会在动画途中采集一个"几乎等于旧高度"的瞬时值,如果直接写回 `viewModel.menuContentHeight`,会**覆盖**你刚刚写下的编译期值,导致 panel 停在展开状态不缩回去。

为此,`NotchMenuView` 用了**两层防御**:

1. **菜单页 (`NotchMenuView`)** — 时间门控(0.3s) 拦截动画窗口内的 broadcast,过了门控再用收敛检测吸收稳态值。
2. **Agents 页 (`AgentSettingsView`)** — 导航 API(进入/离开 agents 时在 `viewModel.pushTo` / `navigateBack` / `toggleMenu`)里硬重置 `agentsClaudeDirPickerExpanded = false` 和 `agentsContentHeight = agentsBaseHeight`。Agents 页**不走时间门控**(agents 的 contentHeight 由 GeometryReader 测量,广播口径和写入口径都是同一个,不会有跨源漂移;真正会爆的是 picker 状态 + contentHeight 一起带过去,所以用确定性重置更稳)。

两层防御**不可互换**:
- menu 页不需要导航 API 重置(因为 page 在 Exit 路径已经把 singleton picker 重置了,且每次重开是新的 View 实例)
- agents 页不能用时间门控(agents contentHeight 来自测量,广播值才是真理;不能像 menu 那样用编译期值"覆盖"广播)

---

## 必须做 3 件事 ✅

### 1. 用 `PickerLayout` 声明展开高度

放在新增 picker 所在的 row component 文件里:

```swift
struct MyNewPickerRow: View {
    // ...
    static var pickerLayout: PickerLayout {
        PickerLayout(
            rowCount: 4,                                     // 子行数
            rowHeight: settingsSubPickerRowVerticalSublabelHeight,  // 或 .settingsSubPickerRowHeight / settingsSubToggleRowHeight
            rowSpacing: 2,
            topPadding: 4
        )
    }
}
```

**`rowHeight` 必须等于** `SettingsSubPickerRow(... verticalSublabel: true/false)` 的实际渲染高度。三个口径任选其一:

| 场景 | rowHeight |
|---|---|
| `SettingsSubPickerRow` 无 sublabel | `settingsSubPickerRowHeight` |
| `SettingsSubPickerRow` `verticalSublabel: true`(label + sublabel 上下堆叠) | `settingsSubPickerRowVerticalSublabelHeight` |
| `SettingsSubToggleRow`(圆形 + On/Off) | `settingsSubToggleRowHeight` |

⚠️ **rowHeight 和实际 row 必须严格对应**。否则 panel 会比 ScrollView 短(或长),出现底部空白或裁切。Bug 历史: claude dir picker 之前声明 `settingsSubPickerRowVerticalSublabelHeight` 但 row 没用 `verticalSublabel: true`,overshoot ~28pt。

### 2. picker 自己的 `frame(height:)` 必须瞬时跟随 `isExpanded`

`ExpandableSettingsRow` 已经做了这件事(见 `ExpandableSettingsRow.swift` 的 `targetHeight` 参数),**直接复用,不要重新发明**:

```swift
ExpandableSettingsRow(
    // ...
    isExpanded: $myPicker.isExpanded,
    targetHeight: Self.pickerLayout.expandedHeight,
    onToggle: { newExpanded, contentHeight in
        // 写入逻辑(见第 3 条)
    }
) {
    VStack(spacing: 2) {
        ForEach(options) { option in
            SettingsSubPickerRow(...) { /* tap */ }
        }
    }
}
```

`targetHeight` 是 picker 内部用 `withTransaction(\.disablesAnimations)` 瞬时设的 frame,**不要**在外面再包一层 `.animation()`。

### 3. `onToggle` 里:**第一行 `markExplicitSet()`,第二行写 `viewModel.menuContentHeight`**

只在 `NotchMenuView` 上的 picker 需要这步(因为 menu 页有 broadcast 时间门控)。Agents 页的 picker **不需要**(agents 的写入直接走 `viewModel.agentsContentHeight += pickerLayout.expandedHeight`,见下)。

```swift
// 在 NotchMenuView.swift 的 body 里:
MyNewPickerRow(
    // ...
    onToggle: { _, _ in
        markExplicitSet()                                     // ← 第 1 行:门控时间戳
        viewModel.menuContentHeight = menuContentHeight       // ← 第 2 行:写编译期值
    }
)
```

`markExplicitSet()` 把 `lastExplicitSetAt = Date()`。之后 0.3s 内 `ScrollViewOverlayHelper` 的 broadcast 会被 `handleMeasuredContentHeight` 忽略(避免覆盖刚写的编译期值)。0.3s 后 broadcast 用收敛检测(相邻两次 < 1.5pt 差异)吸收稳态值,作为 font-metric 可能漂移的兜底。

**为什么是这两行,不能少**:

- 少了 `markExplicitSet()`: 动画窗口内的 broadcast 会通过收敛检查(diff < 1.5pt 对比**展开前**的 prev)并覆盖编译期值 → panel 卡在展开状态。
- 少了 `viewModel.menuContentHeight = ...`: 编译期值根本不会写进去,panel 等到第一个有效 broadcast(0.3s 后)才更新,延迟肉眼可见。

### 3b. (Agents 页)在 picker 的 `onToggle` 里增量加/减展开高度

`AgentSettingsView.claudeDirPickerOptions` 的写法:

```swift
ExpandableSettingsRow(
    // ...
    isExpanded: $viewModel.agentsClaudeDirPickerExpanded,
    targetHeight: Self.claudeDirPickerLayout.expandedHeight,
    onToggle: { isExpanded, contentHeight in
        viewModel.agentsContentHeight += isExpanded ? contentHeight : -contentHeight
    }
)
```

agents 页**没有** markExplicitSet / 时间门控(agents 的 contentHeight 来源就是 GeometryReader 测量,广播就是写入,跨源漂移不存在)。但 agents 有自己**独有的 EXIT 路径重置**(见下面 ❌ #3 的反向说明)。

### 3c. (短键路径) 在 `toggleXxxFromKeyboard()` 里也必须双行

`NotchMenuView` 的 keyboard handler 一样要双行(因为快捷键路径和鼠标点击路径都触发同一个 picker 动画窗口):

```swift
private func toggleMyPickerFromKeyboard() {
    withAnimation(.easeInOut(duration: 0.2)) {
        myPicker.isPickerExpanded.toggle()
        markExplicitSet()                                     // ← 同样第 1 行
        viewModel.menuContentHeight = menuContentHeight       // ← 同样第 2 行
    }
}
```

---

## 绝不能做 3 件事 ❌

### ❌ 1. 不要用 GeometryReader 测量 picker 高度后回写到 viewModel

```swift
// ❌ 错误示范 — 这是 9 次 flicker 修复的根源
GeometryReader { g in
    Color.clear
        .preference(key: MyPickerHeightKey.self, value: g.size.height)
}
.onPreferenceChange(MyPickerHeightKey.self) { height in
    viewModel.menuContentHeight = height   // ← 别这么写
}
```

**为什么不行**: picker 的 `frame(height:)` 走的是 `.animation()`,SwiftUI 的 layout pass 在动画中途采集到的 `g.size.height` 是**瞬时插值**(可能等于展开前、展开中、展开后),把它写回 viewModel 会让 panel 高度跟随动画抖动;就算不走动画,GeometryReader 的首次回调时机和 onAppear 也不对齐,经常捕获到**旧**状态。

**正确做法**: 用 `PickerLayout.expandedHeight`(编译期),而不是测量。

例外: `AgentSettingsView` 的 VStack 整体高度**确实**用 GeometryReader 测量(因为行数动态 — 每个 agent provider 安装了 hooks toggle 后多一行),但**只测一次 base**,后续增量靠 picker 的 `+= pickerLayout.expandedHeight`。完整规则见 `AgentSettingsView.onPreferenceChange` 注释。

### ❌ 2. 不要在 picker `onToggle` 之外的地方调整 picker 高度

```swift
// ❌ 错误示范 — 在 onChange / onReceive / 定时器里偷偷改高度
.onChange(of: viewModel.someFlag) { _, _ in
    myPicker.isPickerExpanded = true   // 别这么写
    viewModel.menuContentHeight += MyPickerRow.pickerLayout.expandedHeight
}
```

**为什么不行**: picker `frame(height:)` 的动画在 `isExpanded` 改变那一刻启动,从这一帧起 `documentView.frame.size.height` 在 0.2s 内是动画值。onChange / onReceive / Timer 触发的高度写入会绕过 onToggle 里的 `markExplicitSet()`,时间门控认为"刚才是用户主动 toggle",会**让** broadcast 写回去 — 但 broadcast 抓的是动画中间值,高度会跳。

**正确做法**: 高度调整只走 picker 自己的 onToggle(或 keyboard handler,见 ✅ #3c)。

### ❌ 3. 不要把 picker 状态持久化到 viewModel 的"页面级" @Published

```swift
// ❌ 错误示范 — picker 状态写在 viewModel 而不是 row 的 @State
@Published var myPickerExpanded: Bool = false   // ← 别这么写
```

**为什么不行**: `NotchMenuView` 是 `if/else` 分支出来的,每次 `contentType` 变回 `.menu` 是**新 View 实例**,它的 `@State` 会自动重置。但如果 picker 状态写在 `viewModel`(VM 持久化),它会跨 View 生命周期保留:
- 退出 menu → 进入 agents → 退出 agents → 回到 menu: picker 还是展开状态,panel 高度却已重置 → 底部空白。
- 退出 menu → 进入 shortcuts → 回到 menu: 同上。

**正确做法**: 
- 单页用的 picker 状态用 `@State`(自动随 View 销毁重置)— `isAppearancePickerExpanded` 就是这个模式。
- 跨页(VM 层)的 picker 状态 **必须配合** `pushTo` / `navigateBack` / `toggleMenu` 里的 EXIT 路径重置(见 `NotchViewModel.swift` 的三处 `if self.contentType == .agents` 块,这是 agents 页 claude dir picker 必须放在 VM 上的原因 — 它的展开状态参与 `agentsItemCount` 键盘索引计算,得让 menu View 也读得到)。

> 反向说明: agents 页 picker 状态**必须**在 VM 上(参与键盘索引),所以 EXIT 路径重置是 agents 的**唯一**可行模式。menu 页 picker 状态推荐放 `@State`,因为 menu View 销毁就够重置了;只有 `ScreenSelector.shared` / `SoundSelector.shared` 这种 singleton 必须 EXIT 路径显式重置(`isPickerExpanded = false`)。

---

## 调试 checklist — picker 高度不对劲时按顺序查

1. **`rowHeight` 选错?** 把 `PickerLayout.init` 的 `rowHeight` 和 row component 实际使用的 `verticalSublabel` 对照 — 必须一致(参见 ✅ #1 表格)。
2. **`onToggle` 漏了 `markExplicitSet()` 或 `viewModel.menuContentHeight = ...`?** 搜新增 picker 的所有 onToggle 调用点,确保每处都有这两行。键盘路径同理(参见 ✅ #3c)。
3. **Picker 状态写在 VM 上但没在 navigation API 里 EXIT 路径重置?** 搜 `pushTo` / `navigateBack` / `toggleMenu`,确认新 picker 对应的 VM 字段在 EXIT 路径被重置为 false(参见 ❌ #3 反向说明)。
4. **运行时开 Debug log(`/tmp/nook-debug.log`),toggle picker 抓 log**:
   - 看 `handleMeasuredContentHeight` 是否在 0.3s 窗口内被 broadcast 命中 — 命中说明 ✅ #3 漏了 `markExplicitSet()`。
   - 看 `viewModel.menuContentHeight` 是否和 `PageLayout.staticHeight + pickerLayout.expandedHeight` 一致 — 不一致说明编译期公式或 rowHeight 选错。
5. **ScrollView 实际高度 ≠ panel maxHeight?** 两者**必须**在所有帧上相等。如果 ScrollView contentSize 比 panel 大 → scrollbar 出现;反之 → 空白。计算 panel 用 `openedSize.height - headerHeight - 12` 对比 ScrollView 实际高度。

---

## 关联文档

- [2026-07-01 Picker Panel Height Redesign](2026-07-01-picker-panel-height-redesign.md) — 9 次 flicker 修复的完整背景,font-metric 派生的来历
- `SettingsPageLayout.swift` 顶部注释 — `fontLineHeight` / `textRenderHeight` / 各 row height 常量的推导
- `NotchViewModel.swift` `panelContentBuffer` 注释 — 为什么 buffer = 0 且仍然安全
- `NotchMenuView.swift` `markExplicitSet` 注释 — 时间门控的设计理由
- `AgentSettingsView.swift` `onPreferenceChange` + `onChange(contentType)` 注释 — EXIT 路径重置的设计理由