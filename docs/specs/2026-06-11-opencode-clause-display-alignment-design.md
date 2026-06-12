# OpenCode ↔ Claude ChatItem Display Alignment — Design Spec

> 日期: 2026-06-11
> 状态: 已实现
> 目标: 让 OpenCode 的 tool call 展示效果与 Claude 一致

## Context

OpenCode 已走统一 ChatItemUpdate 管道，但 tool call 展示效果与 Claude（标杆）存在差异。

**根因**：`OpencodeHookAdapter.handleToolPart()` 第 840 行已拿到完整 `state["input"] as? [String: Any]`，但 `buildInputSummary()` 将其压缩为单一字符串，下游只能构建 `["command": summaryString]`。Claude 传递完整结构化 `tool.input`（如 `["file_path", "old_string", "new_string"]`），所以 Edit diff、MCP 格式化等都正常。

**影响范围**：
- Edit 工具：`EditInputDiffView` 需要 `file_path`/`old_string`/`new_string` → 当前 OpenCode 无法展示 diff
- MCP 工具：`MCPToolFormatter.formatArgs` 需要完整参数 → 当前只展示 toolName
- Grep/Read 工具：有 fallback 能工作，但数据来源不精确

## 数据流对比

```
Claude (gold standard):
  JSONL → ConversationParser → ToolUseBlock.input: [String: String]
  → SessionStore.upsertBlocks() → ToolCallItem(input: tool.input)
  → ChatView (EditInputDiffView, MCPToolFormatter, etc.)

OpenCode (当前):
  Hook event → state["input"] as? [String: Any]  ← 完整数据在这里
  → buildInputSummary() → inputSummary: String     ← 数据丢失点
  → OpencodeSessionEvent.preTool(inputSummary:)
  → ChatItemToolCall(input: ["command": inputSummary])  ← 只剩单 key
  → ChatView (EditInputDiffView 无法工作)

OpenCode (目标):
  Hook event → state["input"] as? [String: Any]
  → stringifyInput() → [String: String]             ← 保留完整结构
  → OpencodeSessionEvent.preTool(inputSummary:, input:)
  → ChatItemToolCall(input: fullInput)              ← 与 Claude 一致
  → ChatView (EditInputDiffView, MCPToolFormatter 正常工作)
```

## Implementation Plan

### Task 1: 扩展 OpencodeSessionEvent.preTool 签名

**文件**: `Nook/Services/Hooks/OpencodeHookModels.swift`

在 `.preTool` case 新增 `input: [String: String]` 参数（默认值 `[:]`），保留 `inputSummary`（日志仍在使用，默认值保证编译兼容）。

### Task 2: 添加 [String: Any] → [String: String] 转换函数

**文件**: `Nook/Services/Hooks/OpencodeHookAdapter.swift`

新增 `stringifyInput()` 静态方法：
- `String` → 直接使用
- `Int/Double/Bool` → `String(describing:)`
- 嵌套字典/数组 → JSON 序列化
- `nil` → 跳过

### Task 3: handleToolPart() 传递完整 input

**文件**: `Nook/Services/Hooks/OpencodeHookAdapter.swift`

修改 2 处 `.preTool` 构造（task 工具 + 通用工具），添加 `input: stringifyInput(input ?? [:])` 参数。

### Task 4: OpencodeChatItemAdapter 使用完整 input

**文件**: `Nook/Services/Hooks/OpencodeChatItemAdapter.swift`

修改 `convertEvent()` 的 `.preTool` case：
- Task 工具保持 `["description": ...]`（subagent container 渲染依赖此 key）
- 其他工具使用 `fullInput`（非空时），fallback 到 `["command": inputSummary]`

### Task 5: 构建验证

`xcodebuild` 确认编译通过。

## 不在本次范围

- **structuredResult**: 需独立的 output 解析逻辑，后续任务
- **旧 processOpencode* 清理**: 死代码，不影响功能，后续统一清理
- **代码块语法高亮**: 独立问题，与 provider 无关

## 涉及文件

| 文件 | 改动 |
|------|------|
| `OpencodeHookModels.swift` | `.preTool` 新增 `input` 参数 |
| `OpencodeHookAdapter.swift` | 新增 `stringifyInput()`；2 处 `.preTool` 构造传入 input |
| `OpencodeChatItemAdapter.swift` | `.preTool` case 使用完整 input 替代 `inputSummary` 构建 |

## 验证方法

1. Edit 工具应显示 `EditInputDiffView`（文件名 + old/new diff）
2. Grep 工具应显示 `grep: <pattern>`（从 `input["pattern"]` 获取）
3. MCP 工具应输出完整格式化参数
4. Bash/Read/Task 工具显示不变（行为已正确）
