import Foundation

@main
struct ReportProblemRegression {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }

        // Redaction removes who and where, keeps what failed.
        let input = URL(fileURLWithPath: "/Users/amy/Movies/Holiday 2026/clip.ts")
        let raw = """
        Input #0, mpegts, from '/Users/amy/Movies/Holiday 2026/clip.ts':
        /Volumes/Backup Disk/.macmp4-p1-ABC/output.mp4: Invalid data found when processing input
        contact amy@example.com or see https://example.com/help and/or retry 1/2
        """
        let clean = ReportProblem.redact(raw, input: input)
        check(!clean.contains("amy") && !clean.contains("Holiday") && !clean.contains("Backup Disk"), "redaction leaked: \(clean)")
        check(clean.contains("<input>.ts"), "input path should become <input>.ts: \(clean)")
        check(clean.contains("<path>.mp4: Invalid data found when processing input"), "other paths should keep their extension: \(clean)")
        check(clean.contains("<email>"), "email not redacted")
        check(clean.contains("https://example.com/help") && clean.contains("and/or") && clean.contains("1/2"), "redaction mangled non-path text: \(clean)")
        check(ReportProblem.redact("plain text, no paths") == "plain text, no paths", "plain text must be unchanged")

        // The tail keeps the end of the output, where ffmpeg reports the failure.
        let long = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n\n  \nError: the real reason"
        let tail = ReportProblem.tail(long, lines: 3)
        check(tail == "line 49\nline 50\nError: the real reason", "tail kept the wrong lines: \(tail)")
        check(ReportProblem.tail(String(repeating: "x", count: 9000), lines: 5).count == ReportProblem.maxLogCharacters, "tail is not bounded")

        // The button shows only after the first attempt plus two retries have failed.
        check(!ReportProblem.isOffered(failures: 0) && !ReportProblem.isOffered(failures: 1) && !ReportProblem.isOffered(failures: 2), "button offered too early")
        check(ReportProblem.isOffered(failures: 3) && ReportProblem.isOffered(failures: 10), "button not offered after repeated failures")

        // The link: product and language in the query, diagnostics only in the fragment.
        let log = "Error: Invalid data found when processing input"
        let url = ReportProblem.makeURL(.init(appVersion: "1.1.0", macOS: "15.1.0", ffmpeg: "7.1.1", errorLog: log), language: "zh-Hant")
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        check(parts.scheme == "https" && parts.host == "support.jimmy-tools.com", "unexpected host: \(url)")
        check(parts.queryItems?.first { $0.name == "product" }?.value == "macmp4", "product missing")
        check(parts.queryItems?.first { $0.name == "lang" }?.value == "zh-Hant", "language missing")
        check(!(parts.query ?? "").contains("Invalid"), "diagnostics must never be in the query string")
        guard let fragment = parts.fragment, fragment.hasPrefix("d=") else { fatalError("diagnostics fragment missing") }
        let encoded = String(fragment.dropFirst(2))
        check(encoded.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, "fragment is not base64url: \(encoded)")
        var padded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        let json = try JSONSerialization.jsonObject(with: Data(base64Encoded: padded)!) as! [String: String]
        check(json == ["app_version": "1.1.0", "macos": "15.1.0", "ffmpeg": "7.1.1", "error_log": log], "payload mismatch: \(json)")

        // Missing pieces are left out rather than sent empty; an oversized log is capped.
        let bare = ReportProblem.makeURL(.init(appVersion: "dev", macOS: "15.0.0", ffmpeg: nil, errorLog: ""), language: "en")
        check(!(bare.fragment ?? "").isEmpty && bare.absoluteString.contains("lang=en"), "bare link broken")
        let big = ReportProblem.makeURL(.init(appVersion: "1", macOS: "1", ffmpeg: nil, errorLog: String(repeating: "e", count: 20000)), language: "en")
        check(big.absoluteString.count < 8000, "link is too long: \(big.absoluteString.count)")

        // The app's own language wins over the system's.
        check(ReportProblem.languageCode(override: "zh-Hant", preferred: ["en-US"]) == "zh-Hant", "override ignored")
        check(ReportProblem.languageCode(override: nil, preferred: ["zh-TW", "en"]) == "zh-Hant", "system Chinese not detected")
        check(ReportProblem.languageCode(override: nil, preferred: ["ja-JP"]) == "en", "other languages should fall back to English")

        // ffmpeg's version comes from the first line of `-version`.
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ffmpeg-\(UUID())")
        try "#!/bin/sh\necho 'ffmpeg version 7.1.1 Copyright (c) 2000-2025 the FFmpeg developers'\necho 'built with Apple clang'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        defer { try? FileManager.default.removeItem(at: fake) }
        check(ReportProblem.ffmpegVersion(path: fake.path) == "7.1.1", "version not parsed")
        check(ReportProblem.ffmpegVersion(path: "/does/not/exist") == nil, "missing tool should give nil")

        print("PASS: report link, fragment-only diagnostics, redaction, bounded log, language choice, ffmpeg version")
    }
}
