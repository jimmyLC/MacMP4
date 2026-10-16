import SwiftUI
import AppKit

extension AppAccess {
    var preferredColorScheme: ColorScheme? {
        switch effectiveAppearance {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    /// Also keeps native file panels and AppKit controls consistent with the workspace.
    func applyNativeAppearance() {
        switch effectiveAppearance {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}

struct PlanBadge: View {
    let tier: AppTier
    var body: some View {
        Text(tier.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tier == .pro ? Color.blue : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tier == .pro ? Color.blue.opacity(0.10) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(tier == .pro ? Color.blue.opacity(0.25) : Color.primary.opacity(0.12), lineWidth: 1))
            .accessibilityLabel(tier == .pro ? L("Pro 版本") : L("Free 版本"))
    }
}

extension AppAppearance {
    var title: String {
        switch self {
        case .light: return L("淺色")
        case .dark: return L("深色")
        case .system: return L("跟隨系統")
        }
    }
    var subtitle: String {
        switch self {
        case .light: return L("明亮清楚的工作區")
        case .dark: return L("降低工作區亮度")
        case .system: return L("隨 macOS 外觀設定自動切換")
        }
    }
    var icon: String {
        switch self {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .system: return "circle.lefthalf.filled"
        }
    }
}

struct AppearanceView: View {
    @EnvironmentObject private var access: AppAccess
    @Environment(\.dismiss) private var dismiss
    @State private var showingProInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("外觀")).font(.title2.weight(.semibold))
                PlanBadge(tier: access.tier)
                Spacer()
            }
            Text(access.isPro ? L("選擇適合你的工作區外觀。") : L("Free 提供完整轉檔功能，使用淺色外觀。"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(AppAppearance.allCases, id: \.self) { appearance in
                    appearanceOption(appearance)
                    if appearance != .system { Divider().padding(.leading, 58) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            if !access.isPro {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Pro · NT$90 終身買斷")).font(.callout.weight(.semibold))
                    Text(L("包含 Pro 標誌、深色外觀與跟隨系統自動切換。Pro 升級即將開放。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 440)
        .alert(L("Pro 外觀功能"), isPresented: $showingProInfo) {
            Button(L("知道了"), role: .cancel) {}
        } message: {
            Text(L("深色與跟隨系統是 Pro 功能。Pro 為 NT$90 終身買斷，升級即將開放；轉檔功能維持免費。"))
        }
    }

    private func appearanceOption(_ appearance: AppAppearance) -> some View {
        let locked = !access.isPro && appearance != .light
        let selected = access.effectiveAppearance == appearance
        return Button {
            if !access.selectAppearance(appearance) { showingProInfo = true }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: appearance.icon)
                    .font(.system(size: 20, weight: .regular)).frame(width: 26)
                    .foregroundStyle(selected ? Color.blue : Color.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(appearance.title).font(.callout.weight(.medium))
                    Text(appearance.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if locked {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                } else if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .padding(15).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appearance.title)
        .accessibilityValue(locked ? L("Pro 功能，尚未解鎖") : selected ? L("已選取") : L("未選取"))
        .help(locked ? L("Pro 可使用此功能") : appearance.subtitle)
    }
}
