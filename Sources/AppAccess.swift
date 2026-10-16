import Foundation
import Combine

enum AppTier: String {
    case free, pro
    var title: String { self == .pro ? "Pro" : "Free" }
}

enum AppAppearance: String, CaseIterable {
    case light, dark, system
}

/// UI entitlements only. Production starts Free until a verified license provider is connected.
/// Neither the tier nor a fake activation switch is read from UserDefaults or the environment.
final class AppAccess: ObservableObject {
    @Published private(set) var tier: AppTier
    @Published private(set) var preferredAppearance: AppAppearance
    private let defaults: UserDefaults
    private static let appearanceKey = "AppAppearance"

    init(tier: AppTier = .free, defaults: UserDefaults = .standard) {
        self.tier = tier
        self.defaults = defaults
        preferredAppearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    var isPro: Bool { tier == .pro }
    var effectiveAppearance: AppAppearance { isPro ? preferredAppearance : .light }

    @discardableResult
    func selectAppearance(_ appearance: AppAppearance) -> Bool {
        guard isPro || appearance == .light else { return false }
        preferredAppearance = appearance
        defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
        return true
    }

    /// Integration seam for the future license provider; not an activation or payment verifier.
    func updateEntitlement(_ tier: AppTier) { self.tier = tier }
}
