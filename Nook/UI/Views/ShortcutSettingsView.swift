//
//  ShortcutSettingsView.swift
//  Nook
//
//  Settings page for configuring keyboard shortcuts
//

import SwiftUI
import Combine

struct ShortcutSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color
    @StateObject private var store = ShortcutStore.shared
    @State private var recordingAction: ShortcutAction?
    @State private var showResetConfirmation = false
    @State private var conflictFlash: ShortcutAction?
    private var cancellables = Set<AnyCancellable>()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                // Back button
                MenuRow(
                    icon: "chevron.left",
                    label: "Back",
                    primaryTextColor: primaryTextColor
                ) {
                    viewModel.navigateBack()
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // Tip
                Text("Tap a shortcut to record \u{00B7} Backspace to remove")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                // Action rows
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    ShortcutRow(
                        action: action,
                        primaryTextColor: primaryTextColor,
                        secondaryTextColor: secondaryTextColor,
                        store: store,
                        recordingAction: $recordingAction,
                        onConflict: { conflicting in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                conflictFlash = conflicting
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                withAnimation { conflictFlash = nil }
                            }
                        }
                    )
                    .overlay(
                        conflictFlash == action
                            ? RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red.opacity(0.6), lineWidth: 1)
                            : nil
                    )
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // Reset button
                Button {
                    showResetConfirmation = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                            .foregroundColor(secondaryTextColor)
                            .frame(width: 16)

                        Text("Restore Defaults")
                            .font(.system(size: 12))
                            .foregroundColor(secondaryTextColor)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .alert("Restore Default Shortcuts?", isPresented: $showResetConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Restore", role: .destructive) {
                        store.resetToDefaults()
                    }
                } message: {
                    Text("This will reset all keyboard shortcuts to their default values.")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: recordingAction) { _, newValue in
            ShortcutManager.shared.isRecording = (newValue != nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutKeyDown)) { notification in
            handleKeyDown(notification)
        }
    }

    private func handleKeyDown(_ notification: Notification) {
        guard let event = notification.object as? NSEvent,
              let recording = recordingAction else { return }

        let combo = KeyCombination.from(event: event)

        // Esc during recording — cancel
        if combo.keyCode == 53 {
            recordingAction = nil
            return
        }

        // Backspace — remove last combination
        if combo.keyCode == 51 {
            store.removeLastCombination(from: recording)
            recordingAction = nil
            return
        }

        // Add combination
        let success = store.addCombination(combo, to: recording)
        if success {
            recordingAction = nil
        } else {
            // Conflict — flash and stay in recording mode
            if let conflict = store.findConflict(combo) {
                conflictFlash = conflict
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation { conflictFlash = nil }
                }
            }
        }
    }
}
