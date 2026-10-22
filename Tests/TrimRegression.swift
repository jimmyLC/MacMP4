import Foundation

@main
struct TrimRegression {
    static func main() throws {
        let args = CommandLine.arguments
        let ffmpeg = args[1], ffprobe = args[2]
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macmp4-trim-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "trim worker timed out")
        }
        func makeStore(_ start: String, _ end: String, gpu: Bool = false) -> JobStore {
            let s = JobStore(ffmpeg: ffmpeg, ffprobe: ffprobe)
            s.trimEnabled = true; s.trimStartText = start; s.trimEndText = end
            s.allowReencode = false; s.hardwareAccel = gpu; s.overwrite = true
            return s
        }
        for (start, end) in [("-1", "0"), ("NaN", "1"), ("inf", "1"), ("abc", "0"), ("", "1"), ("0", "0")] {
            let s = makeStore(start, end)
            precondition(s.trimInputError != nil)
            s.start(); precondition(!s.isRunning && s.flashMessage != nil)
        }
        let defaults = JobStore(ffmpeg: ffmpeg, ffprobe: ffprobe)
        precondition(!defaults.trimEnabled && defaults.trimInputError == nil)
        let mp4 = root.appendingPathComponent("original.mp4")
        try fm.copyItem(at: URL(fileURLWithPath: args[3]), to: mp4)
        let original = try Data(contentsOf: mp4)
        defaults.add(urls: [mp4]); defaults.start(); wait { !defaults.isRunning }
        guard case .skipped = defaults.jobs[0].status else { fatalError("default MP4 skip changed") }
        // Six seconds: red / green / blue, two seconds each, with a long GOP.
        for (index, fixture) in args.dropFirst(3).enumerated() {
            let input = root.appendingPathComponent("clip-\(index)." + URL(fileURLWithPath: fixture).pathExtension)
            try fm.copyItem(at: URL(fileURLWithPath: fixture), to: input)
            let before = try Data(contentsOf: input)
            let s = makeStore("2.2", "2.2", gpu: index == 0)
            s.add(urls: [input]); s.start()
            s.trimStartText = "0"; s.trimEndText = "0"; s.trimEnabled = false
            wait { !s.isRunning }
            guard case .done = s.jobs[0].status, let out = s.jobs[0].outURL else { fatalError("trim failed for \(input.path): \(s.jobs[0].status)") }
            let after = try Data(contentsOf: input)
            precondition(before == after, "source overwritten")
            precondition(out.lastPathComponent == "clip-\(index)_trimmed.mp4")
            guard let result = FF.probe(url: out, ffprobe: ffprobe), let duration = result.duration else { fatalError("trim output missing") }
            precondition(abs(duration - 1.6) < 0.15, "wrong duration: \(duration)")
            precondition(result.videoCodec == "h264" && result.audioCodec == "aac")
            for seek in ["0", "1.4"] {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: ffmpeg)
                p.arguments = ["-v", "error", "-ss", seek, "-i", out.path, "-frames:v", "1", "-vf", "scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"]
                p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                try p.run(); let pixel = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                precondition(p.terminationStatus == 0 && pixel.count == 3)
                precondition(Int(pixel[1]) > Int(pixel[0]) + 30 && Int(pixel[1]) > Int(pixel[2]) + 30, "wrong retained frames: \(Array(pixel))")
            }
            let saved = try Data(contentsOf: out)
            let skip = makeStore("1", "1"); skip.overwrite = false
            skip.add(urls: [input]); skip.start(); wait { !skip.isRunning }
            guard case .skipped = skip.jobs[0].status else { fatalError("trim overwrite off ignored") }
            for seconds in ["6", "99"] {
                let invalid = makeStore(seconds, "0")
                invalid.add(urls: [input]); invalid.start(); wait { !invalid.isRunning }
                guard case .failed = invalid.jobs[0].status else { fatalError("out-of-range cut accepted") }
                let retained = try Data(contentsOf: out)
                precondition(saved == retained, "invalid edit replaced output")
            }
        }
        for (index, pair) in [("2.2", "0"), ("0", "2.2"), ("2.9", "2.9")].enumerated() {
            let input = root.appendingPathComponent("single-\(index).mp4")
            try fm.copyItem(at: mp4, to: input)
            let s = makeStore(pair.0, pair.1)
            s.add(urls: [input]); s.start(); wait { !s.isRunning }
            guard case .done = s.jobs[0].status, let out = s.jobs[0].outURL,
                  let result = FF.probe(url: out, ffprobe: ffprobe), let duration = result.duration else { fatalError("single-edge trim failed") }
            precondition(abs(duration - (6 - Double(pair.0)! - Double(pair.1)!)) < 0.15)
        }
        let trim = try ClipTrim(startText: "1", endText: "1")
        for duration: Double? in [nil, .nan, .infinity, 0, 2] {
            do { _ = try trim.resolve(duration: duration); fatalError("invalid duration accepted") } catch {}
        }
        // A successful encoder exit must not accept an untrimmed file.
        let protectedOutput = root.appendingPathComponent("original_trimmed.mp4")
        try Data("KEEP".utf8).write(to: protectedOutput)
        let fakeEncoder = root.appendingPathComponent("fake-encoder")
        try "#!/bin/sh\nfor output do :; done\ncp '\(mp4.path)' \"$output\"\n".write(to: fakeEncoder, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeEncoder.path)
        let invalidOutput = JobStore(ffmpeg: fakeEncoder.path, ffprobe: ffprobe)
        invalidOutput.trimEnabled = true; invalidOutput.trimStartText = "2"; invalidOutput.trimEndText = "2"
        invalidOutput.hardwareAccel = false; invalidOutput.overwrite = true
        invalidOutput.add(urls: [mp4]); invalidOutput.start(); wait { !invalidOutput.isRunning }
        guard case .failed = invalidOutput.jobs[0].status else { fatalError("full uncut output accepted") }
        let preserved = try Data(contentsOf: protectedOutput)
        precondition(preserved == Data("KEEP".utf8))
        // Cancellation keeps both the source and a pre-existing trimmed result.
        let marker = root.appendingPathComponent("started")
        try "#!/bin/sh\nfor output do :; done\nprintf PARTIAL > \"$output\"\ntouch '\(marker.path)'\nexec /bin/sleep 30\n".write(to: fakeEncoder, atomically: true, encoding: .utf8)
        let cancelled = JobStore(ffmpeg: fakeEncoder.path, ffprobe: ffprobe)
        cancelled.trimEnabled = true; cancelled.trimStartText = "1"; cancelled.overwrite = true
        cancelled.hardwareAccel = false
        cancelled.add(urls: [mp4]); cancelled.start(); wait { fm.fileExists(atPath: marker.path) }
        cancelled.stop(); wait { !cancelled.isRunning }
        guard case .waiting = cancelled.jobs[0].status else { fatalError("trim cancellation not resumable") }
        let afterCancel = try Data(contentsOf: protectedOutput)
        precondition(afterCancel == preserved)
        let after = try Data(contentsOf: mp4)
        precondition(original == after)
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".macmp4-") }
        precondition(leftovers.isEmpty)
        print("PASS: trim MP4/MKV/TS content, head/tail/both, H.264/AAC, CPU/hardware fallback, batch snapshot, short cuts, invalid ranges, source/output preservation")
    }
}
