MacMP4 v1.1.2：「回報問題」改開新的回報表單。

## 下載

- `MacMP4-v1.1.2-macos-arm64.dmg`：Apple Silicon（M 系列）Mac，macOS 13 以上。
- `SHA256SUMS.txt`：下載檔案的 SHA-256 校驗碼。

安裝方式與先前版本相同，詳見 DMG 內的 INSTALL.txt。此版仍使用本機 ad-hoc 簽章，**尚未使用 Apple Developer ID 簽署或經 Apple 公證**；macOS 可能阻擋首次開啟，確認來源為此官方 Release 後，依「系統設定 → 隱私權與安全性」的提示個別允許。

## 變更

- 「回報問題」現在直接開啟新的回報表單（support.jimmy-tools.com/add）。診斷資訊仍只放在網址的 `#` 後面，在你檢視並送出之前不會離開你的 Mac；送出前會遮蔽檔名、路徑、Email 與影片內嵌標籤。
- v1.1.1 開啟的舊網址會自動轉到新表單，不需要立刻更新。

## 延續先前版本

- Pro 終身版（NT$90 一次買斷，Apple Pay／台灣信用卡）；Pro 只增加外觀選項，轉檔功能維持免費。
- H.265 輸出可在 QuickTime 播放、保留所有音軌、exFAT 磁碟可儲存、中斷後自動清除暫存資料夾、同名輸出不互相覆蓋。

## 授權

Copyright © 2026 JimmyLC · https://jimmy-tools.com/

非商業用途免費，禁止商業用途；商業用途須另行取得 JimmyLC 書面授權。完整條款見隨附 LICENSE 與 https://jimmy-tools.com/MacMP4/terms/。

## 驗證範圍

通過轉檔、授權、付款與回報功能的回歸測試，以及 arm64 GUI／CLI 建置。尚未在實體 Intel Mac、macOS 13–15 上驗證；此 DMG 不適用 Intel Mac。
