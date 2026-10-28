import {base64url, randomToken, sha256, keyedHash, checkMacValue, verifyMac, seal, unseal, signLicense, normalizeEmail} from './crypto.mjs';
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
  if (!/^\d{5,10}$/.test(env.ECPAY_MERCHANT_ID ?? '') || ![16,32].includes(env.ECPAY_HASH_KEY?.length) || env.ECPAY_HASH_IV?.length !== 16) fail(503,'not_configured');
  for (const key of ['DATA_KEY','LOOKUP_KEY']) if (!/^[A-Za-z0-9_-]{43}$/.test(env[key] ?? '')) fail(503,'not_configured');
  if (env.DATA_KEY === env.LOOKUP_KEY) fail(503,'not_configured');
  const signing = JSON.parse(env.LICENSE_SIGNING_JWK ?? '{}');
  if (signing.kty !== 'EC' || signing.crv !== 'P-256' || !signing.d || !signing.x || !signing.y) fail(503,'not_configured');
  if (env.PAYMENT_ENV === 'production' && (env.ECPAY_MERCHANT_ID === '3002607' || env.ECPAY_HASH_KEY === 'pwFHCqoQZGmho4w6')) fail(503,'test_credentials_in_production');
  if (env.PAYMENT_ENV === 'staging' && env.ECPAY_MERCHANT_ID !== '3002607') fail(503,'production_credentials_in_staging');
  return {base:origin(env.PUBLIC_BASE_URL), callback:origin(env.CALLBACK_BASE_URL),
    action:env.PAYMENT_ENV === 'production' ? 'https://payment.ecpay.com.tw/Cashier/AioCheckOut/V5' : 'https://payment-stage.ecpay.com.tw/Cashier/AioCheckOut/V5'};
}
async function body(request, type) {
  if (!(request.headers.get('Content-Type') ?? '').toLowerCase().startsWith(type)) fail(415,'content_type');
  const reader = request.body?.getReader();
  if (!reader) fail(400,'invalid_body');
  const chunks=[]; let length=0;
  while (true) { const {done,value}=await reader.read(); if(done) break; length+=value.byteLength;
    if(length>16384) { await reader.cancel(); fail(413,'body_too_large'); } chunks.push(value); }
  const all = new Uint8Array(length); let offset=0;
  for(const chunk of chunks) { all.set(chunk,offset); offset+=chunk.byteLength; }
  const value = new TextDecoder('utf-8',{fatal:true}).decode(all);
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
  await env.DB.prepare('INSERT OR IGNORE INTO orders(id,environment,product,amount,method,email_hash,serial_hash,private_data,access_hash,checkout_hash,created_at) VALUES(?,?,?,90,?,?,?,?,?,?,?)')
    .bind(id,env.PAYMENT_ENV,PRODUCT,data.method,emailHash,serialHash,privateData,accessHash,checkoutHash,Math.floor(Date.now()/1000)).run();
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
async function orderStatus(request,env,id) {
  await rateLimit(request,env,'status',90);
  const hash=await sha256(bearer(request));
  const row=await env.DB.prepare('SELECT * FROM orders WHERE id=? AND access_hash=? AND environment=?').bind(id,hash,env.PAYMENT_ENV).first();
  if(!row) fail(404,'order_not_found');
  return json(await paidResult(row,env));
}
export function taiwanDate(timestamp) { return new Date(timestamp+8*3600000).toISOString().slice(0,19).replaceAll('-','/').replace('T',' '); }
function escapeHTML(value) { return String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
function html(content, action="'none'") {
  return new Response(`<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta name="robots" content="noindex,nofollow"><title>MacMP4 超級感謝</title><style>body{font:17px system-ui;max-width:32rem;margin:12vh auto;padding:24px;color:#1d2433;background:#f4f6f9}button{padding:14px 24px;background:#0061cc;color:white;border:0;border-radius:12px;font:inherit}a{color:#0061cc}</style><main>${content}</main></html>`,
    {headers:{...HEADERS,'Content-Type':'text/html; charset=utf-8','Content-Security-Policy':`default-src 'none'; style-src 'unsafe-inline'; form-action ${action}; frame-ancestors 'none'; base-uri 'none'`}});
}
async function checkout(env,cfg,id,token) {
  if(!tokenValid(token)) fail(404,'not_found');
  const row=await env.DB.prepare('SELECT * FROM orders WHERE id=? AND checkout_hash=? AND environment=?').bind(id,await sha256(token),env.PAYMENT_ENV).first();
  if(!row) fail(404,'not_found');
  if(row.status!=='pending') return html('<h1>返回 MacMP4</h1><p>請在 App 中檢查此筆訂單狀態。</p>');
  if(env.CHECKOUT_ENABLED!=='true') fail(503,'checkout_unavailable');
  if(Date.now()/1000-row.created_at>3600) fail(410,'checkout_expired');
  // 規格即時核對：2026-10-28，2862.md、7328.md；固定伺服器端價格，拒絕前端指定金額。
  const params={MerchantID:env.ECPAY_MERCHANT_ID, MerchantTradeNo:row.id, MerchantTradeDate:taiwanDate(row.created_at*1000),
    PaymentType:'aio', TotalAmount:'90', TradeDesc:'MacMP4 Pro', ItemName:'MacMP4 Pro Lifetime',
    ReturnURL:`${cfg.callback}/ecpay/notify`, ClientBackURL:`${cfg.base}/thanks`,
    ChoosePayment:row.method, EncryptType:'1', NeedExtraPaidInfo:'N', ItemURL:'https://jimmy-tools.com/MacMP4/'};
  params.CheckMacValue=await checkMacValue(params,env.ECPAY_HASH_KEY,env.ECPAY_HASH_IV);
  const fields=Object.entries(params).map(([k,v])=>`<input type="hidden" name="${escapeHTML(k)}" value="${escapeHTML(v)}">`).join('');
  return html(`<h1>超級感謝</h1><p>MacMP4 Pro · NT$90 終身買斷</p><p>${env.PAYMENT_ENV==='staging'?'測試環境，不會真的扣款。':'付款完成後，請回到 App，自動啟用 Pro。'}</p><p>本商店僅支援台灣發行的信用卡，暫不支援海外發行信用卡。</p><form method="post" action="${cfg.action}">${fields}<button type="submit">${row.method==='ApplePay'?'使用 Apple Pay 付款':'信用卡付款'}</button></form><p>購買資訊由 App 填寫；卡片資料直接交由綠界處理。</p><p><a href="/privacy">隱私說明</a> · <a href="mailto:acsd6850@hotmail.com">客服信箱</a></p>`,new URL(cfg.action).origin);
}
async function notify(request,env) {
  // 付款通知規格：2026-10-28 https://developers.ecpay.com.tw/2878.md、2858.md。
  const params=await body(request,'application/x-www-form-urlencoded');
  if(!await verifyMac(params,env.ECPAY_HASH_KEY,env.ECPAY_HASH_IV)) return text('0|Invalid signature');
  if(params.MerchantID!==env.ECPAY_MERCHANT_ID) return text('0|Merchant mismatch');
  const row=await env.DB.prepare('SELECT * FROM orders WHERE id=? AND environment=?').bind(params.MerchantTradeNo ?? '',env.PAYMENT_ENV).first();
  if(!row || params.TradeAmt!==String(row.amount)) return text('0|Order mismatch');
  if(env.PAYMENT_ENV==='production' && params.SimulatePaid!=='0') return text('0|Simulation rejected');
  if(!['0','1'].includes(params.SimulatePaid)) return text('0|Invalid simulation');
  if(params.RtnCode!=='1') return text('1|OK'); // 授權失敗不覆寫已付款狀態，後續有效成功通知仍可處理。
  if(!/^[A-Za-z0-9]{1,20}$/.test(params.TradeNo ?? '')) return text('0|Invalid trade');
  if(row.status==='paid' && row.provider_trade_no!==params.TradeNo) return text('0|Trade mismatch');
  // 單一原子更新；重複、併發、亂序與已撤銷的通知皆不重發授權。
  await env.DB.prepare("UPDATE orders SET status='paid',paid_at=?,provider_trade_no=? WHERE id=? AND environment=? AND status='pending'")
    .bind(Math.floor(Date.now()/1000),params.TradeNo,row.id,env.PAYMENT_ENV).run();
  return text('1|OK');
}
async function activate(request,env,cfg) {
  rejectBrowserMutation(request,cfg.base); await rateLimit(request,env,'activate',10);
  const data=await body(request,'application/json'), email=normalizeEmail(data.email), serial=serialCanonical(data.serial);
  if(!email || !/^MP4[A-F0-9]{40}$/.test(serial)) fail(403,'invalid_license');
  const row=await env.DB.prepare('SELECT * FROM orders WHERE email_hash=? AND serial_hash=? AND environment=?')
    .bind(await keyedHash(env.LOOKUP_KEY,`email:${email}`),await sha256(serial),env.PAYMENT_ENV).first();
  if(!row || row.status==='pending') fail(403,'invalid_license');
  return json(await paidResult(row,env));
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
  if(path==='/ecpay/notify' && request.method==='POST') return notify(request,env);
  const page=path.match(/^\/checkout\/([A-Z0-9]{20})$/);
  if(page && request.method==='GET') return checkout(env,cfg,page[1],url.searchParams.get('token'));
  if(path==='/thanks' && request.method==='GET') return html('<h1>請回到 MacMP4</h1><p>App 會向伺服器確認付款結果，再自動啟用 Pro。這個頁面不會直接啟用授權。</p><p>尚未啟用時，請在 App 按「檢查付款」。</p>');
  if(path==='/privacy' && request.method==='GET') return html('<h1>MacMP4 Pro 隱私說明</h1><p>開發者：JimmyLC。購買時提供的 Email 與序號會加密保存於 Cloudflare D1，僅用於授權、重裝啟用與客服。付款資料由綠界處理，MacMP4 不儲存卡號。影片保留於你的電腦，不會上傳。</p><p>已付款與撤銷訂單保留，以支援終身授權及交易核對；未付款訂單於 30 天後刪除。流量限制用的 IP 雜湊桶最多保留 2 天。Cloudflare 與綠界另依其政策處理連線資料。</p><p>請妥善保存 Email 與序號，任何持有兩者的人皆可恢復授權。本系統不提供公開 Email 查序號。</p><p>存取、更正、刪除資料或退款需求：<a href="mailto:acsd6850@hotmail.com">acsd6850@hotmail.com</a>。刪除授權資料將失去線上恢復能力。</p>');
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
  }
};
