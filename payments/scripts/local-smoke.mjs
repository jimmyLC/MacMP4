import assert from 'node:assert/strict';
import {randomToken} from '../src/crypto.mjs';
// 本機 workerd＋D1：不連 SHOPLINE。驗證建單、未簽名 Webhook 被拒、授權不會被前景頁啟用。
const base='http://127.0.0.1:8792';
const options=await fetch(base+'/v1/config');assert.equal(options.status,200);assert.equal((await options.json()).environment,'staging');
const token=randomToken();
const create=await fetch(base+'/v1/orders',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:'worker-smoke@example.com',method:'Credit',accessToken:token})});
assert.equal(create.status,201,await create.clone().text());const order=await create.json();
const hook=await fetch(base+'/shopline/webhook',{method:'POST',headers:{'Content-Type':'application/json',timestamp:String(Date.now()),sign:'0'.repeat(64)},body:JSON.stringify({type:'trade.succeeded',data:{referenceOrderId:order.orderId}})});
assert.equal(hook.status,401);
const query=await fetch(base+'/v1/orders/'+order.orderId,{headers:{Authorization:'Bearer '+token}});
assert.equal((await query.json()).status,'pending');
console.log('PASS: 本機 worker 建單、拒絕未簽名 Webhook、訂單維持待付款');
