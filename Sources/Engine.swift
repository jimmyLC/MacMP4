// Engine.swift — ffmpeg/ffprobe 操作核心(無 UI 依賴,可同時給 GUI 和 CLI 用)
import Foundation

struct ProbeResult {
    var videoCodec: String?
    var audioCodec: String?
    var duration: Double?
    var hasVideo: Bool { videoCodec != nil }
    var hasAudio: Bool { audioCodec != nil }
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
    static func probe(url: URL, ffprobe: String) -> ProbeResult? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
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
                } else if type == "audio", result.audioCodec == nil {
                    result.audioCodec = s["codec_name"] as? String
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
    static func strategies(for probe: ProbeResult, allowReencode: Bool, hardwareAccel: Bool) -> [Strategy] {
        let maps = ["-map", "0:v:0?", "-map", "0:a:0?"]
        let vOK = probe.videoCodec.map { mp4VideoCodecs.contains($0) } ?? false
        let aOK = probe.audioCodec.map { mp4AudioCodecs.contains($0) } ?? true
        var list: [Strategy] = []

        if probe.hasVideo && vOK && aOK {
            // 最理想:影片+音訊都直接複製,零損失、極快(純 I/O,無需也無法用 GPU 加速)
            list.append(Strategy(label: "無損轉換", args: maps + ["-c", "copy"]))
        }
        if probe.hasVideo && vOK {
            // 音訊重編碼:修復損壞的 AAC 幀等問題(影片仍為複製)
            list.append(Strategy(label: "修復音訊", args: maps + ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k"]))
        }
        if allowReencode {
            if hardwareAccel {
                // GPU 硬體編碼:Apple VideoToolbox(媒體引擎),速度快、省電
                list.append(Strategy(label: "GPU 硬體編碼", args: maps + [
                    "-c:v", "h264_videotoolbox", "-q:v", "65",
                    "-c:a", "aac", "-b:a", "192k",
                ]))
            }
            // 最後手段:軟體重新編碼(同解析度、CRF18 高畫質;GPU 失敗時自動退回這裡)
            list.append(Strategy(label: "重新編碼", args: maps + [
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k",
            ]))
        }
        return list
    }

    /// 執行 ffmpeg 轉換。progress: (百分比(-1=未知), 速度字串)
    /// didStart: 讓呼叫端拿到 Process 以便中途停止
    static func run(ffmpeg: String, input: URL, output: URL, strategy: Strategy,
                    duration: Double?,
                    didStart: ((Process) -> Void)? = nil,
                    progress: @escaping (Double, String) -> Void) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)

        var args = ["-hide_banner", "-nostdin", "-y",
                    // 容錯:批次轉檔遇到零星壞封包不中斷,直接跳過
                    "-err_detect", "ignore_err", "-fflags", "+discardcorrupt",
                    "-i", input.path]
        args += strategy.args
        args += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        var buffer = Data()
        var lastSpeed = ""

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
            if d.isEmpty { fh.readabilityHandler = nil }
        }

        do { try p.run() } catch { return false }
        didStart?(p)
        p.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        return p.terminationStatus == 0
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
    if seconds < 60 { return String(format: "%.1f 秒", seconds) }
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// 支援的影片副檔名
let supportedVideoExtensions: Set<String> = [
    "ts", "m2ts", "mts", "tp", "trp", "mkv", "flv", "f4v", "avi", "mov",
    "wmv", "webm", "mpg", "mpeg", "vob", "rm", "rmvb", "ogv", "3gp", "3g2",
    "m4v", "mp4", "asf", "divx", "mxf", "dv", "dat",
]
