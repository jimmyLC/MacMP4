// main.swift — 命令列版(GUI 的同一顆引擎)
import Foundation

func printUsage() {
    print("""
    MacMP4 CLI — 影片無損轉 MP4(自動修復壞檔)

    用法:
      macmp4-cli [選項] 檔案或資料夾...

    選項:
      --out <目錄>      指定輸出資料夾(預設:與來源同資料夾)
      --no-overwrite    輸出檔已存在時略過(預設覆蓋)
      --force-h264     強制輸出 H.264 影片與 AAC 音訊(預設關閉)
      --no-reencode     停用「失敗時自動重新編碼」的最後手段
      --no-gpu          重新編碼時不使用 GPU 硬體加速(改用 CPU)
      -h, --help        顯示說明
    """)
    print("Copyright © 2026 JimmyLC · https://jimmy-tools.com/")
    print(L("原始碼公開，非商業用途免費。禁止商業用途。"))
}

var inputs: [URL] = []
var outDir: URL?
var overwrite = true
var forceH264 = false
var allowReencode = true
var hardwareAccel = true

let args = CommandLine.arguments
var i = 1
while i < args.count {
    switch args[i] {
    case "--out":
        i += 1
        guard i < args.count else {
            FileHandle.standardError.write(Data("--out 需要指定資料夾。\n".utf8))
            exit(2)
        }
        outDir = URL(fileURLWithPath: args[i])
    case "--no-overwrite":
        overwrite = false
    case "--force-h264":
        forceH264 = true
    case "--no-reencode":
        allowReencode = false
    case "--no-gpu":
        hardwareAccel = false
    case "-h", "--help":
        printUsage()
        exit(0)
    default:
        inputs.append(URL(fileURLWithPath: args[i]))
    }
    i += 1
}

if forceH264 && !allowReencode {
    FileHandle.standardError.write(Data("--force-h264 不能與 --no-reencode 同時使用。\n".utf8))
    exit(2)
}

guard !inputs.isEmpty else {
    printUsage()
    exit(1)
}

if let dir = outDir {
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    catch {
        FileHandle.standardError.write(Data("無法建立輸出資料夾:\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// Ctrl+C / kill skip deinit, which would leave the hidden staging folder behind.
var activeTransaction: OutputTransaction?
let signalLock = NSLock()
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler {
        signalLock.lock(); let transaction = activeTransaction; signalLock.unlock()
        transaction?.cleanup()
        exit(128 + sig)
    }
    source.resume()
    signalSources.append(source)
}

guard let ffmpeg = FF.findTool("ffmpeg"), let ffprobe = FF.findTool("ffprobe") else {
    FileHandle.standardError.write("找不到 ffmpeg/ffprobe。請先執行:brew install ffmpeg\n".data(using: .utf8)!)
    exit(1)
}

// 展開資料夾
let videoExts = supportedVideoExtensions
var files: [URL] = []
for u in inputs {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else {
        FileHandle.standardError.write("跳過(不存在):\(u.path)\n".data(using: .utf8)!)
        continue
    }
    if isDir.boolValue {
        if let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let f as URL in en where videoExts.contains(f.pathExtension.lowercased()) {
                files.append(f)
            }
        }
    } else {
        files.append(u)
    }
}

guard !files.isEmpty else {
    print("沒有找到可轉換的影片檔")
    exit(1)
}

var failures = 0
var claimed = Set<String>()
for (idx, input) in files.enumerated() {
    let fm = FileManager.default
    let name = input.deletingPathExtension().lastPathComponent + ".mp4"
    // Same-named inputs (a.ts + a.mkv, or equal names from different folders) get "a 2.mp4".
    let out = uniqueOutputURL((outDir ?? input.deletingLastPathComponent()).appendingPathComponent(name), claimed: claimed)

    print("[\(idx + 1)/\(files.count)] \(input.lastPathComponent)")

    let ext = input.pathExtension.lowercased()
    if ext == "mp4" || ext == "m4v" {
        print("    略過:已是 MP4 格式")
        continue
    }
    if fm.fileExists(atPath: out.path) && !overwrite {
        print("    略過:輸出檔已存在 (\(out.lastPathComponent))")
        continue
    }

    guard let probe = FF.probe(url: input, ffprobe: ffprobe) else {
        print("    ✗ 無法讀取檔案")
        failures += 1
        continue
    }
    let strategies = FF.strategies(for: probe, allowReencode: allowReencode, hardwareAccel: hardwareAccel, forceH264: forceH264)
    if strategies.isEmpty {
        print("    ✗ 影片編碼 \(probe.videoCodec ?? "?") 無法封裝成 MP4(可移除 --no-reencode)")
        failures += 1
        continue
    }

    let transaction: OutputTransaction
    do { transaction = try OutputTransaction(destination: out, overwrite: overwrite) }
    catch {
        print("    ✗ \(error.localizedDescription)")
        failures += 1
        continue
    }
    claimed.insert(out.standardizedFileURL.path)
    signalLock.lock(); activeTransaction = transaction; signalLock.unlock()
    defer { signalLock.lock(); activeTransaction = nil; signalLock.unlock() }
    var succeeded = false
    let t0 = Date()
    for strategy in strategies {
        print("    → \(strategy.label)…")
        var lastPrint = Date.distantPast
        let ok = FF.run(ffmpeg: ffmpeg, input: input, output: transaction.temporaryURL, strategy: strategy, duration: probe.duration) { pct, speed in
            // 每 0.5 秒最多更新一次終端機
            let now = Date()
            guard now.timeIntervalSince(lastPrint) > 0.5 else { return }
            lastPrint = now
            let p = pct < 0 ? "  …  " : String(format: "%5.1f%%", pct)
            let s = speed.isEmpty ? "" : "  \(speed)"
            print("\r         \(p)\(s)          ", terminator: "")
            fflush(stdout)
        }
        print("\r" + String(repeating: " ", count: 40) + "\r", terminator: "")
        if ok, let outProbe = FF.probe(url: transaction.temporaryURL, ffprobe: ffprobe), FF.outputIsValid(outProbe, forceH264: forceH264) {
            do { try transaction.commit() }
            catch {
                print("    ✗ 無法儲存輸出: \(error.localizedDescription)")
                break
            }
            var durStr = ""
            if let d = outProbe.duration { durStr = "(\(formatDuration(d)))" }
            print("    ✓ 完成 \(durStr) → \(out.lastPathComponent),耗時 \(formatElapsed(Date().timeIntervalSince(t0)))")
            succeeded = true
            break
        }
        transaction.discardAttempt()
    }
    if !succeeded {
        print("    ✗ 轉換失敗(來源檔可能損壞)")
        failures += 1
    }
}
exit(failures == 0 ? 0 : 1)
