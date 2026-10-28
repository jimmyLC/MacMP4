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
- 🌐 **雙語介面** — 英文 / 繁體中文,跟隨系統語言(也可在 App 內手動切換)
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
3. 確認佇列與輸出位置後按「開始轉檔」(可選擇加入後立即轉換);逐檔顯示進度與速度
4. 完成後點列尾的資料夾圖示,直接在 Finder 查看結果

選項:輸出位置、是否覆蓋已存在的 MP4、失敗時自動重新編碼、GPU 硬體加速。

> 小技巧:Finder 對 `.ts` 檔右鍵 →「打開方式」→ MacMP4。

## 基本裁切（GUI 進階選項）

展開「進階選項 → 裁切開頭／結尾」，輸入要剪掉的開頭及結尾秒數，支援小數；只裁切其中一端時，另一端填 0。預設關閉，啟用後套用到本次批次佇列中的待處理影片。保留片段會重新編碼成 H.264 影片與 AAC 音訊的 MP4，優先使用硬體加速，失敗退回 CPU；即使未勾選一般的重新編碼備援，此明確裁切操作仍會重新編碼。

裁切時也接受 MP4／M4V，另存為 `<原檔名>_trimmed.mp4`，保留來源檔案；既有裁切輸出遵循覆蓋選項。無效秒數、未知片長或剪掉整部影片的設定會被拒絕。進度以保留片段長度計算。關閉裁切即可回到原本快速封裝與略過 MP4／M4V 的流程。Free 與 Pro 均可使用；CLI 行為不變。

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

[MacMP4 非商業用途授權 1.0](LICENSE)

Copyright © 2026 **JimmyLC** · [開發者網站](https://jimmy-tools.com/)

原始碼公開，可免費用於非商業用途，也可研究、修改及分享，但須保留版權聲明、開發者姓名、網站與授權條款。**禁止商業用途**，包含企業業務、專業或客戶工作、付費轉檔服務及整合至商業產品；商業用途須另行取得 JimmyLC 的書面授權。

此為附有非商業限制的原始碼公開授權，不屬於 OSI 定義的開源授權。先前已以 MIT 釋出的版本及已授出的權利不受影響；第三方工具仍適用各自授權。完整條款以英文 LICENSE 檔為準。

## 輸出保護與回歸測試

轉檔先寫入輸出資料夾旁的獨立暫存位置,通過驗證後才以原子操作替換正式 MP4。失敗或取消時保留既有檔案,同名資料夾與符號連結會被拒絕。支援有效的短於一秒影片。

macOS 安裝 Swift、Python 3、ffmpeg 與 ffprobe 後,執行 `python3 Tests/regressions.py`。測試僅使用可丟棄的合成影片,涵蓋 CLI 轉檔、GUI 佇列模型取消操作、輸出保護與大量錯誤輸出的探測流程。

## 介面與語言

左側是轉檔佇列，右側持續顯示輸出設定，底部固定開始／停止操作。加入影片後先確認清單與儲存位置，再按「開始轉檔」；可自行開啟立即轉換。進階選項預設收起，「移除已完成」會保留失敗項目供重試。右側語言選單支援跟隨系統、繁體中文與英文；部分既有工作訊息需重新開啟 App 後完整套用新語言。

macOS 26 以上的加入控制列與底部操作列使用原生 Liquid Glass，舊系統使用標準系統材質。檔案內容維持清楚易讀，並支援系統的降低透明度與減少動態效果設定。App icon 採用簡單的藍色雙向箭頭。

## DMG 下載與建置

Apple Silicon 版本請至 [GitHub Release v1](https://github.com/jimmyLC/MacMP4/releases/tag/v1) 下載，需 macOS 13 以上並另行安裝 ffmpeg/ffprobe。此版使用 ad-hoc 簽章，尚無 Developer ID 簽章與 Apple 公證。

從原始碼建置需使用包含 macOS 26 SDK 或更新 SDK 的 Xcode，執行 `./build-dmg.sh`。安裝包包含 MacMP4.app、Applications 捷徑、LICENSE 與中英安裝說明；腳本會驗證映像並產生 build/SHA256SUMS.txt。App 顯示版本以 VERSION 為準。

MacMP4 開啟時會檢查 FFmpeg 與 ffprobe。缺少工具時會顯示設定引導；已安裝 Homebrew 可直接按「安裝 FFmpeg」，查看安裝訊息，失敗時可重試。沒有 Homebrew 則提供官方安裝說明。返回 App 後自動重新檢查，不必重開。Homebrew 目前正式支援 macOS 15 以上，較舊系統需自行安裝相容工具。

Free 顯示 Free 標誌並固定使用淺色外觀。Pro 顯示 Pro 標誌，可選擇淺色、深色與跟隨系統，並記住外觀偏好。Free 保留完整轉檔功能。Pro 為 NT$90 終身買斷；開發分支已串接付款與 Email／序號啟用。開發預覽可用 `-D MACMP4_PREVIEW_PRO` 編譯，build.sh 不會啟用此旗標。

進階選項新增「強制 H.264」，預設關閉，Free／Pro 均可使用。開啟後略過直接封裝策略，輸出 H.264 影片與 AAC 音訊（來源有音訊時），支援 VideoToolbox 與 CPU 備援；此選項優先於一般的重新編碼備援設定。CLI 使用 `--force-h264`，不可與 `--no-reencode` 並用。既有 MP4／M4V 與不覆蓋檔案的略過規則維持不變。

支持入口統一使用「超級感謝」，搭配愛心內含 $ 的圖示。面板介紹 NT$90 終身買斷的 Pro 版本，並提供付款入口。

## Pro 金流串接（開發中）

`codex/ecpay-pro` 已加入綠界付款與簽章終身授權流程，後端為獨立 Worker／D1。正式收款已開啟供擁有者驗收，實際付款尚未驗證，目前維持關閉。Pro 為 NT$90 一次買斷，轉檔維持免費；本商店目前僅支援台灣發行的信用卡。詳見[串接與上線條件](docs/ECPAY_INTEGRATION.md)。

首次購買經確認後，App 會播放短暫煙火並顯示 Pro 歡迎訊息；恢復授權不會重播，開啟減少動態效果時則只顯示訊息。
