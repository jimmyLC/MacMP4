# MacMP4

**Mac 影片快速轉 MP4:無損、可批次、會自動修復壞檔。**

把 `.ts`(或其他常見影片格式)拖進來就能轉成 `.mp4` — 不重編碼、零畫質損失,速度通常是播放長度的數百倍。

[English README →](README.md)

---

## 為什麼需要它?

`.ts`(MPEG-TS)檔案 — 電視錄影、串流下載 — 常常在 QuickTime 開不起來、播放卡頓或拖曳異常。正確的解法是 **remux**(重新封裝成 MP4 容器,不動影音內容),但:

- 用命令列打 ffmpeg 很麻煩
- 檔案只要有一個壞封包,整個轉換就會中斷

MacMP4 把「快速 remux 引擎 + 容錯自動降級」包成一個小小的原生 Mac App。

## 功能

- 🚀 **無損、極快** — 影音直接複製位元流,完全不重編碼。實測 1.2 GB / 1 小時 46 分影片約 60 秒轉完,CPU 幾乎閒置(瓶頸在磁碟)
- 🗂 **批次佇列** — 檔案或整個資料夾拖進去,逐檔顯示進度與速度,完成可一鍵在 Finder 顯示
- 🩹 **自動修復** — 每支影片依序嘗試,直到成功為止:
  1. **無損封裝**(`-c copy`)
  2. **修復音訊** — 影片複製、音訊重新編碼(專門解決「壞掉的 AAC 幀導致轉換中斷」這個經典問題)
  3. **整檔重新編碼** — 先試 GPU,失敗自動退回 CPU
- 🧯 **容錯** — 損壞封包自動跳過(`-err_detect ignore_err -fflags +discardcorrupt`),不會因一顆老鼠屎整鍋倒掉
- 🎛 **GPU 硬體加速** — 重新編碼時預設使用 Apple **VideoToolbox** 硬體編碼器(`h264_videotoolbox`),失敗自動退回 CPU x264(CRF 18)
- 📁 輸出預設**同來源資料夾**,也可自選
- ⌨️ 附**命令列版**,方便寫腳本

## 支援的輸入格式

`ts · m2ts · mts · tp · trp · mkv · flv · f4v · avi · mov · wmv · webm · mpg · mpeg · vob · rm · rmvb · ogv · 3gp · asf · mxf · dv …`

MP4 相容的編碼(H.264 / H.265 / AV1 影片;AAC / MP3 / AC3 / E-AC3 / ALAC 音訊)走無損封裝;其他則進入重新編碼流程。

## 系統需求

- macOS 13 (Ventura) 以上
- [ffmpeg](https://ffmpeg.org) — `brew install ffmpeg`

## 建置與執行

```bash
git clone https://github.com/jimmyLC/MacMP4.git
cd MacMP4
./build.sh
open build/MacMP4.app
```

安裝到「應用程式」:

```bash
cp -R build/MacMP4.app /Applications/
```

建置產出:

- `build/MacMP4.app` — GUI 主程式
- `build/macmp4-cli` — 命令列版

## 使用方式(GUI)

1. 開啟 `MacMP4.app`
2. 把影片檔 / 資料夾拖進視窗(或用「加入檔案」「加入資料夾」按鈕)
3. 預設自動開始轉換(可關);逐檔顯示進度與速度
4. 完成後點列尾的資料夾圖示,直接在 Finder 查看結果

選項:輸出位置、是否覆蓋已存在的 MP4、失敗時自動重新編碼、GPU 硬體加速。

> 小技巧:Finder 對 `.ts` 檔右鍵 →「打開方式」→ MacMP4。

## 使用方式(CLI)

```bash
macmp4-cli video.ts                       # → 同資料夾的 video.mp4
macmp4-cli --out ~/Movies folder/*.ts     # 指定輸出資料夾
macmp4-cli --no-overwrite a.ts b.mkv      # 已存在則略過
macmp4-cli --no-gpu --no-reencode x.ts    # 嚴格模式:只做複製類轉換
```

| 選項 | 說明 |
|---|---|
| `--out <目錄>` | 輸出資料夾(預設:與來源相同) |
| `--no-overwrite` | 輸出檔已存在時略過 |
| `--no-reencode` | 停用「整檔重新編碼」最後手段 |
| `--no-gpu` | 改用 CPU x264(不使用 VideoToolbox) |

## 硬體加速說明

remux 不做任何解碼/編碼,是純 I/O 工作,速度已是磁碟上限 — GPU 在這裡無事可做。GPU 只對**重新編碼**這條救援路徑有意義(例如 MPEG-2 電視錄影這種無法封裝成 MP4 的來源):

| 路徑 | 實際工作 | 加速方式 |
|---|---|---|
| 無損封裝 | 無(直接複製) | 已達磁碟速度上限 |
| 修復音訊 | 僅 AAC 編碼 | 多執行緒(耗費極小) |
| 整檔重新編碼 | 解碼 + 編碼影片 | **VideoToolbox GPU / 媒體引擎**,失敗退回 CPU x264 |

## 運作原理

1. `ffprobe` 檢查編碼格式與長度
2. 依 MP4 相容性排出轉換策略清單
3. 每個策略都帶 `-err_detect ignore_err -fflags +discardcorrupt -movflags +faststart` 執行
4. 產出檔案會再次用 ffprobe 驗證,確認有效才算成功

## 專案結構

```
Sources/Engine.swift    ffprobe/ffmpeg 核心(無 UI 依賴)
Sources/Model.swift     批次佇列與轉換邏輯
Sources/App.swift       SwiftUI 介面
CLI/main.swift          命令列版
assets/makeicon.swift   App 圖示產生器
build.sh                建置腳本
```

## 授權

[MIT](LICENSE)
