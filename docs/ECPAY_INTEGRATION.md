# MacMP4 Pro — 綠界金流串接

2026-10-28；功能分支 `codex/ecpay-pro`。既有網站、main 與 GitHub Release 尚未更新。

## 使用流程

1. App「超級感謝」填購買 Email，選 Apple Pay（優先）或信用卡。
2. App 先把訂單恢復權杖寫入 macOS 鑰匙圈，再向獨立付款 API 建立 NT$90 訂單；網路逾時重試使用相同權杖，避免重複建單。
3. Safari 開啟 Apple Pay；信用卡使用系統外部瀏覽器。付款表單由伺服器簽章，前端不持有綠界 HashKey／HashIV。
4. 綠界的 Server-to-Server ReturnURL 才能確認付款。核對全部 CheckMacValue 欄位、MerchantID、訂單、NT$90、RtnCode=1；正式環境拒絕 SimulatePaid=1。
5. 原子更新 pending → paid，同一訂單只啟用一次，重送或失敗的晚到通知不會撤回已付款狀態。資料庫失敗回 503，讓綠界重試；驗簽失敗不回成功確認。
6. App 每 10 秒查詢自己的訂單狀態（不是每 10 秒呼叫綠界），付款後驗證 P-256 簽章收據才顯示 Pro。關閉視窗、重開 App 仍可確認未完成訂單。
7. Email＋高熵序號可恢復 Pro，沒有帳號登入。序號顯示於 App，可選取複製；不做公開 Email 查序號，也未串接寄信服務。
8. 付款失敗或連結過期可「重新建立訂單」；先查原訂單，並保留前幾筆恢復權杖，處理延遲付款通知。

本商店僅支援台灣發行的信用卡，暫不支援海外發行信用卡。限制文案放在 App 購買視窗與付款頁按鈕附近；由綠界依正式商店設定執行卡片限制。

Pro 是 NT$90 終身買斷，只增加 Pro 標誌、淺色／深色／跟隨系統。轉檔與裁切維持 Free。既有非商業用途授權並未因付款而自動授予商業使用權。

## 架構與資料

- `payments/`：獨立 Cloudflare Worker＋D1，沒有靜態 assets 路由，也不修改 `jimmy-tools-site`。
- 預定測試主機：`https://macmp4-payments-staging.acsd68500.workers.dev`
- 預定正式主機：`https://macmp4-payments.acsd68500.workers.dev`
- 金流回呼直接進 Worker 原生 origin，不經既有網站的 CDN／靜態資源快取。須實測綠界可送達，必要時改用可公開接收的獨立 origin；不可用快取頁面或驗證碼挑戰包住 ReturnURL。
- 價格／產品固定於伺服器，無裝置數限制（使用者未指定）；持有 Email＋序號者可恢復。
- Email 與序號使用獨立 AES-GCM DATA_KEY 加密；Email 查找為 LOOKUP_KEY 的 HMAC，序號為高熵隨機值的 SHA256。權杖僅保存 SHA256。綠界交易編號與本地訂單關聯保存。
- 公開簽章金鑰固定於 `Resources/ProConfiguration.json`，私鑰僅在 Worker secrets。正式 App 拒絕 staging 收據；未配置時付款按鈕保持停用。
- 簽章收據是終身且可離線驗證。App 啟動連線成功時檢查撤銷；離線無法立即撤銷。不得承諾可強制遠端停用離線 App。
- 鑰匙圈保存 Email、序號、收據及未完成訂單權杖；API 不允許重新導向，避免重送授權資料到其他主機。
- 所有 API／付款頁 no-store、no-referrer、noindex；沒有公開查詢 Email 或管理員 API。雲端服務本身可能有連線層日誌，詳見供應商政策。
- 未付款訂單 30 天後刪除；限流桶兩天內清除；已付款與撤銷資料為終身恢復保留。每天排程清理，測試有實際刪除驗證。

## 端點

| 端點 | 權限／用途 |
|---|---|
| `GET /health`、`GET /v1/config` | 公開，無機密 |
| `POST /v1/orders` | Email＋客戶端高熵權杖，限流、來源及 JSON 檢查 |
| `GET /checkout/:id?token=…` | 僅含付款表單的獨立 checkout 權杖；不能讀取序號 |
| `GET /v1/orders/:id` | Bearer 訂單恢復權杖；付款後回傳簽章收據 |
| `POST /ecpay/notify` | 綠界全部參數的 SHA256 CheckMacValue，精確回應 `1|OK` |
| `POST /v1/licenses/activate` | Email＋序號，限流，僅已付且未撤銷可啟用 |
| `GET /thanks` | 只提示返回 App，不信任前景付款狀態 |
| `GET /privacy` | 資料處理與聯絡說明 |

## 本機設定

依官方技能 `https://github.com/ECPay/ECPay-API-Skill` V3.4 實作；skill 不隨本專案重新散布。

`payments/.dev.vars.production` 是 600 權限、Git 排除的正式金鑰檔。不要把內容貼到對話、終端輸出或 CI 日誌。`payments/.dev.vars` 使用官方公開測試帳號與獨立隨機資料／簽章金鑰。

```bash
cd payments
npm ci --ignore-scripts
node scripts/prepare-config.mjs staging https://macmp4-payments-staging.acsd68500.workers.dev
node scripts/prepare-config.mjs production https://macmp4-payments.acsd68500.workers.dev
npm test
```

prepare-config 保留已存在的私鑰，不自動輪替，收款保持關閉；公開設定另寫入 `ProConfiguration.<env>.public.json`。備份 DATA_KEY、LOOKUP_KEY、LICENSE_SIGNING_JWK 與 D1；失去它們可能失去查找、解密或舊 App 的驗證相容性。

## 核准後的部署順序

1. 建立完全分開的 staging／production D1，記錄真實 database_id，套用 migrations。
2. 分環境上傳 secrets：`node scripts/upload-secrets.mjs staging` 或 `production`。只用 stdin 傳送，腳本不印值。
3. 部署 staging，開啟測試環境建單，實際在綠界測試頁驗證 ReturnURL、重送及 App 自動啟用。此步驟不能用本機模擬取代。
4. production 初次部署保持 CHECKOUT_ENABLED=false；確認正式秘密、直接回呼主機、D1 備份／還原、監控與隱私資訊。
5. 將正式公開金鑰／API 主機設定進 App，再開正式收款。正式交易需由使用者親自確認付款，不能由代理刷卡。
6. 更新 App 發行版、DMG、網站下載頁是另一個上線步驟；尚未執行。先前 v1 不包含此金流。

退款由綠界後台操作；退費確認後以受控 D1 管理途徑把對應 `orders.status` 設為 `revoked`。不提供公開退款或管理 API。主動 QueryTradeInfo 尚未自動化：官方建議付款後 10 分鐘起查詢，且該回覆未列出 SimulatePaid；不以缺少模擬辨識資訊的查詢結果直接發放正式授權。若通知遺失，先在綠界後台核對並重送通知。

## 官方規格（2026-10-28 已讀取）

- 建單： https://developers.ecpay.com.tw/2862.md
- Apple Pay： https://developers.ecpay.com.tw/7328.md
- 通知／模擬付款： https://developers.ecpay.com.tw/2878.md
- SHA256 CheckMacValue： https://developers.ecpay.com.tw/2902.md
- 介接注意事項（origin、80/443、密鑰、WAF、限速）： https://developers.ecpay.com.tw/2858.md
- 正式金鑰位置： https://developers.ecpay.com.tw/2856.md
- 查詢訂單限制： https://developers.ecpay.com.tw/2890.md

官方 Apple Pay 頁同時保留 Safari 限制說明，並公告第三方瀏覽器 QR Code（iOS 18+）流程；本 App 優先開 Safari，信用卡保留一般瀏覽器選項。
