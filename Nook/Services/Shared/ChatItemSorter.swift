//
//  ChatItemSorter.swift
//  Nook
//
//  Sorts chat items using provider-specific BlockOrdering keys.
//  Replaces naive append-order with logical ordering based on the
//  provider's data model (file position, message-relative, or timestamp).
//
//  Design spec: docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md
//

import Foundation

// MARK: - ChatItemSorter

enum ChatItemSorter {
    /// Sort chat items using the stored ordering keys. Items without a
    /// stored ordering fall back to timestamp comparison.
    static func sorted(
        _ items: [ChatHistoryItem],
        orderings: [String: BlockOrdering]
    ) -> [ChatHistoryItem] {
        items.sorted { a, b in
            compare(
                orderings[a.id], orderings[b.id],
                fallbackA: a, fallbackB: b
            )
        }
    }

    private static func compare(
        _ a: BlockOrdering?, _ b: BlockOrdering?,
        fallbackA: ChatHistoryItem, fallbackB: ChatHistoryItem
    ) -> Bool {
        switch (a, b) {
        case (.filePosition(let mi1, let bi1), .filePosition(let mi2, let bi2)):
            return (mi1, bi1) < (mi2, bi2)
        case (.messageRelative(let m1, let p1, let b1), .messageRelative(let m2, let p2, let b2)):
            // opencode messageIDs have a monotonic creation-time prefix,
            // so lexicographic order is chronological.
            //
            // Within the same message, BlockTypePriority enforces causal
            // ordering (reasoning → action → response) regardless of
            // event arrival order. This mirrors opencode's own provider
            // adapter which reorders reasoning before tool_use at API
            // call time (see anomalyco/opencode PR #10474, commit e8d6d1c,
            // and issues #9364, #3077).
            //
            // blockIndex preserves insertion order within the same type
            // (e.g. multiple tool calls maintain their execution order).
            if m1 == m2 {
                if p1 != p2 { return p1.rawValue < p2.rawValue }
                return b1 < b2
            }
            return m1 < m2
        case (.timestamp(let t1), .timestamp(let t2)):
            return t1 < t2
        default:
            // Mixed ordering types or nil → fall back to timestamp
            return fallbackA.timestamp < fallbackB.timestamp
        }
    }
}

// MARK: - ChatItemIdFactory

/// Generates stable, provider-scoped IDs for chat items.
enum ChatItemIdFactory {
    /// Claude: based on JSONL message ID + block position (unchanged from existing scheme).
    static func claudeBlockId(messageId: String, typePrefix: String, blockIndex: Int) -> String {
        "\(messageId)-\(typePrefix)-\(blockIndex)"
    }

    /// OpenCode: based on message ID + logical block index (replaces timestamp-based IDs).
    static func opencodeBlockId(messageId: String, typePrefix: String, blockIndex: Int) -> String {
        "opencode-\(messageId)-\(typePrefix)-\(blockIndex)"
    }

    /// Codex: based on transcript line index or call_id (unchanged).
    static func codexBlockId(sessionId: String, lineIndex: Int) -> String {
        "codex-message-\(sessionId)-\(lineIndex)"
    }

    /// Fallback tool ID when no provider-specific ID is available.
    static func toolId(provider: SessionProvider, rawId: String?) -> String {
        rawId ?? "\(provider.rawValue)-tool-\(Int(Date().timeIntervalSince1970 * 1000))"
    }
}
