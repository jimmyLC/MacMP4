import Foundation

@main
struct OutputRegression {
    static func main() throws {
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
        print("PASS: preserve output on launch failure, atomic replace, no-overwrite collision, symlink rejection")
    }
}
