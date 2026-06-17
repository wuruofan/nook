# Progress

> Last updated: 2026-06-15

## 🎯 Current Focus
<!-- #64 state cleanup + tool error status 已完成。Bug H 待实战验证。Bug I 诊断已就位，race 未被证实。 -->

## 📥 Next Phases
<!-- 下一步候选，按优先级 -->
1. **Critical #3** — `createMinimalConfig()` 在 JSON 损坏时会覆盖原文件，先备份再覆盖更安全
2. **统一 ChatItem 中间层重构**（设计 spec：[`docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md`](docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md)）— 引入 `ChatItemUpdate` 中间格式让三种 provider 走统一入口。Phase 2（OpenCode adapter）直接修复 thinking 排序 bug，Phase 5 把 `SessionStore.process()` 从 30+ case 降到 ~12 case。优先级：先 Phase 1+2 修复 thinking 排序，其他 phase 可后置。

## ⏸️ Paused Tasks
| Task | 状态 | 阻塞点 / 入口 |
| --- | --- | --- |
| #78 Bug H | Fix 2 已 commit，等实战验证 | TrailingEchoDetector 覆盖 handleTextPart + handlePartDelta 两条路径。验证方法：等 bug 自然触发时检查日志是否有 `→ text part suppressed (trailing-echo)` 或 `→ text delta suppressed (trailing-echo accumulated)` |
| #79 Bug I | 诊断已就位，race 未被证实 | 3 条诊断 log 已部署。当前 opencode v1.15.13 下 `⚠ DIAG #79` 从未命中，`subagent routing HIT` 正常工作。保留诊断作为基线，暂不修复 |

## ✅ Recently Completed
- **#83 opencode v1.17.x question.asked 不存在** — `OpencodeHookAdapter.swift` 文件头 + `handleQuestionAsked` + `handleToolPart` 注释更新，明确标注：v1.15.13 报告的 `question.asked` 事件在 v1.17.x 不可达（plugin socket 日志只看到 `file.watcher.updated`）。v1.17.x 的 AskUserQuestion phase 改为从 `message.part.updated(type=tool, tool=question)` 在 `handleToolPart` 里推断（PRIMARY path），`handleQuestionAsked` 退化为 v1.15.13 forward-looking 代码（idempotent — 两条路径都 emit `.waitingForUserInput`）。代码无逻辑改动，只动注释 + 路径语义标注。
- **#64 清理 unbounded session-scoped state** — 新增 `cleanupState(forSession:)` 函数，在 `handleSessionStatus(idle)`、`handleSessionIdle`、子代理 `session.idle` 三处调用。清理 per-session dicts（sessionCwd/latestUserMsgID/consumedUserPromptBySession 等）、subagent dicts（subagentToParent/subagentTaskToolId 双向清理）、message-scoped dicts（通过 messageSession 反查过滤）。`runningToolCallIds` 保留不清理（keyed by callID，无 session 映射，但 bounded by active calls）。
- **handleToolPart error status** — `handleToolPart` 的 status switch 新增 `case "error"`：去重 switch 中移除 callID 并记录日志；事件产出 switch 中 emit `.postTool(output: nil, error: error)`；task tool 的 error 状态也触发 `subagentStopped`。
- **#78 Bug H Fix 2** — TrailingEchoDetector 重构：抽出 pure value type，exact match + length-bounded Levenshtein 替代 substring 匹配；覆盖 handlePartDelta 的 delta 路径（Fix 1 只覆盖 handleTextPart）；system-reminder 修正（第一个 text part 是 `<system-reminder>` 时允许第二个 text part 覆盖）；Levenshtein 计算移到 lock 外避免阻塞事件循环；`min(a,b,c)` 改为嵌套 `min(min(a,b),c)`；delta 路径长度上限改为 `max(pTrim.count + 10, pTrim.count * 2)`
- **#76 opencode tool result 渲染对齐 claude** — 3 个 commit：d36b782（unwrap `<task_result>`）+ 537f725（结构化 input 透传）+ a29076a（删除 5 个被 ChatItemUpdate 取代的旧 handler）
- **#82 Bug J** — 推理块出现在 chat 末尾（bullet-pointed text）。根因调查：opencode v1.15.13 偶发漏发 `reasoning-end` 事件，但 `cleanup()`（`processor.ts:390-396`）会兜底 fire `updatePart` 触发 `message.part.updated` 走 plugin → 我们 handler 正常 emit。Bug J 间歇性，本轮跑 2 个 task 9 段 reasoning 全部正常内联 emit。本地验证方法：诊断 log 保留长期。
- **f139350** — `chore(opencode): document unbounded session-scoped state`（已 commit）
- **6c56af0** — `feat(opencode): full event stream + subagent routing`（已 commit）
- **Bug A–F 全部修复完成**（#70–#75）

## 🧱 Blockers & Issues
- **Bug J 是 opencode 上游 bug**，不是我们 plugin。opencode v1.15.13 在某些边界条件（cancel/retry/异常 step 切换）下 `reasoningMap` 中的 entry 可能在 cleanup() fire `updatePart` 之前就被移除（具体路径未深挖）。我们这边处理没问题，但若以后高频复现，需要在 handler 加 "新 reasoning-start 触发老 reasoning flush" 的兜底。当前不实现——没复现场景。
- **SourceKit false positives**：`DebugLog` / `OpencodeHookEnvelope` / `AnyCodable` / `OpencodeSessionEvent` 等类型 SourceKit 报 "Cannot find ... in scope"。xcodebuild 实际通过。是跨文件引用的已知问题，忽略。
- **task 列表历史**：会话中已 working through 17 个 bug/task（#60-#82），#78 / #79 / #64 / #76 还活着。

## 🧠 Context Notes
### Bug J 调查关键事实
1. opencode reasoning 生命周期在 `packages/opencode/src/session/processor.ts:117-151`：
   - `reasoning-start` → `updatePart(text="")`
   - `reasoning-delta` → `updatePartDelta(field=text, delta=...)`
   - `reasoning-end` → `updatePart(text=<trimmed>)`（**唯一带完整 text 的 part.updated**）
   - `cleanup()` line 390-396：遍历 `ctx.reasoningMap` 残留 entry 兜底 fire `updatePart`
2. 事件流：`Session.updatePart` → `SyncEvent.run(PartUpdated)` → `sync/index.ts:142-158` 把 SyncEvent 同时 publish 到标准 Bus → 插件 `bus.subscribeAll()` 收到 → `event.type="message.part.updated"` → 我们 adapter `handlePartUpdated` 处理
3. 诊断 log 长期保留：`OpencodeHookAdapter.swift` line 581。复现 Bug J 时直接 grep `→ part arrived type=reasoning` 看目标 messageID 有没有出现，出现 → plugin 收到了但 handler 漏了（不太可能）；没出现 → opencode cleanup() 没 fire 这条的 updatePart

### opencode review 11 项核查结果
- ❌ **False positive**（AI 想象了 opencode 没有的事件名/状态）：#1 `session.status=ended`（opencode 只有 idle/retry/busy）、#2 `message.part.final`（不存在）、#9 `ask_user_question`（v1.15.x 改名为 `question.asked` — **但 2026-06-17 验证 v1.17.x 也不发 `question.asked`，连这个名字的事件都不存在**，见 #83）
- ⚠️ **半真**：#3 `createMinimalConfig()` 仅在 JSON 损坏时覆盖，加个备份就好
- ✅ **真**：#4 内存泄漏（=#64）、#5 tool error 进 default、#8 subagent 预注册竞态（=#79）
- 🔍 **待查**：#6 / #7 / #10 / #11 在 SessionStore / HookSocketServer 里

### 设计原则
用户原话："opencode provider 是新加入的，像 claude provider 展示效果看起，这几个 bug 的修复都是这一个原则" —— opencode 行为要对齐 claude：子代理 reasoning/text 不下沉到 chat，tool calls promoted 到 Task 工具的 subagentTools 容器

## ⚡ Quick Recovery
- **branch**: `feat/agent-hooks`
- **主战场文件**:
  - `Nook/Services/Hooks/OpencodeHookAdapter.swift`（核心事件路由 + 处理）
  - `Nook/Services/Hooks/OpencodeHookModels.swift`（envelope / event 类型）
  - `Nook/Services/State/SessionStore.swift`（chatItems 状态机）
  - `Nook/Resources/opencode-plugin/index.js`（opencode 端 forward 到 Unix socket）
  - `Nook/Services/Hooks/HookSocketServer.swift`（Unix socket 接收）
- **诊断日志**：`/tmp/nook-debug.log`（设置面板有 toggle，#60 commit 加的）
- **关键 commit 参考**:
  - `a29076a` — `chore(opencode): remove dead processOpencode* code superseded by ChatItemUpdate`
  - `537f725` — `refactor(opencode): pass structured tool input for display alignment with Claude`
  - `d36b782` — `fix(opencode): strip task_result XML wrapping from Agent tool output`
  - `f139350` — 状态泄漏文档
  - `6c56af0` — 完整事件流 + subagent routing
  - `c51f607` — suppress question tool parent text
  - `4c56af0`(?) — `feat: opencode hooks integration via plugin-based event forwarding` (038bbb6)
- **opencode 本地源码**: `/Users/wuruofan/mine/rfw/opencode/`（v1.15.13）

## 🏛️ Archive Links
（暂无。完成 #78 后建议 archive。）
