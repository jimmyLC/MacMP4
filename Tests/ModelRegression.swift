import Foundation
import Combine

@main
struct ModelRegression {
    static func main() throws {
        let args = CommandLine.arguments
        let source = URL(fileURLWithPath: args[1])
        let ffmpeg = args[2], ffprobe = args[3]
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macmp4-model-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(condition(), "worker timed out")
        }
        func store(_ encoder: String, _ probe: String) -> JobStore {
            let store = JobStore(ffmpeg: encoder, ffprobe: probe)
            store.autoStart = false
            store.overwrite = true
            store.hardwareAccel = false
            return store
        }
        let setup = JobStore(ffmpeg: nil, ffprobe: nil)
        precondition(setup.ffmpeg == nil && setup.ffprobe == nil)
        setup.refreshTools { $0 == "ffmpeg" ? ffmpeg : ffprobe }
        precondition(setup.ffmpeg == ffmpeg && setup.ffprobe == ffprobe, "setup did not detect installed tools")
        setup.isRunning = true
        setup.refreshTools { _ in nil }
        precondition(setup.ffmpeg == ffmpeg && setup.ffprobe == ffprobe, "setup changed tools during conversion")
        setup.isRunning = false
        setup.refreshTools { _ in nil }
        precondition(setup.ffmpeg == nil && setup.ffprobe == nil, "removed tool was not detected")
        let forcedInput = root.appendingPathComponent("hevc.mkv")
        try fm.copyItem(at: URL(fileURLWithPath: args[4]), to: forcedInput)
        let forcedStore = store(ffmpeg, ffprobe)
        precondition(!forcedStore.forceH264, "force H.264 must default off")
        forcedStore.forceH264 = true
        forcedStore.allowReencode = false
        forcedStore.add(urls: [forcedInput]); forcedStore.start(); wait { !forcedStore.isRunning }
        guard case .done = forcedStore.jobs[0].status else { fatalError("forced GUI conversion failed") }
        guard let result = FF.probe(url: root.appendingPathComponent("hevc.mp4"), ffprobe: ffprobe) else { fatalError("forced output missing") }
        precondition(result.videoCodec == "h264" && result.audioCodec == "aac")
        let input = root.appendingPathComponent("clip.ts")
        let output = root.appendingPathComponent("clip.mp4")
        try fm.copyItem(at: source, to: input)
        let short = store(ffmpeg, ffprobe)
        short.add(urls: [input]); short.start(); wait { !short.isRunning }
        guard case .done = short.jobs[0].status else { fatalError("GUI model rejected short clip") }
        let original = try Data(contentsOf: output)
        let marker = root.appendingPathComponent("started")
        let slow = root.appendingPathComponent("slow-tool")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexec /bin/sleep 30\n".write(to: slow, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let slowEncoder = root.appendingPathComponent("slow-encoder")
        try "#!/bin/sh\nfor output do :; done\nprintf PARTIAL > \"$output\"\ntouch '\(marker.path)'\nexec /bin/sleep 30\n".write(to: slowEncoder, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowEncoder.path)
        for cancelProbe in [false, true] {
            try? fm.removeItem(at: marker)
            let stopped = store(cancelProbe ? ffmpeg : slowEncoder.path, cancelProbe ? slow.path : ffprobe)
            stopped.add(urls: [input]); stopped.start()
            wait { fm.fileExists(atPath: marker.path) }
            let duringConversion = try Data(contentsOf: output)
            precondition(duringConversion == original, "conversion touched final path before validation")
            stopped.stop(); wait { !stopped.isRunning }
            let preserved = try Data(contentsOf: output)
            precondition(preserved == original, "cancel destroyed original")
            guard case .waiting = stopped.jobs[0].status else { fatalError("cancel did not return job to waiting") }
        }
        let invalidEncoder = root.appendingPathComponent("invalid-encoder")
        try "#!/bin/sh\nfor output do :; done\nprintf INVALID > \"$output\"\nexit 0\n".write(to: invalidEncoder, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: invalidEncoder.path)
        let invalid = store(invalidEncoder.path, ffprobe)
        invalid.add(urls: [input]); invalid.start(); wait { !invalid.isRunning }
        let afterFailure = try Data(contentsOf: output)
        precondition(afterFailure == original, "invalid output replaced original")
        guard case .failed = invalid.jobs[0].status else { fatalError("invalid output accepted") }
        try fm.removeItem(at: output)
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let sentinel = output.appendingPathComponent("sentinel")
        try original.write(to: sentinel)
        let directory = store(ffmpeg, ffprobe)
        directory.add(urls: [input]); directory.start(); wait { !directory.isRunning }
        let preserved = try Data(contentsOf: sentinel)
        precondition(preserved == original, "GUI model deleted directory")
        guard case .failed = directory.jobs[0].status else { fatalError("directory should be rejected") }
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".macmp4-") }
        precondition(leftovers.isEmpty, "staging output leaked: \(leftovers)")
        let review = store(ffmpeg, ffprobe)
        precondition(!JobStore(ffmpeg: ffmpeg, ffprobe: ffprobe).autoStart, "review-before-convert should be the default")
        review.add(urls: [input])
        var changeCount = 0
        let observation = review.objectWillChange.sink { changeCount += 1 }
        review.jobs[0].status = .failed("test failure")
        precondition(changeCount > 0, "nested job updates do not refresh workspace")
        precondition(review.processedCount == 1 && review.overallProgress == 1, "failed jobs should count as processed")
        review.clearFinished()
        precondition(review.jobs.count == 1, "clear completed removed failure")
        review.jobs[0].status = .probing
        review.remove(review.jobs[0])
        precondition(review.jobs.count == 1, "probing job was removable")
        review.jobs[0].status = .done(strategy: "test", elapsed: 1)
        review.clearFinished()
        precondition(review.jobs.isEmpty, "completed job not cleared")
        withExtendedLifetime(observation) {}
        print("PASS: GUI model short clip, directory preservation, cancel conversion, cancel probing, failed output validation, temporary cleanup, live UI updates, completed-only clearing")
    }
}
