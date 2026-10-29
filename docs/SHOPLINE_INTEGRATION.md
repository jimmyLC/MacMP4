# SHOPLINE Payments integration

Replaces ECPay (last ECPay version: tag `ecpay-final`; old notes in `docs/ECPAY_*.archived.md`).
Redirect mode: the Worker creates a checkout session, the browser is sent to `sessionUrl`, and a signed webhook plus a server-side query confirm payment. The app and its `/v1/*` API are unchanged.

## Flow
1. App `POST /v1/orders` → Worker stores a pending NT$90 order (amount fixed server-side, sent as 9000).
2. App opens `/checkout/<id>?token=…` → Worker calls `POST /api/v1/trade/sessions/create` once (session kept in D1) and 302s to `sessionUrl`.
3. SHOPLINE calls `POST /shopline/webhook` (`timestamp`, `sign` headers). The Worker verifies `HMAC-SHA256(timestamp.rawBody, signKey)`, rejects timestamps over 5 minutes old, and only acts on `trade.succeeded`.
4. Before marking an order paid, the Worker queries `POST /api/v1/trade/payment/get` and requires status `SUCCEEDED`, matching order id and tradeOrderId, and `paidAmount` 9000 TWD.
5. App polls `/v1/orders/<id>`; the `/thanks` page never activates a license.

## Secrets (Worker)
`SHOPLINE_MERCHANT_ID`, `SHOPLINE_API_KEY`, `SHOPLINE_SIGN_KEY` (plus the existing `DATA_KEY`, `LOOKUP_KEY`, `LICENSE_SIGNING_JWK`). Put them in `payments/.dev.vars` (staging) or `.dev.vars.production`, then `node scripts/upload-secrets.mjs staging|production`. Staging uses `api-sandbox.shoplinepayments.com`, production uses `api.shoplinepayments.com`.

## Before going live
- Webhook URL registered with SHOPLINE for sandbox and production: `<worker host>/shopline/webhook`.
- Run migration `0002_shopline.sql` on the D1 database.
- Sandbox: pay with an odd amount rule card (see skill `references/sandbox.md`), confirm the redirect, webhook and activation end to end. Because Pro is NT$90, the sandbox success rule (odd amount after dropping 00) applies to 90 → 0.9; verify with SHOPLINE what result NT$90 gives, or test with a temporary amount.
- Open items to confirm in sandbox: whether `order.shipping`, `customer.referenceCustomerId` and billing address are required for a digital product; Apple Pay availability and domain verification.
- One real small payment, then refund by hand in the SHOPLINE dashboard (no automatic refunds: digital product, no refunds).
