import SwiftUI
import AppKit

/// Runs only after an explicit Install click. No shell, sudo, or downloaded scripts.
final class ToolInstaller: ObservableObject {
    static let shared = ToolInstaller()
    @Published private(set) var terminationPending = false

    func deferTerminationIfInstalling() -> Bool {
        guard isInstalling else { return false }
        terminationPending = true
        return true
    }

    private func finish(status: Int32, completion: () -> Void) {
        exitStatus = status
        isInstalling = false
        completion()
        if terminationPending {
            terminationPending = false
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
    }

    @Published private(set) var isInstalling = false
    @Published private(set) var log = ""
    @Published private(set) var exitStatus: Int32?

    func install(brew: String, completion: @escaping () -> Void) {
        guard !isInstalling else { return }
        isInstalling = true
        exitStatus = nil
        log = "brew install ffmpeg\n"
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install", "ffmpeg"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = URL(fileURLWithPath: brew).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["HOMEBREW_COLOR"] = "0"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                // Drain while the process runs, including stderr, to avoid a full-pipe deadlock.
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    guard !data.isEmpty else { break }
                    let text = String(decoding: data, as: UTF8.self)
                    DispatchQueue.main.async { self.log = String((self.log + text).suffix(24000)) }
                }
                process.waitUntilExit()
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    self.finish(status: status, completion: completion)
                }
            } catch {
                if process.isRunning { process.terminate() }
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.log += "\n" + message
                    self.finish(status: -1, completion: completion)
                }
            }
        }
    }
}

struct ToolSetupView: View {
    @EnvironmentObject private var store: JobStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var installer = ToolInstaller.shared
    @State private var brew = FF.findTool("brew")
    private var ready: Bool { store.ffmpeg != nil && store.ffprobe != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(ready ? L("轉檔工具已就緒") : L("準備轉檔工具"),
                  systemImage: ready ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title2.weight(.semibold))
            Text(L("MacMP4 需要 FFmpeg 與 ffprobe。每次開啟與返回 App 時會自動檢查，安裝完成後不用重新啟動。"))
                .foregroundStyle(.secondary)
            Label("FFmpeg", systemImage: store.ffmpeg == nil ? "circle" : "checkmark.circle.fill")
            Label("ffprobe", systemImage: store.ffprobe == nil ? "circle" : "checkmark.circle.fill")
            if !ready {
                if let brew {
                    Text(L("按下安裝後，會透過這台 Mac 的 Homebrew 執行以下指令，並下載所需套件。"))
                    Text("brew install ffmpeg").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text(brew).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(installer.isInstalling ? L("安裝中…") : L("安裝 FFmpeg")) {
                        installer.install(brew: brew) { store.refreshTools() }
                    }
                    .disabled(installer.isInstalling)
                } else {
                    Text(L("尚未找到 Homebrew。請先依官網指示安裝，完成後返回這裡重新檢查。"))
                    Link(L("開啟 Homebrew 官網"), destination: URL(string: "https://brew.sh/")!)
                    Text(L("Homebrew 目前正式支援 macOS 15 以上；較舊系統可自行安裝相容的 FFmpeg 與 ffprobe。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if installer.isInstalling { ProgressView().controlSize(.small) }
            if installer.terminationPending {
                Text(L("FFmpeg 正在安裝，完成後會結束 MacMP4。"))
                    .foregroundStyle(.secondary)
            }
            if let status = installer.exitStatus, status != 0 || !ready {
                Text(L("尚未完成安裝，請查看下方訊息。修正後可以重試，或自行安裝再重新檢查。"))
                    .foregroundStyle(.orange)
            }
            if !installer.log.isEmpty {
                ScrollView {
                    Text(installer.log).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150).padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button(L("重新檢查")) {
                    store.refreshTools()
                    brew = FF.findTool("brew")
                }.disabled(installer.isInstalling)
                Spacer()
                Button(installer.isInstalling ? L("在背景安裝") : ready ? L("完成") : L("稍後設定")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 530)
    }
}
