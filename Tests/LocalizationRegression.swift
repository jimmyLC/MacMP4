import Foundation

@main
struct LocalizationRegression {
    static func main() throws {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: "AppLanguage") }
        let expectedURL = Bundle.main.url(forResource: "Expected", withExtension: "json")!
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: expectedURL))
        for language in ["en", "zh-Hant"] {
            defaults.set(language, forKey: "AppLanguage")
            for (key, translation) in expected {
                let wanted = language == "en" ? translation : key
                precondition(L(key) == wanted, "Missing \(language) localization: \(key)")
            }
        }
        defaults.removeObject(forKey: "AppLanguage")
        let system = L("輸出設定")
        precondition(system == "Output settings" || system == "輸出設定", "system language fallback failed")
        print("PASS: \(expected.count) English keys, Traditional Chinese override, system fallback")
    }
}
