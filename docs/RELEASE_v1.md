MacMP4 v1.0.0：原生 Mac 影片轉檔工具，優先無損封裝，支援批次處理與自動修復。

## 下載

- `MacMP4-v1.0.0-macos-arm64.dmg`：Apple Silicon（M 系列）Mac，macOS 13 以上。
- `SHA256SUMS.txt`：下載檔案的 SHA-256 校驗碼。
- 原始碼可從此 release 的 source archive 或 `v1` tag 取得。

## 安裝

1. 開啟 DMG，將 MacMP4 拖入 Applications（應用程式）。
2. 開啟時自動檢查 ffmpeg / ffprobe；已有 Homebrew 可在 App 內點選安裝並查看訊息，不必重開。未安裝 Homebrew 時提供官網入口，目前 Homebrew 正式支援 macOS 15 以上；較舊系統需自行安裝相容工具。
3. 開啟 App，加入影片、確認儲存位置，再按「開始轉檔」。

此版使用本機 ad-hoc 簽章，**尚未使用 Apple Developer ID 簽署或經 Apple 公證**。macOS 可能阻擋首次開啟；確認此官方 Release 來源後，依「系統設定 → 隱私權與安全性」的個別 App 提示處理。無須停用系統安全功能。

## 功能與修復

- TS、M2TS、MKV、MOV、FLV、AVI 等格式批次轉為 MP4。
- 優先 stream-copy 無損封裝；必要時嘗試音訊修復或影片重新編碼。
- 影片重新編碼支援 Apple VideoToolbox，並有 CPU 備援。
- 新版原生工作區、有限度的 Liquid Glass、繁體中文／英文切換，以及深色雙向箭頭 icon。
- 失敗／取消先清理自己的暫存輸出，保留既有檔案及資料夾。
- 修復 ffprobe 大量錯誤輸出可能卡住，以及有效短片被誤判失敗的問題。
- 失敗項目保留重試，完成項目可獨立清除。

重新編碼可能改變畫質，不保證每個來源都能無損處理或修復成功。

## 授權與開發者

Copyright © 2026 JimmyLC · https://jimmy-tools.com/

**原始碼公開，非商業用途免費；禁止商用。** 完整條款見隨附 LICENSE。這是非商業的 source-available 授權，不屬於 OSI 定義的開源授權。先前 MIT 版本及已授出的權利不受影響；第三方工具保留各自授權。

## 驗證範圍

已通過 arm64 GUI/CLI 建置、回歸與語系測試、正常 remux／CPU 重新編碼合成影片測試、DMG 映像驗證、掛載內容檢查與 ad-hoc 簽章驗證。實際檢查了繁中／英文切換、匯入、短片轉換、失敗顯示與清除完成項目。

尚未在實體 Intel Mac、macOS 13–15、外接 exFAT/FAT32 輸出磁碟上驗證。此 DMG 不適用 Intel Mac；自行建置需包含 macOS 26 SDK 的 Xcode。
