// ReportProblem.swift — 「回報問題」:組出帶有診斷資訊的回報表單網址
import Foundation

/// Builds the link that opens the support form with diagnostics already filled in.
///
/// Diagnostics travel in the URL fragment (`#d=…`). Browsers never send a fragment to a server,
/// so nothing leaves the Mac until the customer reads the form and presses submit. The form
/// shows exactly what will be attached and lets them switch it off.
enum ReportProblem {
    static let formURL = "https://support.jimmy-tools.com/add"
    static let product = "macmp4"
    /// The form accepts 8000 characters; keeping well below that keeps the link short.
    static let maxLogCharacters = 4000

    /// The report button appears on a failed file only after it has failed this many times,
    /// that is the first attempt plus one retry. A one-off failure is usually fixed by trying again.
    static let failuresBeforeOffering = 2

    static func isOffered(failures: Int) -> Bool { failures >= failuresBeforeOffering }

    struct Diagnostics {
        var appVersion: String
        var macOS: String
        var ffmpeg: String?
        var errorLog: String?
    }

    // MARK: Redaction

    /// An absolute path runs to the closing quote, a colon followed by a space, or the end of the line,
    /// so folder names containing spaces are covered too. Slashes inside words ("and/or", "1/2") and
    /// URLs ("https://…") are not paths.
    private static let absolutePath = try! NSRegularExpression(pattern: #"(?<![\w<>.:/])/[^\n'"]*?(?=:\s|['"]|$)"#, options: [.anchorsMatchLines])
    private static let email = try! NSRegularExpression(pattern: #"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"#)
    /// `file:/Users/…` and `file:///Users/…` are paths too; the scheme is dropped so the path rule applies.
    private static let fileScheme = try! NSRegularExpression(pattern: #"\bfile:(?://)?(?=/)"#)
    /// Container tags ffmpeg echoes from the customer's video (title, comment, TV service name, …).
    /// `tail` already drops whole `Metadata:` blocks; this catches a leftover tag line in any other text.
    private static let metadataTag = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:title|comment|description|synopsis|artist|album_artist|album|author|composer|performer|publisher|copyright|genre|show|network|location|service_name|service_provider|encoded_by|handler_name)[ \t]*:.*(?:\n|$)"#,
        options: [.anchorsMatchLines, .caseInsensitive])

    /// Removes what identifies the customer or their files: the input's path, every other
    /// absolute path (the extension is kept, since it matters for diagnosis) and email addresses.
    static func redact(_ text: String, input: URL? = nil) -> String {
        var out = metadataTag.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        out = fileScheme.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        if let input, !input.path.isEmpty {
            let ext = input.pathExtension
            out = out.replacingOccurrences(of: input.path, with: ext.isEmpty ? "<input>" : "<input>.\(ext)")
        }
        let range = NSRange(out.startIndex..., in: out)
        var result = ""
        var last = out.startIndex
        for match in absolutePath.matches(in: out, range: range) {
            guard let r = Range(match.range, in: out) else { continue }
            result += out[last..<r.lowerBound]
            let path = out[r]
            let ext = path.range(of: #"\.[A-Za-z0-9]{1,5}$"#, options: .regularExpression).map { String(path[$0]) } ?? ""
            result += "<path>" + ext
            last = r.upperBound
        }
        result += out[last...]
        return email.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<email>")
    }

    /// Drops every `Metadata:` block (the line and the more deeply indented tag lines under it).
    /// ffmpeg prints the video's own tags there, which can carry a title, a name or a place.
    static func withoutMetadata(_ text: String) -> String {
        var skipping: Int?
        var kept: [Substring] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let level = skipping {
                if trimmed.isEmpty || indent > level { continue }
                skipping = nil
            }
            if trimmed == "Metadata:" { skipping = indent; continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// The last `lines` non-empty lines, capped at `maxCharacters` from the end.
    /// The end of ffmpeg's output is where the actual failure is reported.
    static func tail(_ text: String, lines: Int = 12, maxCharacters: Int = maxLogCharacters) -> String {
        let kept = withoutMetadata(text).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: "\n")
        return String(kept.suffix(maxCharacters))
    }

    // MARK: Link

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// `lang` is the app's own language, so the form opens in the language the customer is already using.
    static func makeURL(_ d: Diagnostics, language: String) -> URL {
        var payload = ["app_version": d.appVersion, "macos": d.macOS]
        if let ffmpeg = d.ffmpeg, !ffmpeg.isEmpty { payload["ffmpeg"] = ffmpeg }
        if let log = d.errorLog, !log.isEmpty { payload["error_log"] = String(log.suffix(maxLogCharacters)) }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        var components = URLComponents(string: formURL)!
        components.queryItems = [URLQueryItem(name: "product", value: product), URLQueryItem(name: "lang", value: language)]
        components.fragment = "d=" + base64url(data)
        return components.url!
    }

    // MARK: Environment

    static func languageCode(override: String? = UserDefaults.standard.string(forKey: "AppLanguage"),
                             preferred: [String] = Locale.preferredLanguages) -> String {
        let code = override ?? preferred.first ?? "en"
        return code.lowercased().hasPrefix("zh") ? "zh-Hant" : "en"
    }

    static func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// "ffmpeg version 7.1.1 Copyright …" → "7.1.1". Blocks for a moment: call off the main thread.
    static func ffmpegVersion(path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let first = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first else { return nil }
        let words = first.split(separator: " ")
        guard let i = words.firstIndex(of: "version"), words.indices.contains(i + 1) else { return nil }
        return String(words[i + 1].prefix(40))
    }
}
