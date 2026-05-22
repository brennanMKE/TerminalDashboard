import Foundation
import SwiftTUI

// MARK: - HelpOverlay

/// A modal overlay that displays all available keyboard shortcuts.
///
/// Two modes:
///   - dedicated: shows only current-view actions (no navigation section)
///   - auto: shows navigation section + current-view actions
///
/// Any text entered in the command field followed by Return dismisses the overlay.
struct HelpOverlay: View {

    let isDedicatedMode: Bool
    let activeView: DashboardSource
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            Divider()
            modeSection
            Divider()
            currentViewSection
            dismissInputRow
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Title

    private var titleRow: some View {
        Text("Keyboard Shortcuts").bold()
    }

    // MARK: - Mode section

    @ViewBuilder
    private var modeSection: some View {
        if isDedicatedMode {
            dedicatedModeNote
        } else {
            navigationSection
        }
    }

    private var dedicatedModeNote: some View {
        Text("Running in dedicated mode — view switching disabled")
            .foregroundColor(.gray)
    }

    // MARK: - Navigation section (auto mode only)

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Navigation (terminal permitting)").bold().foregroundColor(.cyan)
            shortcutRow(key: "Cmd+Shift+G", description: "Switch to Git Status")
            shortcutRow(key: "Cmd+Shift+C", description: "Switch to Crashes")
            shortcutRow(key: "Cmd+Shift+L", description: "Switch to Logs")
            shortcutRow(key: "Cmd+Shift+A", description: "Toggle Auto Mode")
            shortcutRow(key: "Cmd+H",       description: "Toggle this help screen")
            shortcutRow(key: "q / Ctrl-C",  description: "Quit")
        }
    }

    // MARK: - Current view section

    private var currentViewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Current View: \(activeViewName)").bold().foregroundColor(.cyan)
            currentViewShortcuts
        }
    }

    private var activeViewName: String {
        switch activeView {
        case .git:     return "Git Status"
        case .crashes: return "Crashes"
        case .logs:    return "Logs"
        }
    }

    @ViewBuilder
    private var currentViewShortcuts: some View {
        switch activeView {
        case .git:
            shortcutRow(key: "p", description: "Push")
            shortcutRow(key: "u", description: "Pull")
            shortcutRow(key: "r", description: "Rebase")
            shortcutRow(key: "o", description: "Open in external tool")
        case .crashes:
            shortcutRow(key: "j / k",  description: "Navigate up/down")
            shortcutRow(key: "e",       description: "Extract selected")
            shortcutRow(key: "E",       description: "Extract all")
        case .logs:
            shortcutRow(key: "p / Space", description: "Pause/resume")
            shortcutRow(key: "c",          description: "Clear buffer")
        }
    }

    // MARK: - Shared row builder

    private func shortcutRow(key: String, description: String) -> some View {
        HStack(spacing: 1) {
            Text(key).foregroundColor(.yellow)
            Text("—")
            Text(description)
        }
    }

    // MARK: - Dismiss input

    private var dismissInputRow: some View {
        HStack(spacing: 1) {
            Text("Press any key + Return to dismiss").foregroundColor(.gray)
            TextField(placeholder: "") { _ in
                onDismiss()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
