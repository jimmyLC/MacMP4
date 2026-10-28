// Model.swift — 佇列與批次轉換邏輯
import Foundation
import Combine
import AppKit

enum JobStatus: Equatable {
    case waiting
    case probing
    case converting(percent: Double, speed: String, label: String)
    case done(strategy: String, elapsed: Double)
    case failed(String)
    case skipped(String)
}

final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    @Published var status: JobStatus = .waiting
    @Published var duration: Double?
    @Published var outURL: URL?
    /// Redacted diagnostics for the problem-report form; only read and written on the main thread.
    var failureLog = ""

    init(url: URL) {
        self.url = url
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

final class JobStore: ObservableObject {
    static let shared = JobStore()

    @Published private(set) var ffmpeg: String?
    @Published private(set) var ffprobe: String?

    @Published var jobs: [Job] = []
    @Published var isRunning = false
    @Published var outputToSource = true
    @Published var customOutputDir: URL?
    @Published var overwrite = false
    @Published var forceH264 = false
    @Published var trimEnabled = false
    @Published var trimStartText = "0"
    @Published var trimEndText = "0"
    /// Settings are copied once when a batch starts, so toggling the UI mid-batch cannot
    /// change files already queued, and the worker never reads @Published state.
    private struct RunOptions {
        var outputToSource = true
        var customOutputDir: URL?
        var overwrite = false
        var forceH264 = false
        var allowReencode = true
        var hardwareAccel = true
        var trim: ClipTrim?
    }
    private var runOptions = RunOptions()
    private let optionsLock = NSLock()
    private var activeOptions: RunOptions {
        get { optionsLock.lock(); defer { optionsLock.unlock() }; return runOptions }
        set { optionsLock.lock(); defer { optionsLock.unlock() }; runOptions = newValue }
    }
    /// Output paths claimed in the current batch (worker queue only).
    private var claimedOutputs: [UUID: String] = [:]

    var trimInputError: String? {
        guard trimEnabled else { return nil }
        do { _ = try ClipTrim(startText: trimStartText, endText: trimEndText); return nil }
        catch { return error.localizedDescription }
    }
    @Published var allowReencode = true
    @Published var hardwareAccel = true
    @Published var autoStart = false
    @Published var flashMessage: String?
    @Published var appLanguage: String = UserDefaults.standard.string(forKey: "AppLanguage") ?? "system" {
        didSet {
            guard oldValue != appLanguage else { return }
            if appLanguage == "system" {
                UserDefaults.standard.removeObject(forKey: "AppLanguage")
            } else {
                UserDefaults.standard.set(appLanguage, forKey: "AppLanguage")
            }
            flash(L("語言已切換,重新開啟 App 後全部生效"))
        }
    }

    private var jobObservers: [UUID: AnyCancellable] = [:]
    private var pending: [Job] = []
    private var pendingIDs = Set<UUID>()
    private let lock = NSLock()
    private let stopLock = NSLock()
    private var stopped = false
    private var stopRequested: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return stopped }
        set { stopLock.lock(); defer { stopLock.unlock() }; stopped = newValue }
    }
    private var currentProcess: Process?
    private var procLock = NSLock()
    private let worker = DispatchQueue(label: "macmp4.worker", qos: .userInitiated)

    static let videoExtensions: Set<String> = supportedVideoExtensions

    init(ffmpeg: String? = FF.findTool("ffmpeg"), ffprobe: String? = FF.findTool("ffprobe")) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    /// Recheck after setup or returning to the app; never change tools during a batch.
    func refreshTools(find: (String) -> String? = FF.findTool) {
        guard !isRunning else { return }
        ffmpeg = find("ffmpeg")
        ffprobe = find("ffprobe")
    }

    // MARK: - 對外操作(全部在主執行緒呼叫)

    var hasWaiting: Bool {
        jobs.contains { if case .waiting = $0.status { return true } else { return false } }
    }

    var doneCount: Int {
        jobs.filter { if case .done = $0.status { return true } else { return false } }.count
    }

    var waitingCount: Int { jobs.filter { $0.status == .waiting }.count }
    var failedCount: Int { jobs.filter { if case .failed = $0.status { return true }; return false }.count }
    var finishedCount: Int {
        jobs.filter { switch $0.status { case .done, .skipped: return true; default: return false } }.count
    }
    var processedCount: Int { finishedCount + failedCount }
    var totalBytes: Int64 { jobs.reduce(0) { $0 + $1.size } }

    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        var total = 0.0
        for j in jobs {
            switch j.status {
            case .done, .failed, .skipped: total += 1
            case .converting(let p, _, _): total += max(0, p) / 100
            default: break
            }
        }
        return total / Double(jobs.count)
    }

    func add(urls: [URL]) {
        var existing = Set(jobs.map { $0.url.standardizedFileURL.path })
        var newJobs: [Job] = []
        var ignored = 0
        var capped = false

        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let en = FileManager.default.enumerator(
                    at: u,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    var count = 0
                    for case let f as URL in en {
                        if count >= 2000 { capped = true; break }
                        guard Self.videoExtensions.contains(f.pathExtension.lowercased()) else { continue }
                        let key = f.standardizedFileURL.path
                        if existing.contains(key) { continue }
                        existing.insert(key)
                        newJobs.append(Job(url: f))
                        count += 1
                    }
                }
            } else {
                if Self.videoExtensions.contains(u.pathExtension.lowercased()) {
                    let key = u.standardizedFileURL.path
                    if !existing.contains(key) {
                        existing.insert(key)
                        newJobs.append(Job(url: u))
                    }
                } else {
                    ignored += 1
                }
            }
        }

        newJobs.sort {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        for job in newJobs {
            jobObservers[job.id] = job.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
        if !newJobs.isEmpty { jobs.append(contentsOf: newJobs) }
        if capped { flash(L("資料夾內影片超過 2000 個，只加入前 2000 個")) }
        else if ignored > 0 { flash(String(format: L("已忽略 %d 個不支援的檔案"), ignored)) }
        if autoStart { start() }
    }

    func start() {
        guard ffmpeg != nil, ffprobe != nil else { return }
        if !isRunning {
            let trim: ClipTrim?
            do { trim = trimEnabled ? try ClipTrim(startText: trimStartText, endText: trimEndText) : nil }
            catch { flash(error.localizedDescription); return }
            activeOptions = RunOptions(outputToSource: outputToSource, customOutputDir: customOutputDir,
                                       overwrite: overwrite, forceH264: forceH264, allowReencode: allowReencode,
                                       hardwareAccel: hardwareAccel, trim: trim)
        }
        enqueueNew()
        if !isRunning, hasPending() {
            isRunning = true
            stopRequested = false
            worker.async { [weak self] in self?.runLoop() }
        }
    }

    func stop() {
        stopRequested = true
        procLock.lock()
        let p = currentProcess
        procLock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    func remove(_ job: Job) {
        switch job.status { case .probing, .converting: return; default: break }
        jobObservers.removeValue(forKey: job.id)
        jobs.removeAll { $0.id == job.id }
        lock.lock()
        pending.removeAll { $0.id == job.id }
        pendingIDs.remove(job.id)
        lock.unlock()
    }

    func retry(_ job: Job) {
        if case .failed = job.status {
            job.status = .waiting
            start()
        }
    }

    func clearFinished() {
        jobs.removeAll { j in
            switch j.status {
            case .done, .skipped:
                jobObservers.removeValue(forKey: j.id)
                return true
            default: return false
            }
        }
    }

    // MARK: - 內部

    private func flash(_ s: String) {
        flashMessage = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.flashMessage == s { self?.flashMessage = nil }
        }
    }

    private func enqueueNew() {
        lock.lock()
        defer { lock.unlock() }
        for j in jobs {
            if case .waiting = j.status, !pendingIDs.contains(j.id) {
                pending.append(j)
                pendingIDs.insert(j.id)
            }
        }
    }

    private func hasPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    private func nextPending() -> Job? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let j = pending.removeFirst()
        pendingIDs.remove(j.id)
        return j
    }

    private func runLoop() {
        while !stopRequested {
            guard let job = nextPending() else { break }
            guard !stopRequested else { setStatus(job, .waiting); break }
            process(job)
        }
        claimedOutputs.removeAll()
        DispatchQueue.main.async {
            self.isRunning = false
            self.procLock.lock(); self.currentProcess = nil; self.procLock.unlock()
            if !self.stopRequested, self.hasPending() { self.start() }
        }
    }

    private func setStatus(_ job: Job, _ s: JobStatus) {
        DispatchQueue.main.async { job.status = s }
    }

    /// Stores redacted diagnostics for a failed job. Called before the failed status so the
    /// report button never shows without its log.
    private func recordFailure(_ job: Job, _ lines: [String]) {
        let log = ReportProblem.redact(lines.joined(separator: "\n"), input: job.url)
        DispatchQueue.main.async { job.failureLog = String(log.suffix(ReportProblem.maxLogCharacters)) }
    }

    private func track(_ process: Process) {
        procLock.lock()
        currentProcess = process
        procLock.unlock()
        // Covers Stop arriving between the worker's check and process launch.
        if stopRequested, process.isRunning { process.terminate() }
    }

    private func probe(_ url: URL, using ffprobe: String) -> ProbeResult? {
        defer { procLock.lock(); currentProcess = nil; procLock.unlock() }
        return FF.probe(url: url, ffprobe: ffprobe, didStart: { [weak self] in self?.track($0) })
    }

    private func process(_ job: Job) {
        guard let ffmpeg, let ffprobe else { return }
        let fm = FileManager.default
        let ext = job.url.pathExtension.lowercased()
        let options = activeOptions
        let trim = options.trim
        let overwrite = options.overwrite
        let encodeH264 = options.forceH264 || trim != nil

        if trim == nil && (ext == "mp4" || ext == "m4v") {
            setStatus(job, .skipped(L("已是 MP4 格式")))
            return
        }

        let outDir: URL
        if options.outputToSource || options.customOutputDir == nil {
            outDir = job.url.deletingLastPathComponent()
        } else {
            outDir = options.customOutputDir!
        }
        let wanted = outDir.appendingPathComponent(job.url.deletingPathExtension().lastPathComponent + (trim == nil ? ".mp4" : "_trimmed.mp4"))
        let others = Set(claimedOutputs.filter { $0.key != job.id }.values)
        let outURL = uniqueOutputURL(wanted, claimed: others)

        if fm.fileExists(atPath: outURL.path) && !overwrite {
            setStatus(job, .skipped(L("輸出檔已存在")))
            return
        }

        let startTime = Date()
        setStatus(job, .probing)
        guard let probe = self.probe(job.url, using: ffprobe) else {
            if !stopRequested { recordFailure(job, ["macmp4: ffprobe could not read the file (.\(ext))"]) }
            setStatus(job, stopRequested ? .waiting : .failed(L("無法讀取檔案")))
            return
        }
        DispatchQueue.main.async { job.duration = probe.duration }
        guard probe.hasVideo || probe.hasAudio else {
            recordFailure(job, ["macmp4: no audio or video stream found (.\(ext))"])
            setStatus(job, .failed(L("找不到影音串流")))
            return
        }

        if encodeH264 && !probe.hasVideo {
            setStatus(job, .failed(L("強制 H.264 需要來源包含影片串流。")))
            return
        }
        let range: ClipRange?
        do { range = try trim?.resolve(duration: probe.duration) }
        catch { setStatus(job, .failed(error.localizedDescription)); return }
        let strategies = FF.strategies(for: probe, allowReencode: options.allowReencode, hardwareAccel: options.hardwareAccel, forceH264: encodeH264)
        if strategies.isEmpty {
            recordFailure(job, ["macmp4: video codec \(probe.videoCodec ?? "?") cannot be remuxed to MP4 and re-encoding is off"])
            setStatus(job, .failed(String(format: L("影片編碼 %@ 無法直接封裝成 MP4，請開啟「必要時重新編碼影片」。"), probe.videoCodec ?? "?")))
            return
        }

        claimedOutputs[job.id] = outURL.standardizedFileURL.path
        let transaction: OutputTransaction
        do { transaction = try OutputTransaction(destination: outURL, overwrite: overwrite) }
        catch {
            recordFailure(job, ["macmp4: could not prepare the output location: \(error.localizedDescription)"])
            setStatus(job, .failed(error.localizedDescription))
            return
        }

        var attemptLogs: [String] = []
        let sourceSummary = "source: .\(ext), video \(probe.videoCodec ?? "none"), audio \(probe.audioCodec ?? "none")"
        for strategy in strategies {
            if stopRequested { setStatus(job, .waiting); return }

            setStatus(job, .converting(percent: probe.duration == nil ? -1 : 0, speed: "", label: strategy.label))

            let ok = FF.run(ffmpeg: ffmpeg, input: job.url, output: transaction.temporaryURL, strategy: strategy,
                            duration: range?.duration ?? probe.duration, trim: range,
                            didStart: { [weak self] p in
                                self?.track(p)
                            },
                            progress: { [weak self] pct, speed in
                                self?.setStatus(job, .converting(percent: pct, speed: speed, label: strategy.label))
                            },
                            errorOutput: { output in
                                attemptLogs.append("[\(strategy.label)]\n" + ReportProblem.tail(output, lines: 8, maxCharacters: 1200))
                            })

            procLock.lock(); currentProcess = nil; procLock.unlock()

            if stopRequested { setStatus(job, .waiting); return }
            if ok, let outProbe = self.probe(transaction.temporaryURL, using: ffprobe), FF.outputIsValid(outProbe, forceH264: encodeH264), range?.matches(outProbe) ?? true {
                if stopRequested { setStatus(job, .waiting); return }
                do { try transaction.commit() }
                catch {
                    recordFailure(job, ["macmp4: could not save the output: \(error.localizedDescription)"])
                    setStatus(job, .failed(String(format: L("無法儲存輸出: %@"), error.localizedDescription)))
                    return
                }
                DispatchQueue.main.async { job.outURL = outURL }
                setStatus(job, .done(strategy: strategy.label, elapsed: Date().timeIntervalSince(startTime)))
                return
            }

            transaction.discardAttempt()
            if stopRequested { setStatus(job, .waiting); return }
        }

        recordFailure(job, [sourceSummary] + attemptLogs)
        setStatus(job, .failed(L("轉換失敗(來源檔可能損壞)")))
    }
}
