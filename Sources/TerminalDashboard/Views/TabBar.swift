import Foundation
import SwiftTUI

// MARK: - TabBar

/// A single fixed-height row rendered at the top of the terminal in auto mode.
///
/// Layout:
///   [G] Git [badge]   [C] Crashes [badge]   [L] Logs [badge]   <Spacer>   <banner | AUTO indicator>
///
/// - Active tab: bold
/// - Inactive tab badge: yellow dot(s)
/// - AUTO indicator: bright green when active, gray when suspended
/// - Banner: yellow, replaces AUTO indicator during countdown
struct TabBar: View {

    let activeView: DashboardSource
    let badgeCounts: [DashboardSource: Int]
    let isAutoMode: Bool
    let bannerMessage: String?

    var body: some View {
        HStack(spacing: 1) {
            tabItem(source: .git, shortcut: "G", label: "Git")
            tabItem(source: .crashes, shortcut: "C", label: "Crashes")
            tabItem(source: .logs, shortcut: "L", label: "Logs")
            Spacer()
            rightSlot
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Tab items

    private func tabItem(source: DashboardSource, shortcut: String, label: String) -> some View {
        let isActive = source == activeView
        let badge = badgeCounts[source] ?? 0
        return HStack(spacing: 0) {
            tabLabel(shortcut: shortcut, label: label, isActive: isActive)
            badgeView(count: badge, isActive: isActive)
        }
    }

    private func tabLabel(shortcut: String, label: String, isActive: Bool) -> some View {
        let title = "[\(shortcut)] \(label)"
        if isActive {
            return Text(title).bold()
        } else {
            return Text(title).bold(false)
        }
    }

    private func badgeView(count: Int, isActive: Bool) -> some View {
        let dots: String
        switch count {
        case 0:  dots = ""
        case 1:  dots = " ●"
        default: dots = " ●●"
        }
        // Badge is only shown when count > 0 and tab is not active
        if count > 0 && !isActive {
            return Text(dots).foregroundColor(.yellow)
        } else {
            return Text(dots).foregroundColor(.default)
        }
    }

    // MARK: - Right slot

    @ViewBuilder
    private var rightSlot: some View {
        if let banner = bannerMessage {
            Text(banner).foregroundColor(.yellow)
        } else {
            autoIndicator
        }
    }

    private var autoIndicator: some View {
        if isAutoMode {
            return Text("AUTO").foregroundColor(.brightGreen)
        } else {
            return Text("AUTO").foregroundColor(.gray)
        }
    }
}
