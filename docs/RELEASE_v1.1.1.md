MacMP4 v1.1.1：新增「回報問題」，轉檔失敗時可一鍵附上診斷資訊。

## 下載

- `MacMP4-v1.1.1-macos-arm64.dmg`：Apple Silicon（M 系列）Mac，macOS 13 以上。
- `SHA256SUMS.txt`：下載檔案的 SHA-256 校驗碼。

安裝方式與先前版本相同，詳見 DMG 內的 INSTALL.txt。此版仍使用本機 ad-hoc 簽章，**尚未使用 Apple Developer ID 簽署或經 Apple 公證**；macOS 可能阻擋首次開啟，確認來源為此官方 Release 後，依「系統設定 → 隱私權與安全性」的提示個別允許。

## 新功能

- **回報問題**：同一支影片失敗兩次後，列表會出現「回報問題」按鈕；選單「說明 → 回報問題…」隨時可用。會開啟回報表單，並預先帶入 App 版本、macOS 版本、ffmpeg 版本與轉檔錯誤紀錄。
- 診斷資料放在網址的 `#` 後面，瀏覽器不會把它送到伺服器；你在表單看過內容並按下送出之前，不會有任何資料離開你的 Mac。
- 送出前會移除檔名、資料夾與磁碟名稱、Email，以及影片內嵌的標題、備註等標籤。

## 延續 v1.1.0

- Pro 終身版（NT$90 一次買斷，Apple Pay／台灣信用卡）。Pro 只增加外觀選項，轉檔功能維持免費。
- H.265 輸出可在 QuickTime 播放、保留所有音軌、exFAT 磁碟可儲存、中斷後自動清除暫存資料夾、同名輸出不互相覆蓋。

## 授權

Copyright © 2026 JimmyLC · https://jimmy-tools.com/

非商業用途免費，禁止商業用途；商業用途須另行取得 JimmyLC 書面授權。完整條款見隨附 LICENSE。

## 驗證範圍

通過轉檔、授權、付款與回報功能的回歸測試，以及 arm64 GUI／CLI 建置。尚未在實體 Intel Mac、macOS 13–15 上驗證；此 DMG 不適用 Intel Mac。
