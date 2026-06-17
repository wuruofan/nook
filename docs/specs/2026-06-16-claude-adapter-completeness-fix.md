# Claude Adapter 功能完整性修复 — AskUserQuestion + Error Status

> 日期: 2026-06-16
> 状态: 待实施
> 触发: Claude ChatItemAdapter 迁移后对比验证发现功能丢失

## Context

Claude ChatItemAdapter 迁移完成后，对比验证发现两个功能丢失：

1. **AskUserQuestion 内容不展示**：用户在 Claude session 中遇到 AskUserQuestion 交互，按 ESC 中断后，question 内容在 chat view 中不可见
2. **Tool error/interrupted 状态丢失**：被拒绝的 tool（`is_error=true`）在 chat view 中显示为 `.success`

### 根因分析（数据流追踪）

以 session `3c098ddc` 的 JSONL 实际数据为例：

```
Line 1570 (assistant): tool_use { name: "AskUserQuestion", input: { questions: [{question: "...", options: [...]}] } }
Line 1571 (user):      tool_result { tool_use_id: "...", is_error: true, content: "The user doesn't want to proceed..." }
                       toolUseResult: "User rejected tool use"  ← 字符串，不是 dict
Line 1572 (user):      text: "[Request interrupted by user for tool use]"
```

**Bug 1 — input 嵌套丢失**：
`ConversationParser.parseToolUse()` 将 `input` 强制转为 `[String: String]`，只处理 String/Int/Bool 标量。AskUserQuestion 的 `questions` 是嵌套数组，直接被丢弃 → `ChatItemToolCall.input` 为空 dict → UI 无法展示问题内容。

**Bug 2 — structuredResult 缺失**：
`toolUseResult` 是字符串 `"User rejected tool use"` 而非 dict → `if let toolUseResult = toolUseResult as? [String: Any]` 失败 → `parseStructuredResult` 从未被调用 → `structuredResults[toolId]` 为 nil → UI 的 `ToolResultContent` 走 fallback 路径。

**Bug 3 — error status 未传播**：
`ClaudeChatItemAdapter` 用 `completedToolIds.contains(tool.id) ? .success : .running` 判断状态。但 `completedToolIds` 不区分成功/失败/中断 — 所有收到 tool_result 的 tool 都算 "completed"。`toolResults[toolId].isError` 和 `.isInterrupted` 信息未被使用。

### 中间层设计评估

**结论：中间层 `ChatItemToolCall.input: [String: String]` 设计不需要改动。**

- `[String: Any]` 会破坏 `Sendable` + `Equatable` 约束，波及整个管线
- 采用 **JSON 序列化约定**：`parseToolUse()` 对非标量值序列化为 JSON string，UI 层按 tool kind 反序列化。这与 `structuredResult` 模式互补（structuredResult 承载输出，input 承载输入），且向后兼容所有现有 tool

---

## Task 1: `parseToolUse()` 支持嵌套 input

**文件**: `Nook/Services/Session/ConversationParser.swift` (行 659-679)

当前代码只处理 String/Int/Bool 标量。改为：对 Array/Dict 值序列化为 JSON string。

```swift
// 现在:
if let strValue = value as? String {
    input[key] = strValue
} else if let intValue = value as? Int { ... }
// 新增:
else if let arrValue = value as? [Any] {
    if let data = try? JSONSerialization.data(withJSONObject: arrValue),
       let json = String(data: data, encoding: .utf8) {
        input[key] = json
    }
} else if let dictValue = value as? [String: Any] {
    if let data = try? JSONSerialization.data(withJSONObject: dictValue),
       let json = String(data: data, encoding: .utf8) {
        input[key] = json
    }
}
```

**效果**：AskUserQuestion 的 `input["questions"]` 变为 `"[{\"question\":\"...\",\"options\":[...]}]"` — 一个合法的 JSON string。

同步修改 `ToolUseBlock.preview`（`ChatMessage.swift` 行 102-114），对 AskUserQuestion 增加 question 文本预览。

---

## Task 2: `ClaudeChatItemAdapter` 传播 error/interrupted 状态

**文件**: `Nook/Services/Hooks/ClaudeChatItemAdapter.swift` (行 126-143)

当前：
```swift
let status: ToolStatus = completedToolIds.contains(tool.id) ? .success : .running
```

改为：
```swift
let toolResult = toolResults[tool.id]
let status: ToolStatus = {
    if toolResult?.isInterrupted == true { return .interrupted }
    if toolResult?.isError == true { return .error }
    return completedToolIds.contains(tool.id) ? .success : .running
}()
```

**效果**：被拒绝的 AskUserQuestion 显示为 `.error`，被中断的 tool 显示为 `.interrupted`。

---

## Task 3: `ClaudeChatItemAdapter` 为 AskUserQuestion 构建 fallback structuredResult

**文件**: `Nook/Services/Hooks/ClaudeChatItemAdapter.swift` (行 125-143)

当 tool 是 AskUserQuestion 且 `structuredResults[tool.id]` 为 nil（被拒绝场景）时，从 input 的 JSON 序列化 questions 构建 `AskUserQuestionResult`：

```swift
var structuredResult = structuredResults[tool.id]

// AskUserQuestion fallback: 当 toolUseResult 是 string（非 dict）时
// parseStructuredResult 不会被调用，structuredResult 为 nil。
// 从 tool input 重建 question 内容，确保 UI 能展示。
if structuredResult == nil, tool.name == "AskUserQuestion",
   let questionsJson = tool.input["questions"] {
    structuredResult = Self.buildAskUserResult(from: questionsJson)
}
```

辅助方法 `buildAskUserResult(from:)` 解析 JSON string → `[QuestionItem]` → `AskUserQuestionResult(questions:, answers: [:])`。

**效果**：即使 tool 被拒绝（无 structuredResult），UI 仍能通过 `AskUserQuestionResultContent` 展示 question 内容。

---

## Task 4: UI 渲染适配

**文件**: `Nook/UI/Views/ToolResultViews.swift`

`ToolResultContent` 当前依赖 `structuredResult` 来分发渲染。AskUserQuestion 被拒绝时 structuredResult 为 nil（Task 3 修复后不再为 nil，但作为防御性设计），增加 input-based fallback：

```swift
// 在 structured result switch 之后，增加 AskUserQuestion input fallback
} else if tool.kind == .askUserQuestion, let questionsJson = tool.input["questions"] {
    // 从 input JSON 重建 question 展示
    if let result = Self.parseQuestionsInput(questionsJson) {
        AskUserQuestionResultContent(result: result)
    }
}
```

**文件**: `Nook/UI/Views/ChatView.swift`

`ToolCallView` 的 running 状态展示（`ToolStatusDisplay.running(for:input:)`）对 AskUserQuestion 增加 question 预览：

```swift
case .askUserQuestion:
    return ToolStatusDisplay(text: "Question...", isRunning: true)
```

---

## Task 5: 构建验证 + 回归

1. `xcodebuild` 编译通过
2. 打开 session `3c098ddc`（有 AskUserQuestion + interrupted 的历史数据），验证：
   - AskUserQuestion tool call 展示 question 文本
   - 被拒绝的 tool 显示 error 状态（红色）
   - `[Request interrupted by user]` 显示 "Interrupted" 标记
   - 其他 tool（Bash/Read/Edit/Grep 等）行为不变

---

## 影响评估

| 文件 | 改动 |
|------|------|
| `ConversationParser.swift` | `parseToolUse()` 增加嵌套序列化 (~10 行) |
| `ClaudeChatItemAdapter.swift` | error 状态传播 + AskUserQuestion fallback (~20 行) |
| `ToolResultViews.swift` | AskUserQuestion input fallback (~10 行) |
| `ChatView.swift` | AskUserQuestion running 文案 (~2 行) |
| `ChatMessage.swift` | `ToolUseBlock.preview` 增加 AskUserQuestion case (~3 行) |

**总计**: ~45 行新增，0 行移除，0 个 API 变更，中间层类型签名不变。
