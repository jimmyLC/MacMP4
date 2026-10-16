// App.swift — SwiftUI 介面
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct MacMP4App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = JobStore.shared

    var body: some Scene {
        WindowGroup("MacMP4") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 720, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async {
            JobStore.shared.add(urls: urls)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - 主畫面

struct ContentView: View {
    @EnvironmentObject var store: JobStore
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if store.ffmpeg == nil || store.ffprobe == nil {
                missingBanner
            }
            dropZone
            listSection
            Divider()
            optionsBar
            Divider()
            bottomBar
        }
        .frame(minWidth: 660, minHeight: 540)
        .animation(.easeInOut(duration: 0.2), value: store.jobs.isEmpty)
    }

    // MARK: 區塊

    private var missingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("找不到 ffmpeg。請先開啟「終端機」執行:brew install ffmpeg")
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private var dropZone: some View {
        let empty = store.jobs.isEmpty
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 2, dash: [7])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
            VStack(spacing: empty ? 14 : 6) {
                Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "arrow.down.doc.fill")
                    .font(.system(size: empty ? 56 : 22))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
                Text("把影片檔(.ts / .m2ts / .mkv / .flv / .avi …)或整個資料夾拖進來")
                    .font(empty ? .title3 : .callout)
                    .multilineTextAlignment(.center)
                Text("無損秒轉 MP4:不重編碼、不改解析度,壞檔自動修復")
                    .font(empty ? .callout : .caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: empty ? nil : 84)
        .frame(maxHeight: empty ? .infinity : nil)
        .padding([.horizontal, .top], 14)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var listSection: some View {
        if !store.jobs.isEmpty {
            List {
                ForEach(store.jobs) { job in
                    JobRow(job: job)
                        .environmentObject(store)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 6)
        }
    }

    private var optionsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle("輸出到來源資料夾", isOn: $store.outputToSource)
                Button("選擇輸出資料夾…") { pickOutputDir() }
                    .disabled(store.outputToSource)
                if !store.outputToSource, let dir = store.customOutputDir {
                    Text(dir.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(dir.path)
                }
                Spacer()
                Toggle("加入後自動開始", isOn: $store.autoStart)
            }
            HStack(spacing: 12) {
                Toggle("覆蓋已存在的 MP4", isOn: $store.overwrite)
                Toggle("失敗時自動重新編碼", isOn: $store.allowReencode)
                    .help("無損轉換與修復音訊都失敗時,整檔重新編碼(較慢,但能救回檔案)")
                Toggle("GPU 硬體加速", isOn: $store.hardwareAccel)
                    .disabled(!store.allowReencode)
                    .help("重新編碼時使用 Apple VideoToolbox 硬體編碼器:快很多、省電。關閉則用 CPU x264(品質略佳、較慢)")
                Spacer()
            }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView(value: store.overallProgress)
                    .progressViewStyle(.linear)
                Text("\(store.doneCount)/\(store.jobs.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Button { pickFiles() } label: {
                    Label("加入檔案", systemImage: "plus")
                }
                Button { pickFolder() } label: {
                    Label("加入資料夾", systemImage: "folder.badge.plus")
                }
                Spacer()
                if let msg = store.flashMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("清除已完成") { store.clearFinished() }
                    .disabled(store.jobs.isEmpty)
                if store.isRunning {
                    Button { store.stop() } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .tint(.red)
                } else {
                    Button { store.start() } label: {
                        Label("開始轉換", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.hasWaiting)
                }
            }
        }
        .padding(14)
    }

    // MARK: 動作

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let collect = NSLock()
        var urls: [URL] = []
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let u = url {
                    collect.lock()
                    urls.append(u)
                    collect.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { store.add(urls: urls) }
        }
        return true
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "選擇要轉成 MP4 的影片檔"
        if panel.runModal() == .OK {
            store.add(urls: panel.urls)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "選擇包含影片的資料夾"
        if panel.runModal() == .OK {
            store.add(urls: panel.urls)
        }
    }

    private func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "選擇 MP4 輸出位置"
        if panel.runModal() == .OK {
            store.customOutputDir = panel.urls.first
            store.outputToSource = false
        }
    }
}

// MARK: - 單列

struct JobRow: View {
    @ObservedObject var job: Job
    @EnvironmentObject var store: JobStore

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            trailingControls
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { reveal() }
        .help(tooltip)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .probing:
            Image(systemName: "hourglass").foregroundStyle(.blue)
        case .converting:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.orange)
        }
    }

    private var subtitle: String {
        let sizeStr = ByteCountFormatter.string(fromByteCount: job.size, countStyle: .file)
        let durStr: String
        if let d = job.duration {
            durStr = " · " + formatDuration(d)
        } else {
            durStr = ""
        }
        let state: String
        switch job.status {
        case .waiting: state = "等待中"
        case .probing: state = "讀取中…"
        case .converting(let pct, let speed, let label):
            let p = pct < 0 ? "" : String(format: " %.0f%%", pct)
            let s = speed.isEmpty ? "" : " · \(speed)"
            state = "\(label)…\(p)\(s)"
        case .done(let strategy, let elapsed): state = "完成(\(strategy) · \(formatElapsed(elapsed)))"
        case .failed(let msg): state = "失敗:\(msg)"
        case .skipped(let msg): state = "略過:\(msg)"
        }
        return sizeStr + durStr + " · " + state
    }

    private var subtitleColor: Color {
        switch job.status {
        case .failed: return .red
        case .skipped: return .orange
        case .done: return .green
        default: return .secondary
        }
    }

    private var tooltip: String {
        var lines = [job.url.path]
        if let v = job.outURL { lines.append("輸出:" + v.path) }
        if case .converting(let pct, _, _) = job.status, pct >= 0 {
            lines.append(String(format: "進度:%.1f%%", pct))
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: 4) {
            if case .done = job.status {
                Button { reveal() } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中顯示")
            }
            if case .failed = job.status {
                Button { store.retry(job) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重試")
            }
            if case .converting = job.status {
                EmptyView()
            } else {
                Button { store.remove(job) } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("從清單移除")
            }
        }
        .controlSize(.small)
    }

    private func reveal() {
        if let out = job.outURL {
            NSWorkspace.shared.activateFileViewerSelecting([out])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([job.url])
        }
    }
}
