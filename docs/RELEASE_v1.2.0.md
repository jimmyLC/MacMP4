MacMP4 v1.2.0：換電腦可用序號恢復 Pro（一次一台），購買後自動寄序號信，金流改用 SHOPLINE Payments。

## 下載

- `MacMP4-v1.2.0-macos-arm64.dmg`：Apple Silicon（M 系列）Mac，macOS 13 以上。
- `SHA256SUMS.txt`：下載檔案的 SHA-256 校驗碼。

安裝方式與先前版本相同，詳見 DMG 內的 INSTALL.txt。此版仍使用本機 ad-hoc 簽章，**尚未使用 Apple Developer ID 簽署或經 Apple 公證**；macOS 可能阻擋首次開啟，確認來源為此官方 Release 後，依「系統設定 → 隱私權與安全性」的提示個別允許。

## 變更

- **購買後寄序號信**：付款完成後會寄一封含序號的信到購買 Email，語言跟隨 App 的語言（繁體中文或 English）。
- **換電腦恢復 Pro**：在新電腦的「已有序號？恢復 Pro」輸入購買 Email 與序號即可，不用再買。
- **一組序號同一時間只有一台電腦有效**：在新電腦啟用後，原本的電腦會在下次連線時變回 Free；24 小時內只能更換一次。App 只送出這台 Mac 識別碼的雜湊，無法還原成硬體資料。
- **金流改用 SHOPLINE Payments**：購買頁面改由 SHOPLINE 處理付款。付款資料不經過 MacMP4，也不會被儲存。
- 付款完成但通知延遲時，按「檢查付款」會主動向付款服務確認，不需要重新購買。

## 延續先前版本

- Pro 終身版（NT$90 一次買斷）；Pro 只增加外觀選項，轉檔功能維持免費。
- 「回報問題」開啟新的回報表單；H.265 輸出可在 QuickTime 播放、保留所有音軌、exFAT 磁碟可儲存、中斷後自動清除暫存資料夾、同名輸出不互相覆蓋。

## 授權

Copyright © 2026 JimmyLC · https://jimmy-tools.com/

非商業用途免費，禁止商業用途；商業用途須另行取得 JimmyLC 書面授權。完整條款見隨附 LICENSE 與 https://jimmy-tools.com/MacMP4/terms/。

## 驗證範圍

通過轉檔、授權、換機、付款與回報功能的回歸測試，以及 arm64 GUI／CLI 建置。信用卡付款與 Pro 啟用已用正式環境實測；Apple Pay 與序號信的實際寄達尚待驗證。尚未在實體 Intel Mac、macOS 13–15 上驗證；此 DMG 不適用 Intel Mac。
