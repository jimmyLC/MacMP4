# Privacy Check — MacMP4 Pro 金流

- 日期：2026-10-28
- 範圍：`codex/ecpay-pro` 新增付款 Worker／D1、原生授權與鑰匙圈；不含既有網站改版。
- 狀態：測試與正式 Worker／D1 已部署；正式收款已啟用供擁有者驗收，尚未公開發行 App。

## 1. 結論

**綠界測試環境端到端驗證通過；全面公開販售仍待正式付款驗收、備援與監控。**

待完成上線條件：2；程式層 high：目前測試範圍未發現；營運待辦：監控／備份金鑰。

## 2. 個資資料地圖

| 資料 | 收集點 | 儲存位置 | 用途／期限 | 機制 | 第三方 |
|---|---|---|---|---|---|
| 購買 Email、序號 | App → orders/activate | 鑰匙圈、D1 的 AES-GCM private_data | 已付款／撤銷保留供終身恢復；未付款 30 天 | 加密、HMAC Email 查找、排程刪除 | Cloudflare |
| 訂單恢復權杖 | App 產生 | 鑰匙圈；D1 只存 SHA256 | 關閉／重開 App 後恢復訂單 | 先寫鑰匙圈再建單；Bearer 查詢；與 checkout 權杖分離 | Cloudflare |
| 訂單、NT$90、綠界交易編號 | 建單／簽章通知 | D1 | 核對交易與撤銷 | SQL 參數化、金額固定、單次原子付款更新 | Cloudflare、綠界 |
| IP 限流桶 | Worker CF-Connecting-IP | D1 HMAC 雜湊 | 最多兩天 | 每分鐘桶，每天清理；不保存原始 IP | Cloudflare 另有基礎連線處理 |
| 卡片與 Apple Pay 資料 | 綠界託管頁 | 綠界與其處理者 | 付款 | 不進 App／本服務資料表 | 綠界 |
| 影片檔案 | 原有本機轉檔 | 使用者電腦 | 本機轉檔／裁切 | 新金流 API 不接收媒體 | 無新增第三方傳輸 |
| 正式金流／AES／查找／簽章密鑰 | 本機設定，已分環境上傳 | .dev.vars.production（600）、Worker secrets | 驗簽、加密及授權 | 不進 Resources／Git；不同用途獨立金鑰 | Cloudflare |

## 3. Findings 與上線條件

### 已完成：獨立雲端及綠界測試回呼

- 測試及正式環境各有獨立 Worker、D1 與密鑰；正式付款已開啟供擁有者驗收。
- 使用綠界測試交易實際收到 ReturnURL，原生程式驗簽並顯示 Pro；正式端拒絕無效簽章。Apple Pay 錢包及正式交易尚未實測。

### B-2：正式儲存還原與密鑰備援待完成

- 位置：`payments/migrations/0001_orders.sql`、`payments/scripts/prepare-config.mjs`、.dev.vars.production。
- 影響：遺失資料或 DATA_KEY／LOOKUP_KEY／簽章私鑰會影響恢復、解密或舊 App 相容性。
- 驗證：原生 workerd 本機 D1 SQLite 使用 online backup 匯出 SQL，再還原至隔離記憶體資料庫，已付款合成訂單 count=1；雲端 staging 與正式 D1 均已匯出並在隔離的本機 SQLite 還原；已查詢正式 D1 Time Travel bookmark，尚未執行雲端還原。
- 修法：驗證 D1 恢復到獨立雲端測試資料庫；使用者另以密碼管理器或加密異地備份保管密鑰。不能把同一磁碟的複本當異地備援。

### B-3：正式付款及 Apple Pay 完整流程待使用者驗收

- 位置：`Sources/AppearanceView.swift` 的超級感謝視窗；`payments/src/worker.mjs` checkout/notify。
- 影響：僅格式檢查無法證明商店金鑰與合約實際有效；目前沒有真的刷卡。
- 修法：stage 已使用官方測試卡；正式小額驗收由使用者本人確認付款，不由代理執行付款。

### 營運與殘餘風險

- `payments/wrangler.jsonc` 預設關閉應用追蹤日誌；HTTP 錯誤率／健康檢查通知尚待設定。供應商連線層日誌不能因 observability=false 宣稱不存在。
- `Sources/ProLicense.swift` 接受已驗簽終身收據離線使用；僅在啟動連線恢復授權時檢查撤銷。離線 App 無法即時撤銷，退款後由後台將資料設為 revoked。這項產品取捨須由開發者接受，不假稱有即時 DRM。
- 沒有裝置數限制；持有序號＋Email 即可恢復，依使用者不做登入系統的選擇。序號不透過公開 Email 搜尋提供。
- 尚未串寄信；序號由 App 顯示，購買者須保存。通知遺失時先在綠界核對／重送，不以無 SimulatePaid 欄位的 QueryTradeInfo 回覆逕發正式授權。
- 本商店僅支援台灣發行信用卡的說明已出現在 App 與 checkout；金流端限制仍由正式綠界帳號設定負責。

## 4. 已驗證的防護與證據

| 項目 | 實測證據 |
|---|---|
| CheckMacValue | 官方 SHA256 向量（含空白、單引號與 ~）通過；WebCrypto HMAC verify 時間安全比對 |
| 權限／輸出 | 錯 token 不得查單、未付款不可啟用、錯 Email＋有效序號不回授權、browser thanks 不啟用 |
| 付款一致性 | 偽造簽章、錯 MerchantID、錯金額拒絕；正式 SimulatePaid=1 拒絕；重送與亂序不重複變更 |
| 資料庫失敗 | callback 儲存不可用回 503，不回 1\|OK |
| 設定／測試隔離 | 缺金鑰拒絕服務；正式環境拒絕公開測試帳號；正式 App 拒絕 staging 簽章；鑰匙圈按 bundle/environment 隔離 |
| 原生授權 | CryptoKit 驗證 Node/WebCrypto 的 P-256 簽章；偽造／錯 Email／未來時間／staging 拒絕；鑰匙圈失敗不先建單；離線終身與撤銷測試通過 |
| 資料保存 | 未付款清理、保留已付資料測試通過；本機 D1 還原通過 |
| Web | no-store/no-referrer/noindex/CSP/frame-ancestors；來源、JSON 內容、串流 body 上限與限流測試 |
| 原生介面 | 獨立 Free 預覽已檢查購買 Email、台灣卡限制、NT$90 按鈕、恢復 Email＋序號欄位及未設定時停用狀態；截圖 outputs/MacMP4-payment-preview.png |
| 舊功能 | 完整轉檔／裁切／工具安裝／外觀回歸與 211 英文 key 通過；GUI＋CLI 建置通過 |

命令：`cd payments && npm test`（7 組）；`node payments/scripts/local-smoke.mjs`（隔離 workerd 本機流程）；`python3 Tests/regressions.py`；`./build.sh`；`wrangler deploy --dry-run`（只有打包，不部署）。

## 5. 法遵標記（不提供法律結論）

- 隱私說明實作於 `/privacy`，對齊資料表、雲端處理者及刪除排程。
- Pro 為有對價的外觀功能，頁面稱「超級感謝」；沒有表示公益捐贈或開立公益收據。
- 現有非商業授權仍適用。正式販售前，開發者應確認購買條款、退款及憑證／稅務處理，不自行虛構法定例外或退款期限。

## 6. 簽核狀態

| 項目 | 負責人 | 狀態 |
|---|---|---|
| 本機程式／回歸 | 程式 | 通過 |
| 正式金鑰輸入與 600 權限 | 使用者＋程式 | 已設定，僅檢查存在／格式，未顯示值 |
| 建立 Worker／D1、上傳密鑰、部署 | 使用者核准後程式執行 | 已完成 |
| 綠界 stage 實測 | 程式／必要時使用者處理驗證 | 已完成，實際測試回呼與原生授權通過 |
| 正式付款確認 | 使用者本人 | 尚未執行 |
| 正式異地密鑰備份、D1 還原、錯誤通知 | 開發者＋程式 | 待完成 |
| main／公開 DMG／既有網站更新 | 使用者另行核准 | 未執行 |
