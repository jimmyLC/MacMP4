import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import worker from '../src/worker.mjs';
import {bytes,randomToken,checkMacValue,verifyMac,unbase64url} from '../src/crypto.mjs';
function database() {
  const raw=new DatabaseSync(':memory:');
  raw.exec(readFileSync(new URL('../migrations/0001_orders.sql',import.meta.url),'utf8'));
  return {raw,prepare(sql) {return {bind(...args) {return {
    async first(){return raw.prepare(sql).get(...args) ?? null;},async run(){return raw.prepare(sql).run(...args);}
  };}};},async batch(items){return Promise.all(items.map(i=>i.run()));}};
}
async function setup(environment='staging') {
  const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  return {DB:database(),PAYMENT_ENV:environment,CHECKOUT_ENABLED:'true',APPLE_PAY_ENABLED:'true',
    PUBLIC_BASE_URL:'https://pay.example.com',CALLBACK_BASE_URL:'https://callback.example.com',
    ECPAY_MERCHANT_ID:environment==='staging'?'3002607':'3999999',
    ECPAY_HASH_KEY:environment==='staging'?'pwFHCqoQZGmho4w6':'1234567890123456',ECPAY_HASH_IV:'EkRm7iFT261dpevs',
    DATA_KEY:randomToken(),LOOKUP_KEY:randomToken(),LICENSE_SIGNING_JWK:JSON.stringify(await crypto.subtle.exportKey('jwk',keys.privateKey)),keys};
}
const req=(path,options={})=>new Request('https://pay.example.com'+path,options);
const post=(path,data,headers={})=>req(path,{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(data)});
async function order(env,extra={}) {
  const data={email:'Buyer@example.com',method:'ApplePay',accessToken:randomToken(),...extra};
  const r=await worker.fetch(post('/v1/orders',data),env);
  assert.equal(r.status,201,await r.clone().text());
  return {...data,...await r.json()};
}
async function notify(env,o,extra={},sign=true) {
  const p={MerchantID:env.ECPAY_MERCHANT_ID,MerchantTradeNo:o.orderId,RtnCode:'1',RtnMsg:'Succeeded',
    TradeNo:'T1234567890',TradeAmt:'90',PaymentDate:'2026/10/28 12:00:00',PaymentType:'Credit_CreditCard',SimulatePaid:'0',...extra};
  p.CheckMacValue=sign?await checkMacValue(p,env.ECPAY_HASH_KEY,env.ECPAY_HASH_IV):'0'.repeat(64);
  return worker.fetch(req('/ecpay/notify',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(p)}),env);
}
const status=(env,o,token=o.accessToken)=>worker.fetch(req('/v1/orders/'+o.orderId,{headers:{Authorization:'Bearer '+token}}),env);
test('官方 SHA256 向量：空格、波浪號、單引號與簽章驗證',async()=>{
  const cases=[
    ["Tom's Shop",'100','CF0A3D4901D99459D8641516EC57210700E8A5C9AB26B1D021301E9CB93EF78D'],
    ['Test~Product','200','CEEAE01D2F9A8E74D4AC0DCE7735B046D73F35A5EC99558A31A2EE03159DA1C9'],
    ['My Test Product','300','7712A5E6EDC3B57086063C88568084C66CE882A21D40E74DE5ACA3B478C6F316']];
  for(const [ItemName,TotalAmount,expected] of cases) {
    const p={MerchantID:'3002607',ItemName,TotalAmount};
    assert.equal(await checkMacValue(p,'pwFHCqoQZGmho4w6','EkRm7iFT261dpevs'),expected);
    assert.equal(await verifyMac({...p,CheckMacValue:expected},'pwFHCqoQZGmho4w6','EkRm7iFT261dpevs'),true);
    assert.equal(await verifyMac({...p,CheckMacValue:'bad'},'pwFHCqoQZGmho4w6','EkRm7iFT261dpevs'),false);
  }
});
test('固定金額、加密、冪等、簽章表單與訂單查詢權限',async()=>{
  const env=await setup(),o=await order(env,{amount:1});
  assert.equal(o.amount,90);
  const row=env.DB.raw.prepare('SELECT * FROM orders').get();
  assert.equal(row.amount,90);assert.equal(row.private_data.includes('buyer'),false);
  const retry=await worker.fetch(post('/v1/orders',o),env);assert.equal(retry.status,200);
  assert.equal((await retry.json()).orderId,o.orderId);
  assert.equal(env.DB.raw.prepare('SELECT count(*) AS n FROM orders').get().n,1);
  const page=await worker.fetch(new Request(o.checkoutURL),env),html=await page.text();
  assert.match(html,/payment-stage.ecpay.com.tw/);assert.doesNotMatch(html,/Buyer@example.com|pwFHCqoQZGmho4w6|EkRm7iFT261dpevs/);
  const p=Object.fromEntries([...html.matchAll(/name="([^"]+)" value="([^"]*)"/g)].map(m=>[m[1],m[2].replaceAll('&amp;','&')]));
  assert.equal(p.TotalAmount,'90');assert.equal(p.ChoosePayment,'ApplePay');assert.equal(p.EncryptType,'1');
  assert.equal(await verifyMac(p,env.ECPAY_HASH_KEY,env.ECPAY_HASH_IV),true);
  assert.notEqual(p.ReturnURL,p.ClientBackURL);
  assert.equal((await status(env,o,randomToken())).status,404);
  assert.deepEqual(await (await status(env,o)).json(),{status:'pending'});
});
test('未付款、前景跳轉、偽造簽章／金額／商店均不啟用',async()=>{
  const env=await setup(),o=await order(env);
  assert.equal((await worker.fetch(post('/v1/licenses/activate',{email:o.email,serial:'MP4-'+'A'.repeat(40)}),env)).status,403);
  for(const [extra,sign] of [[{},false],[{TradeAmt:'1'},true],[{MerchantID:'3999999'},true]]) {
    assert.match(await (await notify(env,o,extra,sign)).text(),/^0\|/);
    assert.equal((await (await status(env,o)).json()).status,'pending');
  }
  await worker.fetch(req('/thanks?RtnCode=1'),env);
  assert.equal((await (await status(env,o)).json()).status,'pending');
});
test('付款回呼、重送／亂序、Email＋序號恢復、撤銷與簽章',async()=>{
  const env=await setup(),o=await order(env);
  assert.equal(await (await notify(env,o)).text(),'1|OK');
  const first=env.DB.raw.prepare('SELECT * FROM orders').get();
  for(let i=0;i<3;i++)assert.equal(await (await notify(env,o)).text(),'1|OK');
  await notify(env,o,{RtnCode:'999'});
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
  await notify(env,o);assert.equal(env.DB.raw.prepare('SELECT status FROM orders').get().status,'revoked');
});
test('正式環境拒絕模擬付款與公開測試金鑰',async()=>{
  const env=await setup('production'),o=await order(env);
  assert.match(await (await notify(env,o,{SimulatePaid:'1'})).text(),/^0\|/);
  assert.equal((await (await status(env,o)).json()).status,'pending');
  env.ECPAY_MERCHANT_ID='3002607';assert.equal((await worker.fetch(req('/v1/config'),env)).status,503);
});
test('缺少設定、停用收款、來源、速率、重複欄位與內容大小限制',async()=>{
  const env=await setup();
  assert.equal((await worker.fetch(post('/v1/orders',{}, {Origin:'https://evil.example'}),env)).status,403);
  assert.equal((await worker.fetch(post('/v1/orders',{}, {'Content-Type':'text/plain'}),env)).status,415);
  assert.equal((await worker.fetch(post('/v1/orders',{email:'a'.repeat(17000)}),env)).status,413);
  assert.equal((await worker.fetch(req('/ecpay/notify',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'MerchantID=1&MerchantID=2'}),env)).status,400);
  for(let i=0;i<10;i++)await worker.fetch(post('/v1/licenses/activate',{}),env);
  assert.equal((await worker.fetch(post('/v1/licenses/activate',{}),env)).status,429);
  env.CHECKOUT_ENABLED='false';assert.equal((await worker.fetch(post('/v1/orders',{}),env)).status,503);
  env.DATA_KEY='';assert.equal((await worker.fetch(req('/v1/config'),env)).status,503);
});
test('資料庫失敗不確認通知；只清理未付款過期訂單',async()=>{
  const env=await setup(),o=await order(env);
  env.DB.raw.prepare('UPDATE orders SET created_at=0').run();await worker.scheduled(null,env);
  assert.equal(env.DB.raw.prepare('SELECT count(*) AS n FROM orders').get().n,0);
  const paid=await order(env);await notify(env,paid);env.DB.raw.prepare('UPDATE orders SET created_at=0').run();await worker.scheduled(null,env);
  assert.equal(env.DB.raw.prepare('SELECT count(*) AS n FROM orders').get().n,1);
  env.DB={prepare(){throw new Error('database down');}};assert.equal((await notify(env,paid)).status,503);
});
