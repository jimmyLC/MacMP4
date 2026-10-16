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
      --no-reencode     停用「失敗時自動重新編碼」的最後手段
      --no-gpu          重新編碼時不使用 GPU 硬體加速(改用 CPU)
      -h, --help        顯示說明
    """)
}

var inputs: [URL] = []
var outDir: URL?
var overwrite = true
var allowReencode = true
var hardwareAccel = true

let args = CommandLine.arguments
var i = 1
while i < args.count {
    switch args[i] {
    case "--out":
        i += 1
        if i < args.count { outDir = URL(fileURLWithPath: args[i]) }
    case "--no-overwrite":
        overwrite = false
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

guard !inputs.isEmpty else {
    printUsage()
    exit(1)
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
for (idx, input) in files.enumerated() {
    let fm = FileManager.default
    let out: URL
    if let dir = outDir {
        out = dir.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".mp4")
    } else {
        out = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".mp4")
    }

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
    let strategies = FF.strategies(for: probe, allowReencode: allowReencode, hardwareAccel: hardwareAccel)
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
        if ok, let outProbe = FF.probe(url: transaction.temporaryURL, ffprobe: ffprobe), outProbe.isValidOutput {
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
