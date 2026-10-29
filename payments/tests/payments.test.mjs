import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import worker from '../src/worker.mjs';
import {bytes,randomToken,hmacHex,verifyWebhookSignature,unbase64url} from '../src/crypto.mjs';
function database() {
  const raw=new DatabaseSync(':memory:');
  for(const file of ['0001_orders.sql','0002_shopline.sql']) raw.exec(readFileSync(new URL('../migrations/'+file,import.meta.url),'utf8'));
  return {raw,prepare(sql) {return {bind(...args) {return {
    async first(){return raw.prepare(sql).get(...args) ?? null;},async run(){return raw.prepare(sql).run(...args);}
  };}};},async batch(items){return Promise.all(items.map(i=>i.run()));}};
}
const SIGN_KEY='test-sign-key-0123456789';
async function setup(environment='staging') {
  const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  return {DB:database(),PAYMENT_ENV:environment,CHECKOUT_ENABLED:'true',APPLE_PAY_ENABLED:'true',
    PUBLIC_BASE_URL:'https://pay.example.com',CALLBACK_BASE_URL:'https://callback.example.com',
    SHOPLINE_MERCHANT_ID:'merchant-1',SHOPLINE_API_KEY:'api-key-0123456789',SHOPLINE_SIGN_KEY:SIGN_KEY,
    DATA_KEY:randomToken(),LOOKUP_KEY:randomToken(),LICENSE_SIGNING_JWK:JSON.stringify(await crypto.subtle.exportKey('jwk',keys.privateKey)),keys};
}
// 模擬 SHOPLINE API；記錄每次呼叫，供斷言標頭與內容。
const calls=[];
let tradeReply=null;
globalThis.fetch=async (url,init)=>{
  const body=JSON.parse(init.body);calls.push({url,headers:init.headers,body});
  const json=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}});
  if(url.endsWith('/api/v1/trade/sessions/create'))
    return json({sessionId:'se_'+body.referenceId,referenceId:body.referenceId,status:'CREATED',sessionUrl:'https://api-sandbox.shoplinepayments.com/checkout/session?sessionToken=abc'});
  if(url.endsWith('/api/v1/trade/payment/get')) return tradeReply?json(tradeReply(body)):json({code:'1004',msg:'Param error'},400);
  throw new Error('unexpected fetch '+url);
};
const req=(path,options={})=>new Request('https://pay.example.com'+path,options);
const post=(path,data,headers={})=>req(path,{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(data)});
async function order(env,extra={}) {
  const data={email:'Buyer@example.com',method:'ApplePay',accessToken:randomToken(),...extra};
  const r=await worker.fetch(post('/v1/orders',data),env);
  assert.equal(r.status,201,await r.clone().text());
  return {...data,...await r.json()};
}
const trade=(o,extra={})=>({tradeOrderId:'T'+o.orderId,referenceOrderId:o.orderId,status:'SUCCEEDED',paidAmount:{value:9000,currency:'TWD'},...extra});
async function webhook(env,o,{type='trade.succeeded',data={},timestamp=String(Date.now()),sign=true,reply}={}) {
  tradeReply=reply===undefined?t=>trade(o,{tradeOrderId:t.tradeOrderId}):reply;
  const raw=JSON.stringify({id:'evt1',type,created:Date.now(),data:{tradeOrderId:'T'+o.orderId,referenceOrderId:o.orderId,...data}});
  const signature=sign?await hmacHex(SIGN_KEY,`${timestamp}.${raw}`):'0'.repeat(64);
  return worker.fetch(req('/shopline/webhook',{method:'POST',headers:{'Content-Type':'application/json',timestamp,sign:signature},body:raw}),env);
}
const status=(env,o,token=o.accessToken)=>worker.fetch(req('/v1/orders/'+o.orderId,{headers:{Authorization:'Bearer '+token}}),env);
test('Webhook 簽章：timestamp.body 的 HMAC-SHA256，竄改與錯誤格式皆拒絕',async()=>{
  const sign=await hmacHex(SIGN_KEY,'1760000000000.{"a":1}');
  assert.match(sign,/^[0-9a-f]{64}$/);
  assert.equal(await verifyWebhookSignature('1760000000000','{"a":1}',sign,SIGN_KEY),true);
  assert.equal(await verifyWebhookSignature('1760000000000','{"a":2}',sign,SIGN_KEY),false);
  assert.equal(await verifyWebhookSignature('1760000000001','{"a":1}',sign,SIGN_KEY),false);
  assert.equal(await verifyWebhookSignature('1760000000000','{"a":1}','bad',SIGN_KEY),false);
  assert.equal(await verifyWebhookSignature('1760000000000','{"a":1}',sign,'other-key-0123456789'),false);
});
test('固定金額、加密、冪等、結帳導轉與訂單查詢權限',async()=>{
  calls.length=0;
  const env=await setup(),o=await order(env,{amount:1});
  assert.equal(o.amount,90);
  const row=env.DB.raw.prepare('SELECT * FROM orders').get();
  assert.equal(row.amount,90);assert.equal(row.private_data.includes('buyer'),false);
  const retry=await worker.fetch(post('/v1/orders',o),env);assert.equal(retry.status,200);
  assert.equal((await retry.json()).orderId,o.orderId);
  assert.equal(env.DB.raw.prepare('SELECT count(*) AS n FROM orders').get().n,1);
  const page=await worker.fetch(new Request(o.checkoutURL),env);
  assert.equal(page.status,302);
  assert.match(page.headers.get('Location'),/^https:\/\/api-sandbox\.shoplinepayments\.com\/checkout\/session/);
  const [call]=calls;
  assert.equal(call.url,'https://api-sandbox.shoplinepayments.com/api/v1/trade/sessions/create');
  assert.equal(call.body.amount.value,9000);assert.equal(call.body.amount.currency,'TWD');
  assert.deepEqual(call.body.allowPaymentMethodList,['ApplePay']);assert.equal(call.body.referenceId,o.orderId);
  assert.equal(call.body.returnUrl,'https://pay.example.com/thanks');
  assert.equal(call.body.order.shipping.shippingMethod,'digital');assert.equal(call.body.order.shipping.address.countryCode,'TW');
  assert.equal(call.body.billing.address.countryCode,'TW');
  assert.equal(call.headers.merchantId,'merchant-1');assert.equal(call.headers.apiKey,'api-key-0123456789');
  assert.match(call.headers.requestId,/^[0-9a-f]{32}$/);
  assert.doesNotMatch(JSON.stringify(call.body),/api-key-0123456789|test-sign-key/);
  // 再開同一個結帳連結不會重複建立 session。
  const again=await worker.fetch(new Request(o.checkoutURL),env);assert.equal(again.status,302);assert.equal(calls.length,1);
  assert.equal((await status(env,o,randomToken())).status,404);
  assert.deepEqual(await (await status(env,o)).json(),{status:'pending'});
});
test('信用卡訂單送出 CreditCard；供應商回應異常時不導轉',async()=>{
  calls.length=0;
  const env=await setup(),o=await order(env,{method:'Credit'});
  await worker.fetch(new Request(o.checkoutURL),env);
  assert.deepEqual(calls[0].body.allowPaymentMethodList,['CreditCard']);
  const real=globalThis.fetch;
  globalThis.fetch=async()=>new Response(JSON.stringify({code:'1004'}),{status:400});
  const bad=await order(env,{method:'Credit'});
  assert.equal((await worker.fetch(new Request(bad.checkoutURL),env)).status,502);
  globalThis.fetch=async()=>new Response(JSON.stringify({sessionId:'s',referenceId:bad.orderId,sessionUrl:'https://evil.example/pay'}),{status:200});
  assert.equal((await worker.fetch(new Request(bad.checkoutURL),env)).status,502);
  globalThis.fetch=real;
});
test('未付款、前景跳轉、偽造簽章／過期時間／金額／訂單均不啟用',async()=>{
  const env=await setup(),o=await order(env);
  assert.equal((await worker.fetch(post('/v1/licenses/activate',{email:o.email,serial:'MP4-'+'A'.repeat(40)}),env)).status,403);
  assert.equal((await webhook(env,o,{sign:false})).status,401);
  assert.equal((await webhook(env,o,{timestamp:String(Date.now()-10*60*1000)})).status,401);
  for(const reply of [t=>trade(o,{paidAmount:{value:100,currency:'TWD'}}),t=>trade(o,{referenceOrderId:'MOTHER'}),
    t=>trade(o,{status:'FAILED'}),t=>trade(o,{tradeOrderId:'other'}),null]) {
    if(reply===null) assert.equal((await webhook(env,o,{reply})).status,502);
    else assert.equal((await webhook(env,o,{reply})).status,200);
    assert.equal((await (await status(env,o)).json()).status,'pending');
  }
  assert.equal((await webhook(env,o,{type:'trade.failed'})).status,200);
  await worker.fetch(req('/thanks?status=SUCCEEDED'),env);
  assert.equal((await (await status(env,o)).json()).status,'pending');
});
test('付款通知、重送、Email＋序號恢復、撤銷與簽章',async()=>{
  const env=await setup(),o=await order(env);
  assert.equal((await webhook(env,o)).status,200);
  const first=env.DB.raw.prepare('SELECT * FROM orders').get();
  assert.equal(first.status,'paid');assert.equal(first.provider_trade_no,'T'+o.orderId);
  for(let i=0;i<3;i++)assert.equal((await webhook(env,o)).status,200);
  assert.equal(env.DB.raw.prepare('SELECT * FROM orders').get().paid_at,first.paid_at);
  const result=await (await status(env,o)).json();assert.equal(result.status,'paid');assert.equal(result.email,'buyer@example.com');
  const [payload,signature]=result.licenseToken.split('.');
  assert.equal(await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},env.keys.publicKey,unbase64url(signature),bytes(payload)),true);
  const claims=JSON.parse(new TextDecoder().decode(unbase64url(payload)));
  assert.equal(claims.lifetime,true);assert.equal(claims.environment,'staging');
  assert.equal((await worker.fetch(post('/v1/licenses/activate',{email:' BUYER@example.com ',serial:result.serial}),env)).status,200);
  assert.equal((await worker.fetch(post('/v1/licenses/activate',{email:'other@example.com',serial:result.serial}),env)).status,403);
  env.DB.raw.prepare("UPDATE orders SET status='revoked'").run();
  assert.equal((await worker.fetch(post('/v1/licenses/activate',{email:result.email,serial:result.serial}),env)).status,409);
  await webhook(env,o);assert.equal(env.DB.raw.prepare('SELECT status FROM orders').get().status,'revoked');
});
test('正式環境使用正式 API 網址',async()=>{
  calls.length=0;
  const env=await setup('production'),o=await order(env);
  await worker.fetch(new Request(o.checkoutURL),env);
  assert.equal(calls[0].url,'https://api.shoplinepayments.com/api/v1/trade/sessions/create');
});
test('缺少設定、停用收款、來源、速率、內容大小限制',async()=>{
  const env=await setup();
  assert.equal((await worker.fetch(post('/v1/orders',{}, {Origin:'https://evil.example'}),env)).status,403);
  assert.equal((await worker.fetch(post('/v1/orders',{}, {'Content-Type':'text/plain'}),env)).status,415);
  assert.equal((await worker.fetch(post('/v1/orders',{email:'a'.repeat(17000)}),env)).status,413);
  for(let i=0;i<10;i++)await worker.fetch(post('/v1/licenses/activate',{}),env);
  assert.equal((await worker.fetch(post('/v1/licenses/activate',{}),env)).status,429);
  env.CHECKOUT_ENABLED='false';assert.equal((await worker.fetch(post('/v1/orders',{}),env)).status,503);
  env.DATA_KEY='';assert.equal((await worker.fetch(req('/v1/config'),env)).status,503);
  const env2=await setup();env2.SHOPLINE_SIGN_KEY='';assert.equal((await worker.fetch(req('/v1/config'),env2)).status,503);
});
test('資料庫失敗不確認通知；只清理未付款過期訂單',async()=>{
  const env=await setup(),o=await order(env);
  env.DB.raw.prepare('UPDATE orders SET created_at=0').run();await worker.scheduled(null,env);
  assert.equal(env.DB.raw.prepare('SELECT count(*) AS n FROM orders').get().n,0);
  const paid=await order(env);await webhook(env,paid);env.DB.raw.prepare('UPDATE orders SET created_at=0').run();await worker.scheduled(null,env);
  assert.equal(env.DB.raw.prepare('SELECT count(*) AS n FROM orders').get().n,1);
  env.DB={prepare(){throw new Error('database down');}};assert.equal((await webhook(env,paid)).status,503);
});
