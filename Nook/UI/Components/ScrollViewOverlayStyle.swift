//
//  ScrollViewOverlayStyle.swift
//  Nook
//
//  Force NSScrollView's scroller style to `.overlay` (so the scrollbar
//  floats over content instead of reserving a 15pt gutter) and broadcast
//  the documentView's actual rendered height via NotificationCenter at
//  10Hz. The panel listens and resizes to match exactly — no buffer,
//  no slop, no 1pt drift.
//
//  `ScrollViewOverlayHelper.installIfNeeded()` walks the active window's
//  view tree directly to find the first NSScrollView. It is idempotent
//  and safe to call multiple times. SwiftUI's NSViewRepresentable was
//  tried first but proved unreliable when attached as a `.background()`
//  — the underlying NSView was never instantiated.
//

import SwiftUI
import AppKit

extension Notification.Name {
    /// UserInfo: ["height": CGFloat]
    static let scrollViewDidMeasureContent = Notification.Name("Nook.scrollViewDidMeasureContent")
}

enum ScrollViewOverlayHelper {
    private static var installed = false
    private static var timer: Timer?
    private static var lastBroadcastHeight: CGFloat? = nil

    static func installIfNeeded() {
        guard let scrollView = findScrollView() else { return }
        applyOverlayStyle(to: scrollView)
        broadcast(scrollView: scrollView)
        startTimer()
        installed = true
    }

    private static func findScrollView() -> NSScrollView? {
        if let win = NSApp.keyWindow ?? NSApp.mainWindow,
           let cv = win.contentView,
           let found = findScrollView(in: cv) {
            return found
        }
        for win in NSApp.windows {
            if let cv = win.contentView, let found = findScrollView(in: cv) {
                return found
            }
        }
        return nil
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    private static func applyOverlayStyle(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
    }

    private static func startTimer() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            // Re-find the scrollview each tick — SwiftUI may have
            // recreated it during layout. Keeps the overlay style
            // applied too, since SwiftUI resets it sometimes.
            guard let sv = findScrollView() else { return }
            if sv.scrollerStyle != .overlay {
                applyOverlayStyle(to: sv)
            }
            broadcast(scrollView: sv)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func broadcast(scrollView: NSScrollView) {
        guard let docView = scrollView.documentView else { return }
        let docHeight = docView.frame.size.height
        guard docHeight != lastBroadcastHeight else { return }
        lastBroadcastHeight = docHeight
        NotificationCenter.default.post(
            name: .scrollViewDidMeasureContent,
            object: nil,
            userInfo: ["height": docHeight]
        )
    }
}