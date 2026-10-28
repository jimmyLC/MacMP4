import Foundation

@main
struct OutputRegression {
    static func main() throws {
        let hevc = ProbeResult(videoCodec: "hevc", audioCodec: "aac", duration: 1)
        let normal = FF.strategies(for: hevc, allowReencode: true, hardwareAccel: true)
        precondition(normal.first?.args.contains("copy") == true, "default remux changed")
        for hardware in [false, true] {
            let forced = FF.strategies(for: hevc, allowReencode: false, hardwareAccel: hardware, forceH264: true)
            precondition(!forced.isEmpty && forced.allSatisfy { !$0.args.contains("copy") })
            precondition(forced.last?.args.contains("libx264") == true)
            precondition(!hardware || forced.first?.args.contains("h264_videotoolbox") == true)
        }
        precondition(!FF.outputIsValid(hevc, forceH264: true))
        precondition(FF.outputIsValid(hevc, forceH264: false))
        precondition(FF.outputIsValid(ProbeResult(videoCodec: "h264", audioCodec: "aac", duration: 1), forceH264: true))
        precondition(FF.outputIsValid(ProbeResult(videoCodec: "h264", audioCodec: nil, duration: 1), forceH264: true))
        precondition(!FF.outputIsValid(ProbeResult(videoCodec: "h264", audioCodec: "ac3", duration: 1), forceH264: true))
        precondition(FF.strategies(for: ProbeResult(audioCodec: "aac", duration: 1), allowReencode: true, hardwareAccel: false, forceH264: true).isEmpty)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("macmp4-output-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let output = root.appendingPathComponent("existing.mp4")
        let original = Data("ORIGINAL".utf8)
        try original.write(to: output)
        func expect(_ value: Bool, _ message: String) { precondition(value, message) }
        func attemptFailure() throws {
            let attempt = try OutputTransaction(destination: output, overwrite: true)
            let result = FF.run(ffmpeg: "/does/not/exist", input: root.appendingPathComponent("input.ts"),
                                output: attempt.temporaryURL, strategy: Strategy(label: "test", args: []),
                                duration: nil) { _, _ in }
            expect(!result, "launch failure should fail")
            attempt.discardAttempt()
        }
        try attemptFailure()
        expect(try Data(contentsOf: output) == original, "launch failure destroyed existing output")
        let attempt = try OutputTransaction(destination: output, overwrite: true)
        try Data("NEW".utf8).write(to: attempt.temporaryURL)
        try attempt.commit()
        expect(try Data(contentsOf: output) == Data("NEW".utf8), "successful replace failed")
        let freshOutput = root.appendingPathComponent("fresh.mp4")
        let exclusive = try OutputTransaction(destination: freshOutput, overwrite: false)
        try original.write(to: exclusive.temporaryURL)
        try exclusive.commit()
        expect(try Data(contentsOf: freshOutput) == original, "exclusive creation failed")
        let newOutput = root.appendingPathComponent("race.mp4")
        let noOverwrite = try OutputTransaction(destination: newOutput, overwrite: false)
        try Data("TEMP".utf8).write(to: noOverwrite.temporaryURL)
        try original.write(to: newOutput)
        do { try noOverwrite.commit(); fatalError("no-overwrite clobbered a new arrival") } catch {}
        expect(try Data(contentsOf: newOutput) == original, "no-overwrite lost a new arrival")
        let link = root.appendingPathComponent("link.mp4")
        try fm.createSymbolicLink(at: link, withDestinationURL: output)
        do { _ = try OutputTransaction(destination: link, overwrite: true); fatalError("symlink accepted") } catch {}
        // Staging folders left by dead processes are removed; live ones are kept.
        let staleRoot = root.appendingPathComponent("stale")
        try fm.createDirectory(at: staleRoot, withIntermediateDirectories: false)
        let dead = staleRoot.appendingPathComponent(".macmp4-p4000000-\(UUID().uuidString)")
        let alive = staleRoot.appendingPathComponent(".macmp4-p\(getpid())-\(UUID().uuidString)")
        for dir in [dead, alive] { try fm.createDirectory(at: dir, withIntermediateDirectories: false) }
        _ = try OutputTransaction(destination: staleRoot.appendingPathComponent("x.mp4"), overwrite: false)
        expect(!fm.fileExists(atPath: dead.path), "stale staging folder not removed")
        expect(fm.fileExists(atPath: alive.path), "live staging folder removed")
        let claimedPath = staleRoot.appendingPathComponent("a.mp4").standardizedFileURL.path
        expect(uniqueOutputURL(staleRoot.appendingPathComponent("a.mp4"), claimed: [claimedPath]).lastPathComponent == "a 2.mp4", "unique output name")
        print("PASS: preserve output on launch failure, atomic replace, no-overwrite collision, symlink rejection")
    }
}
