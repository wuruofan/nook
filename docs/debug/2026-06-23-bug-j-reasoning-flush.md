# Bug J — reasoning block 出现在 chat 末尾

> 日期: 2026-06-23 起调查
> 状态: 🟡 间歇性,根因可能在 opencode 上游,本地未复现高频
> Owner: plugin (`Nook/Resources/opencode-plugin/index.js`) + adapter (`Nook/Services/Hooks/OpencodeHookAdapter.swift`)

## 症状

opencode session 的 chat history 末尾,reasoning block(bullet-pointed text)以"额外一段"的形式出现,而不是和对应 turn 的 text 一起正常内联。

## 关键事实(根因调查)

### opencode reasoning 生命周期

源码位置: `packages/opencode/src/session/processor.ts:117-151`

```
reasoning-start    → updatePart(text="")
reasoning-delta    → updatePartDelta(field=text, delta=...)
reasoning-end      → updatePart(text=<trimmed>)  ← 唯一带完整 text 的 part.updated
```

### cleanup() 兜底路径

源码位置: `packages/opencode/src/session/processor.ts:390-396`

opencode 在 session 终止/异常路径会遍历 `ctx.reasoningMap` 残留 entry,兜底 fire `updatePart`。这是 Bug J 间歇性出现的关键:

- 正常路径下 reasoning-end 会带完整 text
- 异常路径(被 cancel / retry / step 切换)下 `reasoningMap` entry 可能**在 cleanup() fire updatePart 之前就被移除**,导致 reasoning 永远没有 final-text → 我们 adapter 拿到的只是空 part + 后续 delta,没有 flush trigger

### 事件流

```
Session.updatePart
    ↓
SyncEvent.run(PartUpdated)
    ↓
sync/index.ts:142-158 把 SyncEvent 同时 publish 到标准 Bus
    ↓
插件 bus.subscribeAll() 收到 → event.type="message.part.updated"
    ↓
我们 adapter handlePartUpdated 处理
```

## 本地验证结论(2026-06-23 跑 2 个 task 9 段 reasoning)

全部正常 emit,没有出现 Bug J 症状。本地无法稳定复现,推测触发条件是 opencode 上游特定异常路径(cancel/retry/异常 step 切换)。

## 诊断 log 长期保留

**位置**: `OpencodeHookAdapter.swift` line 630 附近(DIAGNOSTIC #82)

**用法**: 复现 Bug J 时,grep `/tmp/nook-debug.log` 找 `→ part arrived type=reasoning` 看目标 messageID 有没有出现:

- **出现** → plugin 收到了但 handler 漏了(不太可能,需要查 handlePartUpdated 的 reasoning 路径)
- **没出现** → opencode cleanup() 没 fire 这条的 updatePart,根因在 opencode 上游

## 兜底方案(暂未实现)

如果 Bug J 以后高频复现,需要在 handler 加 **"新 reasoning-start 触发老 reasoning flush"**:

```swift
// 伪代码,不是现状
func handleReasoningStart(messageId: String) {
    // 如果有上一段未 flush 的 reasoning,先 emit
    if let pendingMessageId = oldestPendingReasoning,
       pendingMessageId != messageId {
        emit .assistantThinking(text: buffered[pendingMessageId] ?? "")
    }
}
```

**当前不实现** — 没复现场景,加这个会引入"提前 flush 边界条件",反而可能引入新 bug。

## 相关代码位置

- Plugin 端: `Nook/Resources/opencode-plugin/index.js`
- Adapter reasoning 处理: `OpencodeHookAdapter.swift` line 620-650 (`case "reasoning"` in handlePartUpdated)
- 诊断 log: `OpencodeHookAdapter.swift` line 630 (`#82` TODO)
- flushOneMessageReasoning 调用点: `OpencodeHookAdapter.swift` line 598 (在 `handleMessageUpdated` 的 `finish=stop` 分支)

## 关联

- TODO(#82) 标记在 adapter 第 638 行
- PROGRESS.md "Bug J 调查关键事实"是本 spec 的早期版本,会随时间滚动