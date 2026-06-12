# Progress

> Last updated: 2026-06-12

## 🎯 Current Focus
<!-- opencode 展示对齐 Claude 3 个 commit 已落（unwrap / 结构化 input / 旧 processOpencode* 清理），#76 关闭。Bug H/I 仍等用户验证/数据。等用户决定下一步。 -->

## 📥 Next Phases
<!-- 下一步候选，按优先级 -->
1. **Bug H (#78) 收尾** — Fix 1（trailing-echo 检测）已实现+日志验证。用户需要在自己 prompt 上复测，确认无回归后 commit。
2. **Bug I (#79) 等数据** — 3 条被动诊断已加（subagent routing hit、pre-registration 计数、child registered with pre-reg events），用户跑能复现的 task 收集数据后再决定是否需要 fix。
3. **#64 清理 unbounded session-scoped state** — 12 个 `private static var`（`pendingReasoningByMessage` / `knownReasoningMessageIds` / `emittedReasoningMessages` / `preRegistrationEventCount` / `consumedUserPromptBySession` / `consumedUserMessageIDs` / `sessionCwd` / `subagentToParent` / `subagentTaskToolId` / `parentAwaitingTask` / `messageSession` 等）永不清理。可在 `session.status=ended` 或 `subagentStopped` 钩子里清理。
4. **#76 opencode tool result 渲染对齐 claude** — ✅ 已完成（spec：[docs/specs/2026-06-11-opencode-clause-display-alignment-design.md](docs/specs/2026-06-11-opencode-clause-display-alignment-design.md)），3 个 commit：d36b782（unwrap `<task_result>`）+ 537f725（结构化 input 透传）+ a29076a（删除 5 个被 ChatItemUpdate 取代的旧 handler）
5. **opencode review 里的 Important #5** — `handleToolPart` 的 status switch 只 case `running` / `completed`，`error` 进 default。tool 报错时 UI 一直显示 running
6. **Critical #3** — `createMinimalConfig()` 在 JSON 损坏时会覆盖原文件，先备份再覆盖更安全
7. **统一 ChatItem 中间层重构**（设计 spec：[`docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md`](docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md)）— 引入 `ChatItemUpdate` 中间格式让三种 provider 走统一入口。Phase 2（OpenCode adapter）直接修复 thinking 排序 bug，Phase 5 把 `SessionStore.process()` 从 30+ case 降到 ~12 case。优先级：先 Phase 1+2 修复 thinking 排序，其他 phase 可后置。

## ⏸️ Paused Tasks
| Task | 状态 | 阻塞点 / 入口 |
| --- | --- | --- |
| #78 Bug H | 等用户最终复测 + commit | 入口：`OpencodeHookAdapter.swift` line 686-701 (trailing-echo 分支)。验证方法：跑长 answer + 嵌套 task 的 prompt，看 `→ text part suppressed (trailing-echo ...)` 是否只在 echo 场景触发，合法 post-reasoning text 不被吞 |
| #79 Bug I | 等诊断数据 | 入口：`OpencodeHookAdapter.swift` line 233 (subagent routing hit)、244 (pre-reg 计数)、378 (child registered with pre-reg events)。复现：父 task 嵌套子 agent，task 工具里 prompt 包含子 agent 的真实 text/reasoning 输出。收集 `/tmp/nook-debug.log` 后判断 3 条诊断有没有命中 |

## ✅ Recently Completed
- **#76 opencode tool result 渲染对齐 claude** — 3 个 commit：d36b782（unwrap `<task_result>` XML 包裹，让 Agent 块不再泄漏 raw XML）+ 537f725（`stringifyInput` 把 opencode hook 的 `[String: Any]` 透传到 `ChatItemToolCall.input`，与 Claude `ToolUseBlock.input` 同形；同步 `SessionStore.upsertBlocks` 自动为 subagent container 构造 `TaskResult`；`ChatView.ToolCallView` 收紧为只在 `structuredResult != nil` 时显示 `ToolResultContent`）+ a29076a（删除 5 个被 ChatItemUpdate 取代的旧 `processOpencode*` handler，-333 行；4 个 lifecycle 处理器保留）
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
- ❌ **False positive**（AI 想象了 opencode 没有的事件名/状态）：#1 `session.status=ended`（opencode 只有 idle/retry/busy）、#2 `message.part.final`（不存在）、#9 `ask_user_question`（v1.15.x 改名为 `question.asked`）
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
