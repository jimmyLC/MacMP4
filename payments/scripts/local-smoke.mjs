import assert from 'node:assert/strict';
import {randomToken,checkMacValue} from '../src/crypto.mjs';
const base='http://127.0.0.1:8792';
const options=await fetch(base+'/v1/config');assert.equal(options.status,200);assert.equal((await options.json()).environment,'staging');
const token=randomToken();
const create=await fetch(base+'/v1/orders',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:'worker-smoke@example.com',method:'ApplePay',accessToken:token})});
assert.equal(create.status,201,await create.clone().text());const order=await create.json();
const checkout=new URL(order.checkoutURL);
const page=await fetch(base+checkout.pathname+checkout.search);const html=await page.text();assert.equal(page.status,200);
assert.match(html,/本商店僅支援台灣發行的信用卡，暫不支援海外發行信用卡/);assert.match(html,/Apple Pay/);
const query=()=>fetch(base+'/v1/orders/'+order.orderId,{headers:{Authorization:'Bearer '+token}});
assert.equal((await (await query()).json()).status,'pending');
const params={MerchantID:'3002607',MerchantTradeNo:order.orderId,RtnCode:'1',RtnMsg:'Succeeded',TradeNo:'S'+Date.now(),TradeAmt:'90',SimulatePaid:'1',PaymentDate:'2026/10/28 12:00:00'};
params.CheckMacValue=await checkMacValue(params,'pwFHCqoQZGmho4w6','EkRm7iFT261dpevs');
for(let i=0;i<2;i++){
 const r=await fetch(base+'/ecpay/notify',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(params)});
 assert.equal(await r.text(),'1|OK');
}
const paid=await (await query()).json();assert.equal(paid.status,'paid');assert.ok(paid.licenseToken);
const restore=await fetch(base+'/v1/licenses/activate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:'worker-smoke@example.com',serial:paid.serial})});
assert.equal(restore.status,200);
console.log('PASS: 原生 workerd＋本機 D1 建單、付款頁台灣卡說明、簽章回呼、重送、啟用與 Email＋序號恢復（僅本機公開測試帳號）');
