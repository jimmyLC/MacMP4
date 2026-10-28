// Engine.swift — ffmpeg/ffprobe 操作核心(無 UI 依賴,可同時給 GUI 和 CLI 用)
import Foundation
import Darwin

struct ProbeResult {
    var videoCodec: String?
    var audioCodec: String?
    /// Codecs of every audio stream, in file order (`audioCodec` is the first).
    var audioCodecs: [String] = []
    var duration: Double?
    var hasVideo: Bool { videoCodec != nil }
    var hasAudio: Bool { audioCodec != nil }
    var isValidOutput: Bool {
        guard hasVideo || hasAudio, let duration else { return false }
        return duration.isFinite && duration > 0
    }
}

/// Optional batch edit. Values describe how much to remove, not absolute end times.
struct ClipTrim {
    let start: Double
    let end: Double

    init(startText: String, endText: String) throws {
        guard let start = Double(startText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Double(endText.trimmingCharacters(in: .whitespacesAndNewlines)),
              start.isFinite, end.isFinite, start >= 0, end >= 0 else {
            throw TrimError.invalidSeconds
        }
        guard start > 0 || end > 0 else { throw TrimError.emptyEdit }
        self.start = start
        self.end = end
    }

    func resolve(duration: Double?) throws -> ClipRange {
        guard let duration, duration.isFinite, duration > 0 else { throw TrimError.unknownDuration }
        let retained = duration - start - end
        guard retained.isFinite, retained > 0 else { throw TrimError.tooLong }
        return ClipRange(start: start, duration: retained)
    }
}

struct ClipRange {
    let start: Double
    let duration: Double

    func matches(_ output: ProbeResult) -> Bool {
        guard let actual = output.duration else { return false }
        // Allow video-frame and AAC packet rounding, but reject a full uncut file.
        return output.isValidOutput && abs(actual - duration) <= 0.25
    }
}

enum TrimError: LocalizedError {
    case invalidSeconds, emptyEdit, unknownDuration, tooLong
    var errorDescription: String? {
        switch self {
        case .invalidSeconds: return L("請輸入大於或等於 0 的秒數，可使用小數。")
        case .emptyEdit: return L("請設定要剪掉的開頭或結尾秒數。")
        case .unknownDuration: return L("無法確認影片長度，無法裁切此檔案。")
        case .tooLong: return L("剪掉的總長度必須小於影片長度。")
        }
    }
}

struct Strategy {
    let label: String
    let args: [String]
}

enum FF {

    /// 在常見位置找工具(含 Homebrew 路徑,GUI App 的 PATH 通常不含它們)
    static func findTool(_ name: String) -> String? {
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/opt/local/bin/\(name)",
        ]
        if let envPath = ProcessInfo.processInfo.environment["PATH"], !envPath.isEmpty {
            candidates.append(contentsOf: envPath.split(separator: ":").map { "\($0)/\(name)" })
        }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    /// 用 ffprobe 讀取第一個視訊/音訊編碼與時長
    static func probe(url: URL, ffprobe: String, didStart: ((Process) -> Void)? = nil) -> ProbeResult? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", url.path]
        let out = Pipe()
        p.standardOutput = out
        // Probe diagnostics are not displayed. A null handle cannot fill up and
        // block the child while the parent waits for JSON on stdout.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        didStart?(p)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        var result = ProbeResult()
        if let streams = obj["streams"] as? [[String: Any]] {
            for s in streams {
                let type = s["codec_type"] as? String
                if type == "video", result.videoCodec == nil {
                    // 忽略封面圖類的 attached_pic
                    if (s["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1 {
                        result.videoCodec = s["codec_name"] as? String
                    }
                } else if type == "audio", let codec = s["codec_name"] as? String {
                    if result.audioCodec == nil { result.audioCodec = codec }
                    result.audioCodecs.append(codec)
                }
            }
        }
        if let f = obj["format"] as? [String: Any],
           let d = f["duration"] as? String, let v = Double(d) {
            result.duration = v
        }
        return result
    }

    static let mp4VideoCodecs: Set<String> = ["h264", "hevc", "av1"]
    static let mp4AudioCodecs: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3"]

    /// 依來源編碼決定轉換策略(由快到慢,逐一嘗試)
    static func strategies(for probe: ProbeResult, allowReencode: Bool, hardwareAccel: Bool, forceH264: Bool = false) -> [Strategy] {
        if forceH264 && !probe.hasVideo { return [] }
        // Keep every audio track (dual-language recordings); only the first video.
        let maps = ["-map", "0:v:0?", "-map", "0:a?"]
        let vOK = probe.videoCodec.map { mp4VideoCodecs.contains($0) } ?? false
        let audioCodecs = probe.audioCodecs.isEmpty ? (probe.audioCodec.map { [$0] } ?? []) : probe.audioCodecs
        let aOK = audioCodecs.allSatisfy { mp4AudioCodecs.contains($0) }
        // Copied HEVC defaults to the hev1 tag, which QuickTime/AVFoundation refuses to play.
        let copyTag = probe.videoCodec == "hevc" ? ["-tag:v", "hvc1"] : []
        var list: [Strategy] = []

        if !forceH264 && probe.hasVideo && vOK && aOK {
            // 最理想:影片+音訊都直接複製,零損失、極快(純 I/O,無需也無法用 GPU 加速)
            list.append(Strategy(label: L("無損轉換"), args: maps + ["-c", "copy"] + copyTag))
        }
        if !forceH264 && probe.hasVideo && vOK {
            // 音訊重編碼:修復損壞的 AAC 幀等問題(影片仍為複製)
            list.append(Strategy(label: L("修復音訊"), args: maps + ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"] + copyTag))
        }
        if allowReencode || forceH264 {
            if hardwareAccel {
                // GPU 硬體編碼:Apple VideoToolbox(媒體引擎),速度快、省電
                list.append(Strategy(label: L("GPU 硬體編碼"), args: maps + [
                    "-c:v", "h264_videotoolbox", "-q:v", "65",
                    "-c:a", "aac", "-b:a", "192k",
                ]))
            }
            // 最後手段:軟體重新編碼(同解析度、CRF18 高畫質;GPU 失敗時自動退回這裡)
            list.append(Strategy(label: L("重新編碼"), args: maps + [
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k",
            ]))
        }
        return list
    }

    static func outputIsValid(_ probe: ProbeResult, forceH264: Bool) -> Bool {
        probe.isValidOutput && (!forceH264 ||
            (probe.videoCodec == "h264" && (probe.audioCodec == nil || probe.audioCodec == "aac")))
    }

    /// 執行 ffmpeg 轉換。progress: (百分比(-1=未知), 速度字串)
    /// didStart: 讓呼叫端拿到 Process 以便中途停止
    static func run(ffmpeg: String, input: URL, output: URL, strategy: Strategy,
                    duration: Double?, trim: ClipRange? = nil,
                    didStart: ((Process) -> Void)? = nil,
                    progress: @escaping (Double, String) -> Void,
                    errorOutput: ((String) -> Void)? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)

        var args = ["-hide_banner", "-nostdin", "-y",
                    // 容錯:批次轉檔遇到零星壞封包不中斷,直接跳過
                    "-err_detect", "ignore_err", "-fflags", "+discardcorrupt"]
        args += ["-i", input.path]
        // Output seeking decodes up to the cut. Unlike demuxer seeking, this also
        // handles TS files with sparse/missing seek indexes and long GOPs.
        if let trim { args += ["-ss", String(trim.start), "-t", String(trim.duration), "-map_chapters", "-1"] }
        args += strategy.args
        args += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        var buffer = Data()
        var lastSpeed = ""
        // ffmpeg reports the reason for a failure at the end of stderr; keep only the last 16 KB.
        var errorTail = Data()
        let errorTailLimit = 16 * 1024

        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            buffer.append(d)
            while let idx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<idx)
                buffer.removeSubrange(buffer.startIndex...idx)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                    let eq = line.firstIndex(of: "=")!
                    let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if let us = Double(raw) {
                        let pct: Double
                        if let dur = duration, dur > 0 {
                            pct = min(100, max(0, us / 1_000_000 / dur * 100))
                        } else {
                            pct = -1
                        }
                        progress(pct, lastSpeed)
                    }
                } else if line.hasPrefix("speed=") {
                    lastSpeed = String(line.dropFirst("speed=".count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData   // 排空 stderr,避免 ffmpeg 卡住
            if d.isEmpty { fh.readabilityHandler = nil; return }
            errorTail.append(d)
            if errorTail.count > errorTailLimit { errorTail = errorTail.suffix(errorTailLimit) }
        }

        do { try p.run() } catch { return false }
        didStart?(p)
        p.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        errorTail.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        errorOutput?(String(decoding: errorTail.suffix(errorTailLimit), as: UTF8.self))
        return p.terminationStatus == 0
    }
}

/// Each conversion owns a private staging directory beside its destination.
/// Only this directory is cleaned up; the final path is touched after validation.
final class OutputTransaction {
    let temporaryURL: URL
    private let directory: URL
    private let destination: URL
    private let overwrite: Bool

    init(destination: URL, overwrite: Bool) throws {
        self.destination = destination
        self.overwrite = overwrite
        try Self.validateDestination(destination, overwrite: overwrite)
        let parent = destination.deletingLastPathComponent()
        Self.removeStaleDirectories(in: parent)
        directory = parent.appendingPathComponent("\(Self.prefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryURL = directory.appendingPathComponent("output.mp4")
    }

    /// Staging folders are named `.macmp4-p<pid>-<uuid>`. A crash, force-quit or Ctrl+C skips
    /// `deinit`, so the next run removes folders whose owning process no longer exists.
    private static let prefix = ".macmp4-p"
    private static let cleanedLock = NSLock()
    private static var cleanedDirectories = Set<String>()

    static func removeStaleDirectories(in parent: URL) {
        cleanedLock.lock()
        let first = cleanedDirectories.insert(parent.standardizedFileURL.path).inserted
        cleanedLock.unlock()
        guard first, let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard let pidText = rest.split(separator: "-", maxSplits: 1).first, let pid = pid_t(pidText) else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
            }
        }
    }

    /// Remove the staging folder now (signal handlers cannot rely on `deinit`).
    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    private static func validateDestination(_ url: URL, overwrite: Bool) throws {
        // attributesOfItem inspects the link itself: reject directories, symlinks
        // (including dangling ones), devices, etc., rather than following them.
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return }
            throw error
        }
        guard overwrite, attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NSError(domain: "MacMP4.Output", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(format: L("輸出位置已存在或不是一般檔案: %@"), url.lastPathComponent)])
        }
    }

    func commit() throws {
        try Self.validateDestination(destination, overwrite: overwrite)
        // Both paths are on the same volume. rename atomically replaces a file
        // without truncating it first; RENAME_EXCL prevents no-overwrite races
        // without requiring hard-link support on the output filesystem.
        var failure: Int32 = 0
        temporaryURL.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                if overwrite {
                    if Darwin.rename(source!, target!) != 0 { failure = errno }
                } else if Darwin.renamex_np(source!, target!, UInt32(RENAME_EXCL)) != 0 {
                    failure = errno
                    // exFAT and some network volumes lack RENAME_EXCL: check, then plain rename.
                    if failure == ENOTSUP || failure == EINVAL {
                        var info = stat()
                        if Darwin.lstat(target!, &info) == 0 { failure = EEXIST }
                        else { failure = Darwin.rename(source!, target!) == 0 ? 0 : errno }
                    }
                }
            }
        }
        guard failure == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure)) }
    }

    func discardAttempt() {
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    deinit { cleanup() }
}

/// Picks an output URL not already claimed by another file in the same batch, so
/// `a.ts` and `a.mkv` (or same-named files from different folders) never overwrite each other.
func uniqueOutputURL(_ url: URL, claimed: Set<String>) -> URL {
    guard claimed.contains(url.standardizedFileURL.path) else { return url }
    let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
    var n = 2
    while true {
        let candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
        if !claimed.contains(candidate.standardizedFileURL.path) { return candidate }
        n += 1
    }
}

/// 秒數 → "H:MM:SS" / "M:SS"
func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%d:%02d", m, sec)
}

/// 耗時 → 未滿 60 秒顯示 "12.4 秒",超過顯示 "M:SS"
func formatElapsed(_ seconds: Double) -> String {
    if seconds < 60 { return String(format: L("%.1f 秒"), seconds) }
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// 支援的影片副檔名
let supportedVideoExtensions: Set<String> = [
    "ts", "m2ts", "mts", "tp", "trp", "mkv", "flv", "f4v", "avi", "mov",
    "wmv", "webm", "mpg", "mpeg", "vob", "rm", "rmvb", "ogv", "3gp", "3g2",
    "m4v", "mp4", "asf", "divx", "mxf", "dv", "dat",
]

/// 取用本地化字串:程式碼以「繁體中文原文」作為 key,
/// 英文翻譯位於 Resources/en.lproj/Localizable.strings。
/// 可用 UserDefaults 的 "AppLanguage"("zh-Hant" / "en")覆寫系統語言。
/// CLI 執行時 bundle 內沒有翻譯資源 → 直接回傳中文原文。
func L(_ key: String) -> String {
    var bundle = Bundle.main
    if let code = UserDefaults.standard.string(forKey: "AppLanguage"),
       let path = Bundle.main.path(forResource: code, ofType: "lproj"),
       let b = Bundle(path: path) {
        bundle = b
    }
    return bundle.localizedString(forKey: key, value: key, table: nil)
}
