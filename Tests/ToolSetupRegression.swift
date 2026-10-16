import Foundation

@main
struct ToolSetupRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macmp4-installer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "installer timed out")
        }
        for status in [0, 7] {
            let fake = root.appendingPathComponent("brew")
            try "#!/bin/sh\n[ \"$1\" = install ] && [ \"$2\" = ffmpeg ] || exit 99\n[ \"$#\" = 2 ] || exit 98\ni=0; while [ $i -lt 5000 ]; do echo noisy-install-output >&2; i=$((i+1)); done\necho INSTALLER-END\nexit \(status)\n".write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            let installer = ToolInstaller()
            var completions = 0
            installer.install(brew: fake.path) { completions += 1 }
            installer.install(brew: fake.path) { fatalError("duplicate install started") }
            wait { !installer.isInstalling }
            precondition(completions == 1 && installer.exitStatus == Int32(status))
            precondition(installer.log.contains("INSTALLER-END") && installer.log.count <= 24000)
        }
        let liveBrew = root.appendingPathComponent("live-brew")
        try "#!/bin/sh\necho FIRST-LIVE-LINE\n/bin/sleep 2\n".write(to: liveBrew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveBrew.path)
        let live = ToolInstaller()
        live.install(brew: liveBrew.path) {}
        let liveDeadline = Date().addingTimeInterval(1)
        while !live.log.contains("FIRST-LIVE-LINE"), Date() < liveDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(live.isInstalling && live.log.contains("FIRST-LIVE-LINE"), "log is not delivered before process exits")
        wait { !live.isInstalling }
        let missing = ToolInstaller()
        var completed = false
        missing.install(brew: root.appendingPathComponent("missing").path) { completed = true }
        wait { !missing.isInstalling }
        precondition(completed && missing.exitStatus == -1)
        print("PASS: installer arguments, noisy stderr, bounded log, success/failure, duplicate prevention, launch failure")
    }
}
