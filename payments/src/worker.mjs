import {serialEmail} from './mail.mjs';
import {base64url, randomToken, sha256, keyedHash, verifyWebhookSignature, seal, unseal, signLicense, normalizeEmail} from './crypto.mjs';
const PRODUCT = 'macmp4-pro-lifetime';
const HEADERS = {'Cache-Control':'no-store', 'Referrer-Policy':'no-referrer', 'X-Content-Type-Options':'nosniff',
  'X-Frame-Options':'DENY', 'X-Robots-Tag':'noindex, nofollow', 'Permissions-Policy':'camera=(), microphone=(), geolocation=()'};
class HttpError extends Error { constructor(status, code) { super(code); this.status=status; } }
const fail = (status, code) => { throw new HttpError(status, code); };
function json(data, status=200) { return new Response(JSON.stringify(data), {status, headers:{...HEADERS,'Content-Type':'application/json'}}); }
function text(body, status=200) { return new Response(body, {status, headers:{...HEADERS,'Content-Type':'text/plain'}}); }
function origin(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.port || url.username || url.password || url.search || url.hash || url.pathname !== '/' || url.hostname.endsWith('.invalid')) fail(503,'not_configured');
  return url.origin;
}
export function configuration(env) {
  if (!['staging','production'].includes(env.PAYMENT_ENV)) fail(503,'not_configured');
  if (!/^[A-Za-z0-9_-]{4,64}$/.test(env.SHOPLINE_MERCHANT_ID ?? '') || !/^\S{8,200}$/.test(env.SHOPLINE_API_KEY ?? '') || !/^\S{8,200}$/.test(env.SHOPLINE_SIGN_KEY ?? '')) fail(503,'not_configured');
  for (const key of ['DATA_KEY','LOOKUP_KEY']) if (!/^[A-Za-z0-9_-]{43}$/.test(env[key] ?? '')) fail(503,'not_configured');
  if (env.DATA_KEY === env.LOOKUP_KEY) fail(503,'not_configured');
  const signing = JSON.parse(env.LICENSE_SIGNING_JWK ?? '{}');
  if (signing.kty !== 'EC' || signing.crv !== 'P-256' || !signing.d || !signing.x || !signing.y) fail(503,'not_configured');
  return {base:origin(env.PUBLIC_BASE_URL), callback:origin(env.CALLBACK_BASE_URL),
    api:env.PAYMENT_ENV === 'production' ? 'https://api.shoplinepayments.com' : 'https://api-sandbox.shoplinepayments.com'};
}
async function bodyText(request) {
  const reader = request.body?.getReader();
  if (!reader) fail(400,'invalid_body');
  const chunks=[]; let length=0;
  while (true) { const {done,value}=await reader.read(); if(done) break; length+=value.byteLength;
    if(length>16384) { await reader.cancel(); fail(413,'body_too_large'); } chunks.push(value); }
  const all = new Uint8Array(length); let offset=0;
  for(const chunk of chunks) { all.set(chunk,offset); offset+=chunk.byteLength; }
  try { return new TextDecoder('utf-8',{fatal:true}).decode(all); } catch { fail(400,'invalid_body'); }
}
async function body(request, type) {
  if (!(request.headers.get('Content-Type') ?? '').toLowerCase().startsWith(type)) fail(415,'content_type');
  const value = await bodyText(request);
  if(type==='application/json') { try { const parsed=JSON.parse(value); if(!parsed || typeof parsed!=='object' || Array.isArray(parsed)) fail(400,'invalid_json'); return parsed; } catch { fail(400,'invalid_json'); } }
  const params=new URLSearchParams(value), result={};
  for (const [key,val] of params) { if(Object.hasOwn(result,key)) fail(400,'duplicate_parameter'); result[key]=val; }
  return result;
}
function rejectBrowserMutation(request, base) {
  const supplied=request.headers.get('Origin');
  if(supplied && supplied!==base) fail(403,'origin');
  if(request.headers.get('Sec-Fetch-Site')==='cross-site') fail(403,'origin');
}
async function rateLimit(request, env, action, maximum) {
  // Cloudflare 直連 Worker 使用可信 CF-Connecting-IP；測試無此 header 時共用單一桶。
  const now=Math.floor(Date.now()/1000), bucket=Math.floor(now/60);
  const digest=await keyedHash(env.LOOKUP_KEY,`rate:${request.headers.get('CF-Connecting-IP') ?? 'local'}:${action}:${bucket}`);
  const row=await env.DB.prepare('INSERT INTO rate_limits(key,count,expires_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1 RETURNING count')
    .bind(digest,now+120).first();
  if(row.count>maximum) fail(429,'rate_limited');
}
const tokenValid = value => typeof value==='string' && /^[A-Za-z0-9_-]{43}$/.test(value);
const serialCanonical = value => typeof value==='string' ? value.replace(/[\s-]/g,'').toUpperCase() : '';
async function checkoutKey(env, row) { return keyedHash(env.LOOKUP_KEY,`checkout:${row.id}:${row.access_hash}`); }
async function orderView(env,row,cfg) {
  const checkoutToken=await checkoutKey(env,row);
  return {orderId:row.id, amount:row.amount, currency:'TWD', environment:row.environment,
    checkoutURL:`${cfg.base}/checkout/${row.id}?token=${checkoutToken}`};
}
async function createOrder(request,env,cfg) {
  rejectBrowserMutation(request,cfg.base); await rateLimit(request,env,'create',10);
  if(env.CHECKOUT_ENABLED!=='true') fail(503,'checkout_unavailable');
  const data=await body(request,'application/json');
  const email=normalizeEmail(data.email);
  if(!email || !tokenValid(data.accessToken)) fail(400,'invalid_order');
  if(!['ApplePay','Credit'].includes(data.method) || (data.method==='ApplePay' && env.APPLE_PAY_ENABLED!=='true')) fail(400,'payment_unavailable');
  const accessHash=await sha256(data.accessToken), emailHash=await keyedHash(env.LOOKUP_KEY,`email:${email}`);
  let row=await env.DB.prepare('SELECT * FROM orders WHERE access_hash=? AND environment=?').bind(accessHash,env.PAYMENT_ENV).first();
  if(row) {
    if(row.email_hash!==emailHash || row.method!==data.method) fail(409,'order_conflict');
    return json(await orderView(env,row,cfg));
  }
  const id='M'+[...crypto.getRandomValues(new Uint8Array(10))].map(n=>n.toString(16).padStart(2,'0')).join('').slice(0,19).toUpperCase();
  const rawSerial=[...crypto.getRandomValues(new Uint8Array(20))].map(n=>n.toString(16).padStart(2,'0')).join('').toUpperCase();
  const serial='MP4-'+rawSerial.match(/.{8}/g).join('-');
  const serialHash=await sha256(serialCanonical(serial));
  const privateData=await seal({email,serial},env.DATA_KEY);
  const checkoutHash=await sha256(await checkoutKey(env,{id,access_hash:accessHash}));
  await env.DB.prepare('INSERT OR IGNORE INTO orders(id,environment,product,amount,method,email_hash,serial_hash,private_data,access_hash,checkout_hash,created_at,language) VALUES(?,?,?,90,?,?,?,?,?,?,?,?)')
    .bind(id,env.PAYMENT_ENV,PRODUCT,data.method,emailHash,serialHash,privateData,accessHash,checkoutHash,Math.floor(Date.now()/1000),data.language==='en'?'en':'zh-Hant').run();
  row=await env.DB.prepare('SELECT * FROM orders WHERE access_hash=? AND environment=?').bind(accessHash,env.PAYMENT_ENV).first();
  if(!row || row.email_hash!==emailHash || row.method!==data.method) fail(409,'order_conflict');
  return json(await orderView(env,row,cfg),201);
}
function bearer(request) { const value=(request.headers.get('Authorization') ?? '').replace(/^Bearer /,''); if(!tokenValid(value)) fail(401,'unauthorized'); return value; }
async function paidResult(row,env) {
  if(row.status==='revoked') fail(409,'license_revoked');
  if(row.status!=='paid') return {status:'pending'};
  const data=await unseal(row.private_data,env.DATA_KEY);
  return {status:'paid', email:data.email, serial:data.serial, licenseToken:await signLicense(row,data.email,env.LICENSE_SIGNING_JWK)};
}
const deviceValid = value => typeof value==='string' && /^[A-Za-z0-9_-]{22,64}$/.test(value);
const changes = result => result?.meta?.changes ?? result?.changes ?? 0;
const DEVICE_CHANGE_SECONDS = 24*3600;
/** 一組序號同時只有一台有效裝置。takeover 為使用者明確按下「在這台啟用」；啟動時的背景檢查不會搶走。 */
async function bindDevice(env,row,deviceId,takeover) {
  const hash=await sha256(deviceId), now=Math.floor(Date.now()/1000);
  if(row.active_device_hash===hash) return;
  if(!row.active_device_hash) {
    const bound=await env.DB.prepare('UPDATE orders SET active_device_hash=? WHERE id=? AND active_device_hash IS NULL').bind(hash,row.id).run();
    if(changes(bound)===1) return;
    row=await env.DB.prepare('SELECT * FROM orders WHERE id=?').bind(row.id).first();
    if(row.active_device_hash===hash) return;
  }
  if(!takeover) fail(409,'device_replaced');
  const moved=await env.DB.prepare('UPDATE orders SET active_device_hash=?,device_changed_at=? WHERE id=? AND active_device_hash IS NOT NULL AND active_device_hash!=? AND (device_changed_at IS NULL OR device_changed_at<=?)')
    .bind(hash,now,row.id,hash,now-DEVICE_CHANGE_SECONDS).run();
  if(changes(moved)!==1) fail(429,'device_change_limited');
}
/** 寄序號信。失敗不影響授權；email_sent_at 未設定時，排程會重試。 */
export async function sendSerialMail(env,row) {
  if(!env.EMAIL || row.status!=='paid' || row.email_sent_at) return false;
  try {
    const {email,serial}=await unseal(row.private_data,env.DATA_KEY);
    await env.EMAIL.send({to:email,from:{email:env.MAIL_FROM ?? 'contact@jimmy-tools.com',name:'MacMP4'},replyTo:env.MAIL_FROM ?? 'contact@jimmy-tools.com',...serialEmail(serial,email,row.language)});
    await env.DB.prepare('UPDATE orders SET email_sent_at=? WHERE id=? AND email_sent_at IS NULL').bind(Math.floor(Date.now()/1000),row.id).run();
    return true;
  } catch { return false; }
}
async function firstDevice(request,env,row) {
  const result=await paidResult(row,env);
  const device=request.headers.get('X-Device-Id');
  if(result.status==='paid' && deviceValid(device) && !row.active_device_hash) await bindDevice(env,row,device,false);
  return result;
}
async function orderStatus(request,env,id) {
  await rateLimit(request,env,'status',90);
  const hash=await sha256(bearer(request));
  const row=await env.DB.prepare('SELECT * FROM orders WHERE id=? AND access_hash=? AND environment=?').bind(id,hash,env.PAYMENT_ENV).first();
  if(!row) fail(404,'order_not_found');
  if(row.status==='pending' && row.session_id) {
    try { await reconcile(env,configuration(env),row); } catch {} // 備援失敗不影響查詢，下次再試。
    const fresh=await env.DB.prepare('SELECT * FROM orders WHERE id=? AND environment=?').bind(row.id,env.PAYMENT_ENV).first();
    if(fresh) return json(await firstDevice(request,env,fresh));
  }
  return json(await firstDevice(request,env,row));
}
function html(content, action="'none'") {
  return new Response(`<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta name="robots" content="noindex,nofollow"><title>MacMP4 超級感謝</title><style>body{font:17px system-ui;max-width:32rem;margin:12vh auto;padding:24px;color:#1d2433;background:#f4f6f9}button{padding:14px 24px;background:#0061cc;color:white;border:0;border-radius:12px;font:inherit}a{color:#0061cc}</style><main>${content}</main></html>`,
    {headers:{...HEADERS,'Content-Type':'text/html; charset=utf-8','Content-Security-Policy':`default-src 'none'; style-src 'unsafe-inline'; form-action ${action}; frame-ancestors 'none'; base-uri 'none'`}});
}
const METHODS = {ApplePay:'ApplePay', Credit:'CreditCard'};
const AMOUNT_MINOR = 9000; // NT$90 × 100
const requestId = () => [...crypto.getRandomValues(new Uint8Array(16))].map(n=>n.toString(16).padStart(2,'0')).join('');
async function shoplineCall(env,cfg,path,payload,idempotentKey) {
  const headers={'Content-Type':'application/json', merchantId:env.SHOPLINE_MERCHANT_ID, apiKey:env.SHOPLINE_API_KEY, requestId:requestId()};
  if(idempotentKey) headers.idempotentKey=idempotentKey;
  const response=await fetch(cfg.api+path,{method:'POST',headers,body:JSON.stringify(payload),signal:AbortSignal.timeout(15000)});
  const data=await response.json().catch(()=>null);
  if(!response.ok || !data) fail(502,'provider_error');
  return data;
}
async function createSession(request,env,cfg,row) {
  // 規格核對：2026-10-29 https://docs.shoplinepayments.com/api/trade/session/；固定伺服器端價格，拒絕前端指定金額。
  const {email}=await unseal(row.private_data,env.DATA_KEY);
  const person={firstName:'Customer',lastName:'MacMP4',email};
  const address={countryCode:'TW',street:'N/A'};
  const data=await shoplineCall(env,cfg,'/api/v1/trade/sessions/create',{
    referenceId:row.id, language:row.language==='en'?'en':'zh-TW', amount:{value:AMOUNT_MINOR,currency:'TWD'}, expireTime:60,
    returnUrl:`${cfg.base}/thanks`, mode:'regular', allowPaymentMethodList:[METHODS[row.method]],
    // 2026-10-29 實測正式 API：數位商品仍要求 order.shipping 與 billing.address，填佔位值即可。
    order:{products:[{id:PRODUCT,name:'MacMP4 Pro Lifetime',quantity:1,amount:{value:AMOUNT_MINOR,currency:'TWD'}}],
      shipping:{shippingMethod:'digital',carrier:'digital',personalInfo:person,address}},
    customer:{referenceCustomerId:row.id,personalInfo:person}, billing:{personalInfo:person,address},
    client:{ip:request.headers.get('CF-Connecting-IP') ?? '127.0.0.1'}
  },row.id);
  let target;
  try { target=new URL(data.sessionUrl); } catch { fail(502,'provider_error'); }
  if(target.protocol!=='https:' || !target.hostname.endsWith('.shoplinepayments.com') || data.referenceId!==row.id || !data.sessionId) fail(502,'provider_error');
  await env.DB.prepare("UPDATE orders SET session_id=?,session_url=? WHERE id=? AND environment=? AND status='pending'")
    .bind(data.sessionId,target.href,row.id,env.PAYMENT_ENV).run();
  return target.href;
}
async function checkout(request,env,cfg,id,token) {
  if(!tokenValid(token)) fail(404,'not_found');
  const row=await env.DB.prepare('SELECT * FROM orders WHERE id=? AND checkout_hash=? AND environment=?').bind(id,await sha256(token),env.PAYMENT_ENV).first();
  if(!row) fail(404,'not_found');
  if(row.status!=='pending') return html('<h1>返回 MacMP4</h1><p>請在 App 中檢查此筆訂單狀態。</p>');
  if(env.CHECKOUT_ENABLED!=='true') fail(503,'checkout_unavailable');
  if(Date.now()/1000-row.created_at>3600) fail(410,'checkout_expired');
  const target=row.session_url ?? await createSession(request,env,cfg,row);
  return new Response(null,{status:302,headers:{...HEADERS,Location:target}});
}
// 實測正式 API（2026-10-29）：Session 付款的 referenceOrderId 是 SHOPLINE 自己的 RL… 編號；
// 我們的訂單編號在 order.customer.referenceCustomerId，且 sessionId 會對應。金額在 payment.paidAmount。
function orderCandidates(data) {
  return [data?.order?.customer?.referenceCustomerId, data?.referenceOrderId, data?.order?.referenceOrderId]
    .filter(value=>typeof value==='string' && /^[A-Z0-9]{20}$/.test(value));
}
// 不單信通知內容：向 SHOPLINE 查詢該筆付款，確認屬於這張訂單、狀態成功、金額 NT$90，才入帳。
async function settle(env,cfg,row,tradeOrderId) {
  if(row.status!=='pending') return;
  if(!/^[A-Za-z0-9_-]{1,64}$/.test(tradeOrderId ?? '')) return;
  const trade=await shoplineCall(env,cfg,'/api/v1/trade/payment/get',{tradeOrderId});
  const paid=trade.payment?.paidAmount ?? trade.paidAmount ?? {};
  const mine=(row.session_id && trade.sessionId===row.session_id) || trade.order?.customer?.referenceCustomerId===row.id;
  if(trade.status!=='SUCCEEDED' || !mine || (trade.tradeOrderId && trade.tradeOrderId!==tradeOrderId)
    || paid.value!==AMOUNT_MINOR || paid.currency!=='TWD') return;
  await env.DB.prepare("UPDATE orders SET status='paid',paid_at=?,provider_trade_no=? WHERE id=? AND environment=? AND status='pending'")
    .bind(Math.floor(Date.now()/1000),tradeOrderId,row.id,env.PAYMENT_ENV).run()
    .then(async result=>{ if(changes(result)===1) await sendSerialMail(env,await env.DB.prepare('SELECT * FROM orders WHERE id=?').bind(row.id).first()); });
}
// Webhook 沒到時的備援：App 查詢待付款訂單時，主動向 SHOPLINE 查 session。
async function reconcile(env,cfg,row) {
  if(row.status!=='pending' || !row.session_id) return;
  const session=await shoplineCall(env,cfg,'/api/v1/trade/sessions/query',{sessionId:row.session_id});
  if(session.status!=='SUCCEEDED') return;
  const success=(session.paymentDetails ?? []).find(item=>item.paymentStatus==='SUCCEEDED' || item.status==='SUCCEEDED');
  if(success) await settle(env,cfg,row,success.tradeOrderId);
}
async function webhook(request,env,cfg) {
  // 通知規格：2026-10-29 shopline-payments-skill references/webhook.md。必須用原始 body 驗簽。
  const timestamp=request.headers.get('timestamp') ?? '', sign=request.headers.get('sign');
  const raw=await bodyText(request);
  if(!/^\d{13}$/.test(timestamp) || Math.abs(Date.now()-Number(timestamp))>5*60*1000) fail(401,'timestamp');
  if(!await verifyWebhookSignature(timestamp,raw,sign,env.SHOPLINE_SIGN_KEY)) fail(401,'signature');
  let event; try { event=JSON.parse(raw); } catch { fail(400,'invalid_json'); }
  if(event?.type!=='trade.succeeded') return text('OK'); // 其他事件只確認收到，不改變授權狀態。
  const data=event.data ?? {};
  let row=null;
  for(const id of orderCandidates(data)) { row=await env.DB.prepare('SELECT * FROM orders WHERE id=? AND environment=?').bind(id,env.PAYMENT_ENV).first(); if(row) break; }
  const sessionId=data.sessionId ?? data.order?.sessionId;
  if(!row && typeof sessionId==='string') row=await env.DB.prepare('SELECT * FROM orders WHERE session_id=? AND environment=?').bind(sessionId,env.PAYMENT_ENV).first();
  if(!row || row.status!=='pending') return text('OK'); // 找不到、已付款（重送）或已撤銷：只確認收到。
  await settle(env,cfg,row,data.tradeOrderId);
  return text('OK');
}
async function activate(request,env,cfg) {
  rejectBrowserMutation(request,cfg.base); await rateLimit(request,env,'activate',10);
  const data=await body(request,'application/json'), email=normalizeEmail(data.email), serial=serialCanonical(data.serial);
  if(!email || !/^MP4[A-F0-9]{40}$/.test(serial)) fail(403,'invalid_license');
  const row=await env.DB.prepare('SELECT * FROM orders WHERE email_hash=? AND serial_hash=? AND environment=?')
    .bind(await keyedHash(env.LOOKUP_KEY,`email:${email}`),await sha256(serial),env.PAYMENT_ENV).first();
  if(!row || row.status==='pending') fail(403,'invalid_license');
  const result=await paidResult(row,env); // 已撤銷會在此回 409。
  if(deviceValid(data.deviceId)) await bindDevice(env,row,data.deviceId,data.takeover===true || data.takeover==='true');
  else if(env.REQUIRE_DEVICE==='true') fail(426,'update_required'); // 舊版 App（無裝置識別）過渡期可通過，之後以 REQUIRE_DEVICE 關閉。
  return json(result);
}
export async function handle(request,env) {
  const url=new URL(request.url),path=url.pathname;
  if(path==='/health') return json({service:'macmp4-payments',environment:env.PAYMENT_ENV,checkoutEnabled:env.CHECKOUT_ENABLED==='true'});
  const cfg=configuration(env);
  if(path==='/v1/config' && request.method==='GET') return json({environment:env.PAYMENT_ENV,amount:90,currency:'TWD',
    checkoutEnabled:env.CHECKOUT_ENABLED==='true',methods:env.APPLE_PAY_ENABLED==='true'?['ApplePay','Credit']:['Credit']});
  if(path==='/v1/orders' && request.method==='POST') return createOrder(request,env,cfg);
  const status=path.match(/^\/v1\/orders\/([A-Z0-9]{20})$/);
  if(status && request.method==='GET') return orderStatus(request,env,status[1]);
  if(path==='/v1/licenses/activate' && request.method==='POST') return activate(request,env,cfg);
  if(path==='/shopline/webhook' && request.method==='POST') return webhook(request,env,cfg);
  const page=path.match(/^\/checkout\/([A-Z0-9]{20})$/);
  if(page && request.method==='GET') return checkout(request,env,cfg,page[1],url.searchParams.get('token'));
  if(path==='/thanks' && request.method==='GET') return html('<h1>請回到 MacMP4</h1><p>App 會向伺服器確認付款結果，再自動啟用 Pro。這個頁面不會直接啟用授權。</p><p>尚未啟用時，請在 App 按「檢查付款」。</p>');
  if(path==='/privacy' && request.method==='GET') return html('<h1>MacMP4 Pro 隱私說明</h1><p>開發者：JimmyLC。購買時提供的 Email 與序號會加密保存於 Cloudflare D1，僅用於授權、重裝啟用與客服；購買完成時會寄一封含序號的信到你的 Email。付款資料由 SHOPLINE Payments 處理，MacMP4 不儲存卡號。影片保留於你的電腦，不會上傳。為了「一組序號同時只能在一台電腦使用」，App 會送出這台 Mac 的識別碼雜湊（無法還原成硬體資料），僅用於判斷目前使用中的電腦。</p><p>已付款與撤銷訂單保留，以支援終身授權及交易核對；未付款訂單於 30 天後刪除。流量限制用的 IP 雜湊桶最多保留 2 天。Cloudflare 與 SHOPLINE Payments 另依其政策處理連線資料。</p><p>請妥善保存 Email 與序號，任何持有兩者的人皆可恢復授權。本系統不提供公開 Email 查序號。</p><p>存取、更正、刪除資料或退款需求：<a href="mailto:acsd6850@hotmail.com">acsd6850@hotmail.com</a>。刪除授權資料將失去線上恢復能力。</p>');
  fail(404,'not_found');
}
export default {
  async fetch(request,env) {
    try { return await handle(request,env); }
    catch(error) { return json({error:error instanceof HttpError?error.message:'service_unavailable'},error instanceof HttpError?error.status:503); }
  },
  async scheduled(_event,env) {
    const now=Math.floor(Date.now()/1000);
    await env.DB.batch([
      env.DB.prepare('DELETE FROM rate_limits WHERE expires_at < ?').bind(now),
      env.DB.prepare("DELETE FROM orders WHERE status='pending' AND created_at < ?").bind(now-30*86400)
    ]);
    // 補寄尚未寄出的序號信（寄信服務暫時失敗時）。
    const unsent=await env.DB.prepare("SELECT * FROM orders WHERE status='paid' AND email_sent_at IS NULL AND paid_at > ? LIMIT 20").bind(now-7*86400).all?.();
    for(const row of unsent?.results ?? []) await sendSerialMail(env,row);
  }
};
