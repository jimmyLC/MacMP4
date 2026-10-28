import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct MacMP4App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = JobStore.shared
    @StateObject private var license = ProLicenseStore()
    @State private var showingAbout = false
    #if MACMP4_PREVIEW_PRO
    @StateObject private var access = AppAccess(tier: .pro)
    #else
    @StateObject private var access = AppAccess()
    #endif

    var body: some Scene {
        WindowGroup("MacMP4") {
            ContentView(showingAbout: $showingAbout)
                .environmentObject(store).environmentObject(access).environmentObject(license)
                .preferredColorScheme(access.preferredColorScheme)
                .onAppear { access.applyNativeAppearance() }
                .task {
                    await license.resume(access: access)
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                        if license.hasRecoverablePurchases { await license.checkPayment() }
                    }
                }
                .onChange(of: access.effectiveAppearance) { _ in access.applyNativeAppearance() }
                .id(store.appLanguage)
        }
        .defaultSize(width: 960, height: 660)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button(L("關於 MacMP4")) { showingAbout = true }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async { JobStore.shared.add(urls: urls) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ToolInstaller.shared.deferTerminationIfInstalling() ? .terminateLater : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct ConversionMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.9, 0.30)); path.addLine(to: point(0.1, 0.30))
        path.move(to: point(0.27, 0.13)); path.addLine(to: point(0.1, 0.30)); path.addLine(to: point(0.27, 0.47))
        path.move(to: point(0.1, 0.70)); path.addLine(to: point(0.9, 0.70))
        path.move(to: point(0.73, 0.53)); path.addLine(to: point(0.9, 0.70)); path.addLine(to: point(0.73, 0.87))
        return path
    }
}

private struct ControlSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white :
                (colorScheme == .dark ? Color.white.opacity(0.75) : Color.black.opacity(0.65)))
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background {
                Capsule().fill(isEnabled ?
                    (configuration.isPressed ? Color(red: 0, green: 0.30, blue: 0.67) : Color(red: 0, green: 0.38, blue: 0.80)) :
                    Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                Capsule().strokeBorder(isEnabled ? Color.white.opacity(0.16) : Color.primary.opacity(0.12), lineWidth: 1)
            }
            .contentShape(Capsule())
    }
}

struct ContentView: View {
    @Binding var showingAbout: Bool
    @EnvironmentObject var store: JobStore
    @EnvironmentObject private var access: AppAccess
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false
    @State private var advancedExpanded = false
    @State private var showingToolSetup = false
    @State private var showingAppearance = false
    @State private var showingThanks = false

    private var toolsAvailable: Bool { store.ffmpeg != nil && store.ffprobe != nil }
    private var outputName: String {
        store.outputToSource ? L("與來源影片相同") : store.customOutputDir?.lastPathComponent ?? L("尚未選擇")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !toolsAvailable { missingTools }
            HStack(spacing: 0) {
                queue.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector.frame(width: 250)
            }
            actionShelf.padding(16)
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
        .sheet(isPresented: $showingAbout) { AboutView().environmentObject(access) }
        .sheet(isPresented: $showingAppearance) { AppearanceView().environmentObject(access) }
        .sheet(isPresented: $showingThanks) { SuperThanksView().environmentObject(access) }
        .sheet(isPresented: $showingToolSetup) { ToolSetupView().environmentObject(store) }
        .onAppear {
            store.refreshTools()
            showingToolSetup = !toolsAvailable
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshTools()
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9]))
                    .padding(6).allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: dropTargeted)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ConversionMark()
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text("MacMP4").font(.system(size: 20, weight: .semibold))
                    Button { showingAppearance = true } label: { PlanBadge(tier: access.tier) }
                        .buttonStyle(.plain).help(L("版本與外觀設定"))
                }
                Text(L("影片轉檔，簡單完成")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Button(action: pickFiles) { Label(L("加入影片"), systemImage: "plus") }
                    .keyboardShortcut("o", modifiers: .command)
                Divider().frame(height: 18).padding(.horizontal, 4)
                Button(action: pickFolder) { Image(systemName: "folder.badge.plus") }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .help(L("加入整個資料夾（⇧⌘O）")).accessibilityLabel(L("加入資料夾"))
            }
            .buttonStyle(.borderless).controlSize(.large)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .modifier(ControlSurface())
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 22)
    }

    private var missingTools: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(L("需要先安裝轉檔工具")).fontWeight(.medium)
                Text(L("缺少 FFmpeg 或 ffprobe，安裝完成後即可開始轉檔。"))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button(L("安裝與檢查")) { showingToolSetup = true }
        }
        .padding(14).background(Color.orange.opacity(0.08))
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("轉檔佇列")).font(.system(size: 14, weight: .semibold))
                Text("\(store.jobs.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !store.jobs.isEmpty {
                    Text(ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 24).padding(.vertical, 15)
            if store.jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.jobs) { job in
                            JobRow(job: job).environmentObject(store)
                            if job.id != store.jobs.last?.id { Divider().padding(.leading, 76) }
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text(L("隨時拖入更多影片或資料夾"))
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(13)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 20)
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.blue).padding(.bottom, 8)
                .accessibilityHidden(true)
            Text(L("把影片拖到這裡"))
                .font(.system(size: 24, weight: .semibold))
            Text(L("TS、MKV、MOV 等影片，都能轉成 MP4。"))
                .font(.callout).foregroundStyle(.secondary)
            Button(L("選擇影片…"), action: pickFiles)
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
            Button(L("或加入整個資料夾"), action: pickFolder)
                .buttonStyle(.link).font(.callout)
            Spacer(minLength: 24)
            Text((store.forceH264 || store.trimEnabled) ? L("強制輸出 H.264，原始影片會保留。") : L("優先無損轉換，原始影片會保留。"))
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func trimField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .accessibilityLabel(title)
                .help(L("秒數，可輸入小數，例如 1.5。"))
            Text(L("秒")).foregroundStyle(.secondary)
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("輸出設定")).font(.system(size: 14, weight: .semibold))
                HStack(spacing: 12) {
                    Text("MP4")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                        .frame(width: 62, height: 56)
                        .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("相容常見播放器")).font(.callout).fontWeight(.medium)
                        Text((store.forceH264 || store.trimEnabled) ? L("H.264 影片與 AAC 音訊") : L("優先保留原始畫質")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("儲存位置")).font(.callout).fontWeight(.medium)
                    Label(outputName, systemImage: "folder")
                        .font(.callout).lineLimit(2)
                        .help(store.outputToSource ? L("每支影片旁的來源資料夾") : store.customOutputDir?.path ?? "")
                    Menu {
                        Button(L("與來源影片相同")) { store.outputToSource = true }
                        Button(L("選擇資料夾…"), action: pickOutputDir)
                    } label: { Text(L("更改位置…")) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(store.isRunning)
                    Text(store.outputToSource ? L("MP4 會放在各自的原始影片旁。") : store.customOutputDir?.path ?? L("請選擇輸出資料夾。"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L("加入後立即轉換"), isOn: $store.autoStart)
                    Text(L("關閉時，可先確認清單和儲存位置。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch).controlSize(.small).disabled(store.isRunning)
                Divider()
                DisclosureGroup(L("進階選項"), isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(L("裁切開頭／結尾"), isOn: $store.trimEnabled)
                        if store.trimEnabled {
                            VStack(alignment: .leading, spacing: 10) {
                                trimField(L("剪掉開頭"), text: $store.trimStartText)
                                trimField(L("剪掉結尾"), text: $store.trimEndText)
                                Text(L("套用至本次佇列，裁切後重新轉為 H.264 MP4。原始影片保留，另存為 _trimmed.mp4。"))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let error = store.trimInputError {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        Toggle(L("允許覆蓋既有 MP4"), isOn: $store.overwrite)
                        Toggle(L("強制 H.264"), isOn: $store.forceH264)
                            .disabled(store.trimEnabled)
                        if store.forceH264 {
                            Text(L("輸出 H.264 影片與 AAC 音訊。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle(L("必要時重新編碼影片"), isOn: $store.allowReencode)
                            .disabled(store.forceH264 || store.trimEnabled)
                        Text(L("音訊修復會自動嘗試。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle(L("使用硬體加速"), isOn: $store.hardwareAccel)
                            .disabled(!store.allowReencode && !store.forceH264 && !store.trimEnabled)
                        Text(L("僅在重新編碼時使用。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.toggleStyle(.checkbox).padding(.top, 12)
                }
                .font(.callout).disabled(store.isRunning)
                Spacer(minLength: 0)
            }.padding(20)
            }
            Divider().padding(.horizontal, 20)
            Button { showingAppearance = true } label: {
                HStack {
                    Label(L("外觀"), systemImage: "circle.lefthalf.filled")
                    Spacer()
                    Text(access.effectiveAppearance.title).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).font(.callout)
            .padding(.horizontal, 20).padding(.top, 14)
            Picker(L("語言"), selection: $store.appLanguage) {
                Text(L("跟隨系統")).tag("system")
                Text("繁體中文").tag("zh-Hant")
                Text("English").tag("en")
            }
            .pickerStyle(.menu).font(.callout)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) {
                    Text("© 2026 JimmyLC").foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 0)
                    thanksButton
                    Spacer(minLength: 0)
                    aboutButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("© 2026 JimmyLC").foregroundStyle(.secondary)
                    HStack {
                        thanksButton
                        Spacer()
                        aboutButton
                    }
                }
            }
            .font(.caption).padding(.horizontal, 20).padding(.bottom, 16)
        }
    }

    private var thanksButton: some View {
        Button { showingThanks = true } label: {
            HStack(spacing: 4) {
                SuperThanksIcon(size: 14)
                Text(L("超級感謝")).fontWeight(.medium).fixedSize()
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
    }

    private var aboutButton: some View {
        Button(L("關於與授權")) { showingAbout = true }
            .buttonStyle(.link).fixedSize()
    }

    private var actionShelf: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary).font(.callout).fontWeight(.medium)
                    .lineLimit(1).accessibilityLabel(String(format: L("佇列狀態：%@"), summary))
                if store.isRunning {
                    ProgressView(value: store.overallProgress)
                        .progressViewStyle(.linear).frame(maxWidth: 260)
                        .accessibilityLabel(L("整體進度"))
                } else if let message = store.flashMessage {
                    Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else {
                    Text(store.failedCount > 0 ? L("失敗的影片可在清單中重試。") : L("輸出為 MP4，原始檔案不會移除。"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if store.finishedCount > 0 {
                Button(L("移除已完成")) { store.clearFinished() }
                    .buttonStyle(.borderless).font(.callout)
                    .help(L("移除完成與略過的項目，保留失敗項目"))
            }
            if store.isRunning {
                Button { store.stop() } label: { Label(L("停止轉檔"), systemImage: "stop.fill") }
                    .buttonStyle(.bordered).controlSize(.large)
                    .help(L("停止目前轉檔，保留既有輸出與等待中的影片"))
            } else {
                Button { store.start() } label: {
                    Label(store.hasWaiting ? String(format: L("開始轉檔（%d）"), store.waitingCount) : L("開始轉檔"), systemImage: "arrow.right")
                }
                .buttonStyle(PrimaryActionStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!store.hasWaiting || !toolsAvailable || store.trimInputError != nil)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .modifier(ControlSurface())
    }

    private var summary: String {
        if store.jobs.isEmpty { return L("準備好你的影片") }
        if store.isRunning { return String(format: L("轉檔中 · 已處理 %d / %d"), store.processedCount, store.jobs.count) }
        if store.hasWaiting { return String(format: L("%d 支影片準備轉檔"), store.waitingCount) }
        if store.failedCount > 0 { return String(format: L("%d 支完成，%d 支需要處理"), store.doneCount, store.failedCount) }
        return String(format: L("已處理全部 %d 支影片"), store.jobs.count)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup(), lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url { lock.lock(); urls.append(url); lock.unlock() }
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { store.add(urls: urls) } }
        return true
    }

    private func pickFiles() { pickInput(folder: false) }
    private func pickFolder() { pickInput(folder: true) }
    private func pickInput(folder: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.message = folder ? L("選擇包含影片的資料夾") : L("選擇要轉成 MP4 的影片")
        panel.prompt = L("加入佇列")
        if !folder {
            panel.allowedContentTypes = JobStore.videoExtensions.compactMap { UTType(filenameExtension: $0) }
        }
        if panel.runModal() == .OK { store.add(urls: panel.urls) }
    }
    private func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = L("選擇 MP4 儲存位置")
        panel.prompt = L("選擇位置")
        if panel.runModal() == .OK, let url = panel.urls.first {
            store.customOutputDir = url
            store.outputToSource = false
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    @EnvironmentObject var store: JobStore
    private var busy: Bool {
        switch job.status { case .probing, .converting: return true; default: return false }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "film")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary).frame(width: 36, height: 42)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(job.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .help(job.url.path)
                Text(metadata).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: statusSymbol)
                    Text(statusText).id(statusText).textSelection(.enabled)
                }
                .font(.caption).foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
                if case .converting(let percent, _, _) = job.status {
                    if percent >= 0 {
                        ProgressView(value: percent, total: 100).progressViewStyle(.linear)
                            .accessibilityLabel(String(format: L("%@ 轉檔進度"), job.url.lastPathComponent))
                    } else { ProgressView().controlSize(.small).accessibilityLabel(L("轉檔中")) }
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                if case .done = job.status {
                    Button(action: reveal) { Image(systemName: "folder") }
                        .help(L("在 Finder 中顯示 MP4")).accessibilityLabel(L("顯示轉出的 MP4"))
                }
                if case .failed = job.status {
                    Button(L("重試")) { store.retry(job) }.disabled(store.isRunning)
                }
                if !busy {
                    Button { store.remove(job) } label: { Image(systemName: "xmark") }
                        .foregroundStyle(.secondary).help(L("從佇列移除，不會刪除檔案"))
                        .accessibilityLabel(String(format: L("從佇列移除 %@"), job.url.lastPathComponent))
                }
            }.buttonStyle(.borderless).controlSize(.small).padding(.top, 3)
        }
        .padding(.horizontal, 24).padding(.vertical, 17)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: reveal)
        .contextMenu {
            Button(L("在 Finder 中顯示"), action: reveal)
            if !busy { Button(L("從佇列移除")) { store.remove(job) } }
        }
    }
    private var metadata: String {
        let size = ByteCountFormatter.string(fromByteCount: job.size, countStyle: .file)
        let duration = job.duration.map { " · \($0 < 1 ? formatElapsed($0) : formatDuration($0))" } ?? ""
        return "\(job.url.pathExtension.uppercased()) → MP4 · \(size)\(duration)"
    }
    private var statusText: String {
        switch job.status {
        case .waiting: return L("等待轉檔")
        case .probing: return L("正在讀取影片…")
        case .converting(let percent, let speed, let label):
            let progress = percent < 0 ? "" : String(format: " · %.0f%%", percent)
            return label + progress + (speed.isEmpty ? "" : " · \(speed)")
        case .done(let strategy, let elapsed): return String(format: L("%@完成 · %@"), strategy, formatElapsed(elapsed))
        case .failed(let message): return String(format: L("轉檔失敗：%@"), message)
        case .skipped(let message): return String(format: L("已略過：%@"), message)
        }
    }
    private var statusSymbol: String {
        switch job.status {
        case .waiting: return "clock"
        case .probing, .converting: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }
    private var statusColor: Color {
        switch job.status {
        case .done: return .green
        case .failed: return .red
        case .skipped: return .secondary
        case .probing, .converting: return .blue
        case .waiting: return .secondary
        }
    }
    private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([job.outURL ?? job.url]) }
}

private struct AboutView: View {
    @EnvironmentObject private var access: AppAccess
    @Environment(\.dismiss) private var dismiss
    @State private var licenseExpanded = false

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return L("原始碼公開，非商業用途免費。禁止商業用途。")
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("MacMP4").font(.system(size: 26, weight: .semibold))
                PlanBadge(tier: access.tier)
            }
            Text("Copyright © 2026 JimmyLC").font(.callout)
            HStack {
                Text(L("開發者：JimmyLC"))
                Spacer()
                Link("jimmy-tools.com", destination: URL(string: "https://jimmy-tools.com/")!)
            }.font(.callout)
            Divider()
            Text(L("原始碼公開，非商業用途免費。禁止商業用途。"))
                .font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(L("可研究、修改與分享，須保留版權及授權聲明。商業用途須另行取得書面授權。"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L("完整授權條款"), isExpanded: $licenseExpanded) {
                ScrollView {
                    Text(licenseText).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }.frame(height: 180)
            }.font(.callout)
            HStack {
                Spacer()
                Button(L("關閉")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(28).frame(width: 480)
    }
}
