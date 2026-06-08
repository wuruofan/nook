//
//  OpencodeHookAdapter.swift
//  Nook
//
//  Translates raw OpenCode bus events (from the plugin socket) into the
//  normalised OpencodeSessionEvent surface that Nook's session store consumes.
//
//  Event model (reverse‑engineered from opencode v1.15.13 bus):
//    session.created        → sessionStart (legacy; current versions use session.updated)
//    session.updated        → sessionStart on first sighting; refreshes cwd afterwards
//    session.status         → stop on status.type == "idle"
//    session.idle           → stop (legacy)
//    message.updated        → user/assistant message boundary
//    message.part.updated   → user text, assistant text (initial empty), bash tool
//    message.part.delta     → assistant text streaming chunks (field=text)
//
//  Assistant text arrives via a chain:
//    message.part.updated(type=text, text="")   → initialise buffer for messageID
//    message.part.delta(field=text, delta=...)  → append chunks
//    message.updated(role=assistant, finish=stop) → flush buffer as .assistantText
//

import Foundation
import os.log

final class OpencodeHookAdapter: @unchecked Sendable {

    // MARK: - Diagnostic logging (temporary)

    nonisolated private static let log = Logger(subsystem: "com.celestial.Nook", category: "OpencodeAdapter")

    /// Mirrors `log.notice` to the on-disk debug log (when enabled) so
    /// hook activity is reproducible from a single file. The os_log
    /// call is kept because Console.app is still the most convenient
    /// view during development; the file mirror exists for field
    /// reports and AI-assisted debugging.
    fileprivate static func logNotice(_ message: String) {
        log.notice("\(message, privacy: .public)")
        DebugLog.shared.write("[opencode] " + message)
    }

    // MARK: - State

    private static var lock = NSLock()
    /// sessionID → cwd from session.created / session.updated
    private static var sessionCwd: [String: String] = [:]
    /// sessionID → messageID of the most recent user message awaiting its text part
    private static var latestUserMsgID: [String: String] = [:]
    /// messageID → accumulating assistant text (from message.part.delta chunks,
    /// or seeded by a non-empty message.part.updated(type=text) for v1.15.12-style events)
    private static var pendingTextByMessage: [String: String] = [:]
    /// messageID → accumulating reasoning / thinking text (from message.part.delta
    /// chunks with field=reasoning, seeded by a non-empty message.part.updated(type=reasoning))
    private static var pendingReasoningByMessage: [String: String] = [:]
    /// messageID → sessionID, so the session-idle safety net can flush only
    /// buffers belonging to the session that's going idle.
    private static var messageSession: [String: String] = [:]
    /// messageIDs whose assistant text has already been emitted as .assistantText
    private static var emittedTextMessages: Set<String> = []
    /// messageIDs whose assistant text should NEVER be emitted — these are
    /// the opencode `question` tool's parent messages. The question text is
    /// the prompt the user already sees in the opencode TUI when answering,
    /// and is meta-content rather than conversation flow. We mark the
    /// messageID as suppressed when `question.asked` arrives carrying
    /// `tool.messageID` (in `handleQuestionAsked` below) so both the
    /// `finish=stop` flush path and the `flushPendingText` safety net skip
    /// it. Without this the safety net would emit the question text at the
    /// END of the next turn — visibly out of order in the chat.
    private static var suppressedTextMessages: Set<String> = []
    /// messageIDs that have a reasoning part — set as soon as we see
    /// `message.part.updated type=reasoning` (even when the initial text is empty).
    /// Used by `handlePartDelta` to route opencode's `field="text"` reasoning-delta
    /// events into the reasoning buffer (opencode v1.15.13 emits reasoning-delta
    /// with `field: "text"`, see opencode/src/session/processor.ts:131-141).
    /// MUST stay separate from `emittedReasoningMessages` — adding a messageID here
    /// is a routing decision, not an emission, and would otherwise cause reasoning
    /// to be dropped (flush paths would see "already emitted" and return []).
    private static var knownReasoningMessageIds: Set<String> = []
    /// messageIDs whose reasoning text has already been emitted as .assistantThinking.
    /// Only set when we actually emit the event (at part-final-text in
    /// `handleReasoningPart`, or at flush time as a fallback). Prevents the
    /// duplicate-thinking bug where stop-time flushes re-emit the same content.
    private static var emittedReasoningMessages: Set<String> = []
    /// callIDs whose preTool has already been emitted (opencode fires
    /// status=running 2–3 times per tool; only the first should create a chat item).
    private static var runningToolCallIds: Set<String> = []
    /// child sessionID → parent sessionID. Populated when a `session.created` /
    /// `session.updated` event carries `info.parentID` — opencode creates a fresh
    /// session for every subagent (Task tool) and links it to the parent via this
    /// field (see opencode/src/tool/task.ts:75-76). We use it to keep the subagent
    /// out of the instance list and route its activity into the parent's chat view.
    private static var subagentToParent: [String: String] = [:]
    /// child sessionID → the parent session's `task` tool callID. Established when
    /// the parent's `preTool(tool=task)` arrives and the child session is already
    /// known; used to tag subsequent subagent tool events with the right task id.
    private static var subagentTaskToolId: [String: String] = [:]
    /// Reverse lookup: parent sessionID → child sessionID currently awaiting task id
    /// association. Lets the parent's `preTool(tool=task)` find the right child
    /// even when multiple subagents are spawned in quick succession.
    private static var parentAwaitingTask: [String: String] = [:]

    // MARK: - Public API

    /// Convert a raw envelope into zero or more tracked Nook events.
    /// Returns an empty array for events Nook does not care about.
    static func adapt(_ envelope: OpencodeHookEnvelope) -> [OpencodeSessionEvent] {
        guard envelope.origin == "opencode" else { return [] }
        let props = envelope.properties ?? [:]

        let sessionId = (props["sessionID"]?.value as? String) ?? "?"
        let role: String
        if let info = props["info"]?.value as? [String: Any] {
            role = (info["role"] as? String) ?? "?"
        } else {
            role = "-"
        }
        let partType: String
        let partText: String
        if let part = props["part"]?.value as? [String: Any] {
            partType = (part["type"] as? String) ?? "-"
            let t = (part["text"] as? String) ?? ""
            partText = String(t.prefix(40))
        } else {
            partType = "-"
            partText = ""
        }
        let partCallID: String
        if let part = props["part"]?.value as? [String: Any] {
            partCallID = (part["callID"] as? String) ?? "-"
        } else {
            partCallID = "-"
        }
        let partStatus: String
        if let part = props["part"]?.value as? [String: Any],
           let state = part["state"] as? [String: Any] {
            partStatus = (state["status"] as? String) ?? "-"
        } else {
            partStatus = "-"
        }
        let sessionStatus: String
        if let status = props["status"]?.value as? [String: Any],
           let t = status["type"] as? String {
            sessionStatus = t
        } else {
            sessionStatus = "-"
        }
        Self.logNotice("event type=\(envelope.type) session=\(sessionId) role=\(role) partType=\(partType) partStatus=\(partStatus) sessionStatus=\(sessionStatus) callID=\(partCallID) text=\(partText)")

        // Subagent routing: if this session is already registered as a child of
        // some parent, intercept here so we never let the child events reach the
        // per-session handlers (which would create a top-level SessionState).
        // The handlers below assume top-level sessions; subagent-specific
        // translation is done in `adaptSubagentEvent` and via direct
        // subagent-tool translation in `handleToolPart`.
        if let parentID = lookupParent(for: sessionId), parentID != sessionId {
            return adaptSubagentEvent(envelope: envelope, props: props, childId: sessionId, parentId: parentID)
        }

        switch envelope.type {
        case "session.created", "session.updated":
            return handleSessionCreatedOrUpdated(props)
        case "session.status":
            return handleSessionStatus(props)
        case "session.idle":
            return handleSessionIdle(props)
        case "question.asked":
            return handleQuestionAsked(props)
        case "message.updated":
            return handleMessageUpdated(props)
        case "message.part.updated":
            return handlePartUpdated(props)
        case "message.part.delta":
            return handlePartDelta(props)
        default:
            return []
        }
    }

    /// Read-only lookup that does NOT insert. We need to distinguish "this
    /// sessionId is a known child" (early in adapt, to route) from "we just
    /// discovered this child via session.created" (in handleSessionCreatedOrUpdated,
    /// to record the mapping). `subagentToParent[sessionId] != nil` is the
    /// single source of truth.
    private static func lookupParent(for sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return subagentToParent[sessionId]
    }

    /// Translate a subagent session's raw envelope into parent-scoped Nook
    /// events. Everything except tool events is dropped — subagent text and
    /// reasoning are not user-visible (see opencode/src/tool/task.txt:20: "The
    /// result returned by the agent is not visible to the user"), and the
    /// subagent's own user prompt is the task tool's input which the parent
    /// already receives via `preTool(tool=task)`.
    private static func adaptSubagentEvent(envelope: OpencodeHookEnvelope, props: [String: AnyCodable], childId: String, parentId: String) -> [OpencodeSessionEvent] {
        switch envelope.type {
        case "message.part.updated":
            // Tool parts are handled here so we can translate them into
            // subagentToolExecuted / subagentToolCompleted on the parent. Text
            // and reasoning parts are dropped.
            guard let part = props["part"]?.value as? [String: Any],
                  let partType = part["type"] as? String,
                  partType == "tool" else {
                return []
            }
            return handleSubagentToolPart(childId: childId, parentId: parentId, part: part)

        case "session.status", "session.idle":
            // Subagent session is going idle — flush any text/reasoning buffers
            // that were accidentally accumulated for the child (shouldn't happen
            // now that we route early, but the safety net is cheap and prevents
            // stale buffers from bleeding into the parent on next start).
            let cwd: String = {
                lock.lock()
                let v = sessionCwd[childId] ?? ""
                lock.unlock()
                return v
            }()
            let flushed = flushPendingText(forSession: childId, cwd: cwd)
            Self.logNotice("→ subagent stop routed to parent child=\(childId) parent=\(parentId) flushed=\(flushed.count)")
            return flushed

        default:
            return []
        }
    }

    /// Convert a subagent's tool part into a subagentToolExecuted /
    /// subagentToolCompleted event on the parent session. The tool's callID
    /// (scoped to the child's message stream) is preserved as the subagent
    /// tool id — SubagentToolCall has no cross-session id semantics.
    private static func handleSubagentToolPart(childId: String, parentId: String, part: [String: Any]) -> [OpencodeSessionEvent] {
        guard let toolName = part["tool"] as? String else { return [] }
        guard let state = part["state"] as? [String: Any] else { return [] }
        guard let status = state["status"] as? String else { return [] }
        // The Task tool itself is the parent-side event; the child never sees
        // its own task invocation, so this guard is just defensive.
        guard toolName != "task" else { return [] }

        let callId = part["callID"] as? String
        let input = state["input"] as? [String: Any]
        let inputSummary = buildInputSummary(toolName: toolName, input: input)

        switch status {
        case "running":
            Self.logNotice("→ subagentToolExecuted child=\(childId) parent=\(parentId) callID=\(callId ?? "-") tool=\(toolName) input=\(inputSummary)")
            // SubagentToolCall carries only what the chat UI needs; we keep the
            // callID so postTool status updates can be correlated. The
            // sessionId on the event is the parent's so SessionStore routes
            // through processSubagentToolExecuted's subagentState bookkeeping.
            return [.subagentToolExecuted(
                sessionId: parentId,
                tool: SubagentToolCall(
                    id: callId ?? "subagent-\(childId)-\(UUID().uuidString)",
                    name: toolName,
                    input: ["summary": inputSummary],
                    status: .running,
                    timestamp: Date()
                )
            )]
        case "completed":
            guard let callId else {
                Self.logNotice("→ subagent tool completed without callID, skipping child=\(childId) tool=\(toolName)")
                return []
            }
            Self.logNotice("→ subagentToolCompleted child=\(childId) parent=\(parentId) callID=\(callId) tool=\(toolName)")
            return [.subagentToolCompleted(sessionId: parentId, toolId: callId, status: .success)]
        default:
            return []
        }
    }

    // MARK: - Session Handlers

    private static func handleSessionCreatedOrUpdated(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        let info = props["info"]?.value as? [String: Any]
        let cwd = info?["directory"] as? String ?? ""
        // opencode sets `parentID` on every session created via the Task tool
        // (see opencode/src/tool/task.ts:75-76). When present, this is a subagent
        // session — it must NOT be exposed as a top-level session in the instance
        // list, and its activity must be merged into the parent session's chat view.
        let parentID = info?["parentID"] as? String

        if let parentID, parentID != sessionId {
            lock.lock()
            let isFirstSighting = subagentToParent[sessionId] == nil
            subagentToParent[sessionId] = parentID
            // Track this child against the parent so the parent's subsequent
            // `preTool(tool=task)` can find the right child. The most recent
            // unscheduled child "wins" if multiple spawn in flight.
            parentAwaitingTask[parentID] = sessionId
            lock.unlock()
            Self.logNotice("→ subagent child registered session=\(sessionId) parent=\(parentID) cwd=\(cwd) firstSighting=\(isFirstSighting)")
            // Do NOT emit .sessionStart for the child — that would create a
            // standalone SessionState and surface it in ClaudeInstancesView.
            return []
        }

        lock.lock()
        let isNew = sessionCwd[sessionId] == nil
        sessionCwd[sessionId] = cwd
        lock.unlock()

        if isNew {
            Self.logNotice("→ sessionStart (first sighting) session=\(sessionId) cwd=\(cwd)")
            return [.sessionStart(sessionId: sessionId, cwd: cwd)]
        }
        Self.logNotice("→ session.updated (known) session=\(sessionId) cwd=\(cwd)")
        return []
    }

    private static func handleSessionStatus(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        guard let status = props["status"]?.value as? [String: Any] else { return [] }
        let type = status["type"] as? String ?? ""
        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()

        switch type {
        case "busy":
            Self.logNotice("→ processingStarted (session.status=busy) session=\(sessionId) cwd=\(cwd)")
            return [.processingStarted(sessionId: sessionId, cwd: cwd)]
        case "idle":
            // Safety net: flush any assistant text buffers that didn't get a finish=stop
            var events: [OpencodeSessionEvent] = flushPendingText(forSession: sessionId, cwd: cwd)
            events.append(.stop(sessionId: sessionId, cwd: cwd))
            Self.logNotice("→ stop session=\(sessionId) flushed=\(events.count - 1)")
            return events
        default:
            return []
        }
    }

    private static func handleSessionIdle(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()
        Self.logNotice("→ stop (legacy session.idle) session=\(sessionId)")
        return [.stop(sessionId: sessionId, cwd: cwd)]
    }

    private static func handleQuestionAsked(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()
        // opencode v1.15.13 fires `question.asked` exactly when the
        // ask_user_question dialog appears. From opencode's perspective the
        // session is still "busy" (session.status stays busy until the user
        // answers), so without this explicit signal the notch would keep
        // showing the orange processing indicator while the user is being
        // asked to pick an option.
        //
        // The event payload (opencode/src/question/index.ts:35-45, `Request`
        // schema) also carries `tool: { messageID, callID }` when the
        // question was invoked as a tool call — messageID is the parent
        // message whose text is the question prompt. We tag that messageID
        // as suppressed so its `assistantText` is dropped from the chat
        // history (the question prompt is meta-content the user already
        // sees in the opencode TUI; emitting it as chat text would show up
        // out-of-order at end of next turn). The opencode `question` tool
        // fires BOTH the standard preTool/postTool lifecycle (which creates
        // the visible chatItem via SessionStore, with kind=.askUserQuestion)
        // AND this separate `question.asked` event (the user-input signal).
        // The `question.asked` payload carries `tool.messageID` for the
        // parent — that's what we mark here so the parent's `assistantText`
        // is dropped before the safety-net flush has a chance to emit it.
        if let tool = props["tool"]?.value as? [String: Any],
           let messageId = tool["messageID"] as? String,
           !messageId.isEmpty {
            lock.lock()
            suppressedTextMessages.insert(messageId)
            lock.unlock()
            Self.logNotice("→ suppressed question parent text session=\(sessionId) messageID=\(messageId)")
        }
        Self.logNotice("→ waitingForUserInput (question.asked) session=\(sessionId) cwd=\(cwd)")
        return [.waitingForUserInput(sessionId: sessionId, cwd: cwd)]
    }

    // MARK: - Message Handlers

    private static func handleMessageUpdated(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        guard let info = props["info"]?.value as? [String: Any] else { return [] }
        let messageId = info["id"] as? String ?? ""
        guard !messageId.isEmpty else { return [] }
        let role = info["role"] as? String ?? ""
        let finish = info["finish"] as? String

        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()

        if role == "user" {
            // If the text part arrived first, the buffer holds the prompt.
            lock.lock()
            let buffered = pendingTextByMessage.removeValue(forKey: messageId) ?? ""
            lock.unlock()
            if !buffered.isEmpty {
                log.notice("→ userPromptSubmit (from buffer) session=\(sessionId) messageID=\(messageId) textChars=\(buffered.count)")
                return [.userPromptSubmit(sessionId: sessionId, cwd: cwd, prompt: buffered)]
            }
            // Otherwise, wait for the text part.
            lock.lock()
            latestUserMsgID[sessionId] = messageId
            lock.unlock()
            Self.logNotice("→ user message — waiting for text part session=\(sessionId) messageID=\(messageId)")
            return []
        }

        if role == "assistant" && finish == "stop" {
            // Flush the accumulated reasoning and text for this messageID.
            // Reasoning comes first so the chat view shows thinking above
            // the final assistant text.
            var events: [OpencodeSessionEvent] = []
            events.append(contentsOf: flushOneMessageReasoning(messageId: messageId, sessionId: sessionId, cwd: cwd, trigger: "finish=stop"))
            events.append(contentsOf: flushOneMessageText(messageId: messageId, sessionId: sessionId, cwd: cwd, trigger: "finish=stop"))
            return events
        }

        return []
    }

    private static func handlePartUpdated(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        guard let part = props["part"]?.value as? [String: Any] else { return [] }
        guard let partType = part["type"] as? String else { return [] }

        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()

        switch partType {
        case "text":
            return handleTextPart(sessionId: sessionId, cwd: cwd, part: part)
        case "reasoning":
            // Tag the messageID as reasoning at part creation, even when the
            // initial `text` is empty — streaming deltas arrive between
            // creation and final-text, and they need to be routed into the
            // reasoning buffer from the first one. handleReasoningPart
            // returns [] for the empty-text case but still does the work
            // for the final-text case (full reasoning emit).
            let messageId = part["messageID"] as? String ?? ""
            if !messageId.isEmpty {
                markReasoningMessageId(messageId, sessionId: sessionId)
            }
            return handleReasoningPart(sessionId: sessionId, cwd: cwd, part: part)
        case "tool":
            return handleToolPart(sessionId: sessionId, cwd: cwd, part: part)
        case "step-start":
            // Defensive backup: opencode v1.15.13 sometimes fires step-start
            // before any session.status=busy event (e.g. when the model is
            // thinking without a preceding tool). Emitting processingStarted
            // here ensures the notch shows "processing" during thinking.
            Self.logNotice("→ processingStarted (step-start) session=\(sessionId) cwd=\(cwd)")
            return [.processingStarted(sessionId: sessionId, cwd: cwd)]
        default:
            return []
        }
    }

    private static func handlePartDelta(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let messageId = props["messageID"]?.value as? String else { return [] }
        guard !messageId.isEmpty else { return [] }
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        guard let field = props["field"]?.value as? String else { return [] }
        guard field == "text" || field == "reasoning" else { return [] }
        guard let delta = props["delta"]?.value as? String else { return [] }
        guard !delta.isEmpty else { return [] }

        lock.lock()
        // opencode v1.15.13 emits `reasoning-delta` events with `field: "text"`
        // (see opencode/src/session/processor.ts:131-141), so the `field` value
        // alone can't distinguish reasoning content from assistant text. We
        // fall back to the messageID's known type: once `handleReasoningPart`
        // has seen a `message.part.updated(type=reasoning)` for this messageID,
        // any later delta for the same messageID is reasoning, regardless of
        // what `field` says. `knownReasoningMessageIds` is the routing-only
        // set (distinct from `emittedReasoningMessages` which tracks actual
        // emit history for dedup at flush time).
        let isKnownReasoning = knownReasoningMessageIds.contains(messageId)
        if isKnownReasoning || field == "reasoning" {
            pendingReasoningByMessage[messageId, default: ""] += delta
        } else {
            pendingTextByMessage[messageId, default: ""] += delta
        }
        messageSession[messageId] = sessionId
        lock.unlock()
        return []
    }

    // MARK: - Text / Tool Part Handlers

    private static func handleTextPart(sessionId: String, cwd: String, part: [String: Any]) -> [OpencodeSessionEvent] {
        let messageId = part["messageID"] as? String ?? ""
        let text = part["text"] as? String ?? ""
        guard !messageId.isEmpty else { return [] }

        // User text — flush the pending user message we recorded in handleMessageUpdated
        lock.lock()
        let pendingMsgID = latestUserMsgID[sessionId]
        lock.unlock()
        if pendingMsgID == messageId, !text.isEmpty {
            lock.lock()
            latestUserMsgID.removeValue(forKey: sessionId)
            lock.unlock()
            Self.logNotice("→ userPromptSubmit (text part matched) session=\(sessionId) messageID=\(messageId) textChars=\(text.count)")
            return [.userPromptSubmit(sessionId: sessionId, cwd: cwd, prompt: text)]
        }

        // Assistant text — seed the buffer with any non-empty initial text.
        // In v1.15.13 the initial part is empty and content arrives via deltas.
        // In v1.15.12 the full text is in this event and deltas don't fire.
        if !text.isEmpty {
            lock.lock()
            pendingTextByMessage[messageId] = text
            messageSession[messageId] = sessionId
            lock.unlock()
        }
        return []
    }

    private static func handleReasoningPart(sessionId: String, cwd: String, part: [String: Any]) -> [OpencodeSessionEvent] {
        let messageId = part["messageID"] as? String ?? ""
        let text = part["text"] as? String ?? ""
        guard !messageId.isEmpty else { return [] }

        // v1.15.13 reasoning part lifecycle:
        //   message.part.updated(type=reasoning, text="")  → creation
        //   message.part.delta(field=text, delta=…)        → streaming chunks
        //     (opencode emits `field: "text"` for reasoning deltas too; the
        //      only reliable signal is the partType seen at part creation)
        //   message.part.updated(type=reasoning, text=…)   → final full text
        //
        // Tagging the messageID as a "known reasoning" messageID at creation
        // (in `markReasoningMessageId`, called from handlePartUpdated) ensures
        // the deltas route to the reasoning buffer. The dedup set
        // `emittedReasoningMessages` is NOT touched here — see comment in
        // `markReasoningMessageId` for why early tagging there would drop the
        // emit at final-text and at stop-time flush.

        // The final-text event fires AFTER all deltas complete and BEFORE the
        // next step in the turn (tool pending, text part, etc.). Emitting
        // .assistantThinking here lands the thinking block at the right
        // position in chatItems — before any subsequent tool/text rather than
        // clustered at the end via finish=stop. The emittedReasoningMessages
        // dedup set prevents the finish=stop / safety-net flushes from
        // re-emitting the same content.
        guard !text.isEmpty else { return [] }

        lock.lock()
        let alreadyEmitted = emittedReasoningMessages.contains(messageId)
        pendingReasoningByMessage[messageId] = text
        messageSession[messageId] = sessionId
        if !alreadyEmitted {
            emittedReasoningMessages.insert(messageId)
        }
        lock.unlock()

        if alreadyEmitted { return [] }
        Self.logNotice("→ assistantThinking (final) session=\(sessionId) messageID=\(messageId) textChars=\(text.count)")
        return [.assistantThinking(sessionId: sessionId, cwd: cwd, text: text)]
    }

    /// Tag a messageID as a reasoning message as soon as the reasoning part
    /// is created (empty-text `message.part.updated type=reasoning`). This
    /// must happen BEFORE the first `message.part.delta` for the same
    /// messageID, otherwise the deltas — which all carry `field: "text"` in
    /// opencode v1.15.13 — are routed into `pendingTextByMessage` and
    /// re-emitted as assistantText on `session.idle` (the duplicate-thinking
    /// bug the user reported).
    ///
    /// IMPORTANT: This only adds to `knownReasoningMessageIds` (a routing
    /// signal). It does NOT mark the message as "already emitted" — that
    /// would cause the actual `.assistantThinking` emit at final-text time
    /// and the stop-time safety-net flush to both short-circuit, dropping
    /// the reasoning content entirely.
    private static func markReasoningMessageId(_ messageId: String, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        if !knownReasoningMessageIds.contains(messageId) {
            knownReasoningMessageIds.insert(messageId)
            Self.logNotice("→ reasoning messageId tagged early session=\(sessionId) messageID=\(messageId)")
        }
    }

    private static func handleToolPart(sessionId: String, cwd: String, part: [String: Any]) -> [OpencodeSessionEvent] {
        guard let toolName = part["tool"] as? String else { return [] }
        guard let state = part["state"] as? [String: Any] else { return [] }
        guard let status = state["status"] as? String else { return [] }

        // The opencode `question` tool IS rendered as a chatItem — the user
        // wants to see the question + answer between the surrounding thinking
        // blocks (matching opencode TUI behavior). The "red box" bug came
        // from the *parent message's assistant text* (the model says "OK let
        // me ask" → tool call → user answers → model continues), not from
        // the tool chatItem itself. The parent text is suppressed in
        // `handleQuestionAsked` via `suppressedTextMessages`, NOT here.
        //
        // Falling through to the standard preTool / postTool path below lets
        // SessionStore create a `ToolCallItem(kind: .askUserQuestion)` for
        // the question with its input (the questions list) and result
        // ("User has answered your questions: …") — the same shape the user
        // sees in opencode TUI's "# Questions" block.

        let callId = part["callID"] as? String
        let input = state["input"] as? [String: Any]
        let inputSummary = Self.buildInputSummary(toolName: toolName, input: input)

        // Task tool on the parent side — this is the bridge between a parent
        // session and the child subagent session it just spawned. At this
        // point the child is already registered in `subagentToParent` (the
        // child's session.created event arrived a few ms before this preTool;
        // see debug log around the first task invocation). We associate the
        // task call id with the child and emit a subagentStarted event so
        // SessionStore can wire up subagentState tracking. The preTool itself
        // is also emitted (in the return tuple below) so SessionStore's normal
        // task container path still runs — that path is what creates the
        // visible "task" chatItem and populates its description/input.
        if toolName == "task", let callId, status == "running" {
            let (childId, wasNewlyLinked) = associateTaskWithChild(parentId: sessionId, taskToolId: callId)
            Self.logNotice("→ task preTool session=\(sessionId) callID=\(callId) child=\(childId ?? "<none>") newlyLinked=\(wasNewlyLinked)")
            let pre: OpencodeSessionEvent = .preTool(
                sessionId: sessionId, cwd: cwd,
                toolName: toolName, toolUseId: callId, inputSummary: inputSummary
            )
            if let childId, wasNewlyLinked {
                return [.subagentStarted(sessionId: sessionId, taskToolId: callId), pre]
            }
            return [pre]
        }
        if toolName == "task", let callId, status == "completed" {
            if let childId = disassociateTaskFromChild(parentId: sessionId, taskToolId: callId) {
                Self.logNotice("→ task postTool session=\(sessionId) callID=\(callId) child=\(childId) → subagentStopped")
                // The task postTool is the parent's signal that the subagent
                // is done. Emit both subagentStopped (so subagentState can
                // stop tracking) and postTool (so the visible task chatItem
                // transitions from running → success and gets the final result).
                return [
                    .subagentStopped(sessionId: sessionId, taskToolId: callId),
                    .postTool(
                        sessionId: sessionId, cwd: cwd,
                        toolName: toolName, toolUseId: callId, inputSummary: inputSummary
                    )
                ]
            }
        }

        // Dedup keyed on callID. opencode fires status=running 2-3 times per tool
        // (once at start, then for metadata updates). Without this we create
        // 2-3 chatItems for the same call and one of them ends up "Interrupted"
        // at session.idle because only one postTool ever fires.
        if let callId {
            lock.lock()
            defer { lock.unlock() }
            switch status {
            case "running":
                if runningToolCallIds.contains(callId) {
                    // Second+ running event: opencode may now carry actual input
                    // (first event often has empty input for non-Bash tools).
                    // Emit preTool again so SessionStore can update the chat item.
                    log.notice("→ preTool (input update) session=\(sessionId) callID=\(callId) tool=\(toolName) input=\(inputSummary)")
                } else {
                    runningToolCallIds.insert(callId)
                    log.notice("→ preTool session=\(sessionId) callID=\(callId) tool=\(toolName) input=\(inputSummary)")
                }
            case "completed":
                guard runningToolCallIds.contains(callId) else {
                    log.notice("→ postTool for unknown callID, skipping session=\(sessionId) callID=\(callId)")
                    return []
                }
                runningToolCallIds.remove(callId)
                log.notice("→ postTool session=\(sessionId) callID=\(callId) tool=\(toolName)")
            default:
                return []
            }
        } else {
            Self.logNotice("→ tool part with no callID, passing through session=\(sessionId) tool=\(toolName) status=\(status)")
        }

        switch status {
        case "running":
            return [.preTool(
                sessionId: sessionId, cwd: cwd,
                toolName: toolName, toolUseId: callId, inputSummary: inputSummary
            )]
        case "completed":
            return [.postTool(
                sessionId: sessionId, cwd: cwd,
                toolName: toolName, toolUseId: callId, inputSummary: inputSummary
            )]
        default:
            return []
        }
    }

    /// Link a parent's `task` tool call to the most recently registered child
    /// session awaiting association. Returns the child id and whether the link
    /// was newly created (true) or already existed (false). When false, the
    /// caller should NOT re-emit subagentStarted — the subagent is already
    /// tracked, possibly from a prior preTool with the same callID.
    private static func associateTaskWithChild(parentId: String, taskToolId: String) -> (childId: String?, wasNewlyLinked: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let childId = parentAwaitingTask[parentId] else {
            return (nil, false)
        }
        if subagentTaskToolId[childId] == taskToolId {
            return (childId, false)
        }
        subagentTaskToolId[childId] = taskToolId
        parentAwaitingTask.removeValue(forKey: parentId)
        return (childId, true)
    }

    /// Reverse of `associateTaskWithChild`. Returns the child id if it was
    /// still associated with this task, and clears the mapping so subsequent
    /// subagent events for the same child id can no longer be misrouted.
    private static func disassociateTaskFromChild(parentId: String, taskToolId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        // Walk all known children of this parent. The number of concurrent
        // subagents is tiny (handful at most) so the linear scan is fine.
        for (childId, mappedTask) in subagentTaskToolId {
            guard mappedTask == taskToolId else { continue }
            guard subagentToParent[childId] == parentId else { continue }
            subagentTaskToolId.removeValue(forKey: childId)
            subagentToParent.removeValue(forKey: childId)
            parentAwaitingTask.removeValue(forKey: parentId)
            return childId
        }
        return nil
    }

    // MARK: - Helpers

    private static func buildInputSummary(toolName: String, input: [String: Any]?) -> String {
        guard let input, !input.isEmpty else { return toolName }
        let lower = toolName.lowercased()
        if lower == "bash", let cmd = input["command"] as? String { return cmd }
        if let filePath = input["file_path"] as? String ?? input["filePath"] as? String { return filePath }
        if let name = input["name"] as? String { return name }
        if let pattern = input["pattern"] as? String { return pattern }
        if let prompt = input["prompt"] as? String { return String(prompt.prefix(60)) }
        if let desc = input["description"] as? String { return String(desc.prefix(60)) }
        if let query = input["query"] as? String { return String(query.prefix(60)) }
        if let content = input["content"] as? String { return String(content.prefix(60)) }
        return toolName
    }

    /// Flush one message's text buffer as a single .assistantText event.
    /// Also flushes that message's reasoning first, ensuring thinking appears
    /// above the corresponding text in the chat view.
    /// Used when `message.updated role=assistant finish=stop` arrives.
    private static func flushOneMessageText(messageId: String, sessionId: String, cwd: String, trigger: String) -> [OpencodeSessionEvent] {
        var events: [OpencodeSessionEvent] = []

        // Flush this message's reasoning first so thinking appears above text
        lock.lock()
        let reasoning = pendingReasoningByMessage.removeValue(forKey: messageId) ?? ""
        let reasoningEmitted = emittedReasoningMessages.contains(messageId)
        if !reasoning.isEmpty && !reasoningEmitted {
            emittedReasoningMessages.insert(messageId)
        }
        lock.unlock()
        if !reasoning.isEmpty && !reasoningEmitted {
            Self.logNotice("→ assistantThinking (pre-text) session=\(sessionId) messageID=\(messageId) textChars=\(reasoning.count)")
            events.append(.assistantThinking(sessionId: sessionId, cwd: cwd, text: reasoning))
        }

        // Then flush the text
        lock.lock()
        let text = pendingTextByMessage.removeValue(forKey: messageId) ?? ""
        let alreadyEmitted = emittedTextMessages.contains(messageId)
        let isSuppressed = suppressedTextMessages.contains(messageId)
        if !text.isEmpty && !alreadyEmitted && !isSuppressed {
            emittedTextMessages.insert(messageId)
        }
        lock.unlock()

        guard !text.isEmpty, !alreadyEmitted else {
            Self.logNotice("→ assistant nothing-to-flush session=\(sessionId) messageID=\(messageId) trigger=\(trigger) textChars=\(text.count) alreadyEmitted=\(alreadyEmitted)")
            return events
        }
        if isSuppressed {
            // The opencode `question` tool's parent message — its text is the
            // question prompt the user already saw in the TUI. Drop it here
            // and let the chat history skip straight from prior content to
            // the next non-question turn, instead of having the question
            // appear out of order at the end of the next turn.
            Self.logNotice("→ assistant text suppressed (question tool parent) session=\(sessionId) messageID=\(messageId) textChars=\(text.count) trigger=\(trigger)")
            return events
        }
        Self.logNotice("→ assistantText session=\(sessionId) messageID=\(messageId) textChars=\(text.count) trigger=\(trigger)")
        events.append(.assistantText(sessionId: sessionId, cwd: cwd, text: text))
        return events
    }

    /// Flush one message's reasoning buffer as a single .assistantThinking event.
    /// Symmetric to flushOneMessageText but for the reasoning pipeline.
    private static func flushOneMessageReasoning(messageId: String, sessionId: String, cwd: String, trigger: String) -> [OpencodeSessionEvent] {
        lock.lock()
        let text = pendingReasoningByMessage.removeValue(forKey: messageId) ?? ""
        let alreadyEmitted = emittedReasoningMessages.contains(messageId)
        if !text.isEmpty && !alreadyEmitted {
            emittedReasoningMessages.insert(messageId)
        }
        lock.unlock()

        guard !text.isEmpty, !alreadyEmitted else {
            return []
        }
        Self.logNotice("→ assistantThinking session=\(sessionId) messageID=\(messageId) textChars=\(text.count) trigger=\(trigger)")
        return [.assistantThinking(sessionId: sessionId, cwd: cwd, text: text)]
    }

    /// Flush all pending assistant text and reasoning buffers for a session
    /// (safety net for missed finish=stop events, e.g. on session idle).
    ///
    /// Candidates are sorted by messageID before iteration. opencode
    /// messageIDs embed a creation-time prefix, so lexicographic order is
    /// monotonic and gives a stable, near-chronological ordering for late
    /// arrivals. Without the sort, the safety net would dump messages in
    /// arbitrary Dictionary iteration order, scrambling the chat view.
    private static func flushPendingText(forSession sessionId: String, cwd: String) -> [OpencodeSessionEvent] {
        lock.lock()
        let textKeys = Set(pendingTextByMessage.keys)
        let reasoningKeys = Set(pendingReasoningByMessage.keys)
        let allMessageIds = textKeys.union(reasoningKeys).filter { msgId in
            messageSession[msgId] == sessionId
        }.sorted()
        lock.unlock()

        var events: [OpencodeSessionEvent] = []

        // Interleave reasoning + text per message so thinking appears above its text
        for messageId in allMessageIds {
            lock.lock()
            let reasoning = pendingReasoningByMessage.removeValue(forKey: messageId) ?? ""
            let reasoningEmitted = emittedReasoningMessages.contains(messageId)
            if !reasoning.isEmpty && !reasoningEmitted {
                emittedReasoningMessages.insert(messageId)
            }
            let text = pendingTextByMessage.removeValue(forKey: messageId) ?? ""
            let textEmitted = emittedTextMessages.contains(messageId)
            let textSuppressed = suppressedTextMessages.contains(messageId)
            // Mark the messageID as handled even when we drop it, so a
            // duplicate safety-net pass can't re-emit it. Without this
            // bookkeeping the drop path is silently re-evaluated on every
            // future session.idle and the bookkeeping drifts.
            if !text.isEmpty && !textEmitted {
                emittedTextMessages.insert(messageId)
            }
            messageSession.removeValue(forKey: messageId)
            lock.unlock()

            if !reasoning.isEmpty && !reasoningEmitted {
                Self.logNotice("→ assistantThinking (safety net) session=\(sessionId) messageID=\(messageId) textChars=\(reasoning.count)")
                events.append(.assistantThinking(sessionId: sessionId, cwd: cwd, text: reasoning))
            }
            if !text.isEmpty && !textEmitted && !textSuppressed {
                Self.logNotice("→ assistantText (safety net) session=\(sessionId) messageID=\(messageId) textChars=\(text.count)")
                events.append(.assistantText(sessionId: sessionId, cwd: cwd, text: text))
            } else if !text.isEmpty && textSuppressed {
                Self.logNotice("→ assistantText suppressed (safety net, question parent) session=\(sessionId) messageID=\(messageId) textChars=\(text.count)")
            }
        }
        return events
    }
}
