import Foundation

@main
struct AppearanceRegression {
    static func main() {
        let suite = "macmp4-appearance-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let free = AppAccess(defaults: defaults)
        precondition(free.tier == .free && free.effectiveAppearance == .light)
        precondition(!free.selectAppearance(.dark) && !free.selectAppearance(.system))
        precondition(free.effectiveAppearance == .light)
        let pro = AppAccess(tier: .pro, defaults: defaults)
        precondition(pro.effectiveAppearance == .system)
        for appearance in AppAppearance.allCases {
            precondition(pro.selectAppearance(appearance))
            precondition(pro.effectiveAppearance == appearance)
            precondition(AppAccess(tier: .pro, defaults: defaults).effectiveAppearance == appearance)
        }
        pro.selectAppearance(.dark)
        precondition(AppAccess(defaults: defaults).effectiveAppearance == .light, "saved Pro preference unlocked Free")
        pro.updateEntitlement(.free)
        precondition(pro.effectiveAppearance == .light && !pro.selectAppearance(.dark))
        pro.updateEntitlement(.pro)
        precondition(pro.effectiveAppearance == .dark, "Pro restoration lost preference")
        defaults.set("corrupt-value", forKey: "AppAppearance")
        precondition(AppAccess(tier: .pro, defaults: defaults).effectiveAppearance == .system)
        defaults.set(true, forKey: "isPro")
        defaults.set("pro", forKey: "tier")
        precondition(AppAccess(defaults: defaults).tier == .free, "unverified defaults enabled Pro")
        print("PASS: Free gating, Pro selection, persistence, revocation/restoration, invalid preferences, no UserDefaults unlock")
    }
}
