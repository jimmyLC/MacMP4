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

struct SuperThanksIcon: View {
    var size: CGFloat = 24
    var body: some View {
        Image(systemName: "heart.fill")
            .resizable().scaledToFit()
            .overlay {
                Text("$")
                    .font(.system(size: size * 13 / 24, weight: .heavy, design: .rounded))
                    .blendMode(.destinationOut)
                    .offset(y: -size / 24)
            }
            .compositingGroup()
            .frame(width: size, height: size * 23 / 24)
            .accessibilityHidden(true)
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
    @State private var showingPurchase = false

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
                    Label {
                        Text(L("超級感謝"))
                    } icon: {
                        SuperThanksIcon()
                    }.font(.callout.weight(.semibold))
                    Text(L("Pro · NT$90 終身買斷")).font(.callout.weight(.semibold))
                    Text(L("包含 Pro 標誌、深色外觀與跟隨系統自動切換。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !access.isPro {
                Button(L("超級感謝 · 啟用 Pro")) { showingPurchase = true }
                    .buttonStyle(.borderedProminent)
            }
            HStack {
                Spacer()
                Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 440)
        .sheet(isPresented: $showingPurchase) { SuperThanksView() }
        .alert(L("超級感謝"), isPresented: $showingProInfo) {
            Button(L("知道了"), role: .cancel) {}
        } message: {
            Text(L("深色與跟隨系統是 Pro 功能。請開啟「超級感謝」購買或輸入序號啟用；轉檔功能維持免費。"))
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

struct SuperThanksView: View {
    @EnvironmentObject private var access: AppAccess
    @EnvironmentObject private var license: ProLicenseStore
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var serial = ""
    @State private var method = "ApplePay"
    @State private var showingRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label { Text(L("超級感謝")) } icon: { SuperThanksIcon() }
                    .font(.title2.weight(.semibold))
                Spacer()
                PlanBadge(tier: access.tier)
            }
            Text(L("支持 MacMP4 的後續開發。"))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("MacMP4 Pro").font(.headline)
                Spacer()
                Text(L("NT$90 終身買斷")).font(.headline)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label(L("專屬 Pro 標誌"), systemImage: "checkmark")
                Label(L("淺色、深色與跟隨系統外觀"), systemImage: "checkmark")
                Label(L("完整轉檔功能維持免費"), systemImage: "checkmark")
            }.font(.callout)
            Divider()
            if access.isPro {
                Text(L("感謝你的支持，你目前使用 Pro 版本。"))
                Text(license.email).font(.callout).textSelection(.enabled)
                if !license.serial.isEmpty {
                    Text(license.serial).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(L("請保存 Email 與序號，重新安裝時可恢復 Pro。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                TextField(L("購買 Email"), text: $email).textFieldStyle(.roundedBorder)
                    .disabled(license.isBusy || license.hasPendingPurchase)
                if !showingRestore {
                    Picker(L("付款方式"), selection: $method) {
                        if license.applePayAvailable { Text("Apple Pay").tag("ApplePay") }
                        Text(L("信用卡")).tag("Credit")
                    }.disabled(license.isBusy || license.hasPendingPurchase)
                    Text(L("本商店僅支援台灣發行的信用卡，暫不支援海外發行信用卡。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(license.hasPendingPurchase ? L("重新開啟付款頁") : L("超級感謝 · NT$90")) {
                        Task {
                            if let url = await license.purchase(email: email, method: method) {
                                // 系統外部瀏覽器，Apple Pay 使用 Safari；不嵌入付款頁。
                                if method == "ApplePay", let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                                    do { _ = try await NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration()) }
                                    catch { license.reportBrowserFailure() }
                                } else { NSWorkspace.shared.open(url) }
                            }
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!license.canPurchase || license.isBusy || (email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !license.hasPendingPurchase))
                    if license.hasPendingPurchase {
                        HStack {
                            Button(L("檢查付款")) { Task { await license.checkPayment() } }
                            Button(L("重新建立訂單")) { Task { await license.prepareNewOrder() } }
                        }.disabled(license.isBusy)
                        Text(L("付款完成後會自動啟用 Pro，可關閉此視窗繼續轉檔。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(L("已有序號？恢復 Pro")) { showingRestore = true }
                        .buttonStyle(.link).disabled(license.isBusy)
                } else {
                    TextField(L("Pro 序號"), text: $serial).textFieldStyle(.roundedBorder)
                    Button(L("啟用 Pro")) { Task { await license.restore(email: email, serial: serial) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!license.isConfigured || license.isBusy || email.isEmpty || serial.isEmpty)
                    Button(L("返回購買")) { showingRestore = false }.buttonStyle(.link)
                }
                if !license.isConfigured || license.options?.checkoutEnabled == false {
                    Text(L("付款服務尚未設定完成，請稍後再試。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if license.isBusy { ProgressView().controlSize(.small) }
            if let message = license.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Link(L("隱私說明"), destination: license.privacyURL)
                    .font(.caption)
                Spacer()
                Button(L("關閉")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 470)
        .task {
            email = license.pendingEmail ?? license.email
            await license.loadOptions()
            if !license.applePayAvailable { method = "Credit" }
            if let pending = license.pendingMethod { method = pending }
        }
    }
}
