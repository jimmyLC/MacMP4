import {test} from 'node:test';
import assert from 'node:assert/strict';
import worker, {hmacHex} from '../src/worker.mjs';
const KEY='hub-sign-key-0123456789';
function env(upstreamStatus=200){const seen=[];return {SHOPLINE_SIGN_KEY:KEY,seen,MACMP4:{async fetch(url,init){seen.push({url,init});return new Response('OK',{status:upstreamStatus});}}};}
async function hook(e,{id='MABC',timestamp=String(Date.now()),sign=true,body}={}) {
  const raw=body ?? JSON.stringify({type:'trade.succeeded',data:{referenceOrderId:id}});
  const signature=sign?await hmacHex(KEY,`${timestamp}.${raw}`):'0'.repeat(64);
  return worker.fetch(new Request('https://pay.example.com/shopline/webhook',{method:'POST',headers:{timestamp,sign:signature},body:raw}),e);
}
test('M 開頭的訂單原樣轉給 MacMP4，含原始 body 與簽章',async()=>{
  const e=env(),r=await hook(e);assert.equal(r.status,200);assert.equal(e.seen.length,1);
  assert.equal(e.seen[0].init.body,JSON.stringify({type:'trade.succeeded',data:{referenceOrderId:'MABC'}}));
  assert.match(e.seen[0].init.headers.sign,/^[0-9a-f]{64}$/);assert.match(e.seen[0].init.headers.timestamp,/^\d{13}$/);
});
test('未知開頭只確認收到，不轉送',async()=>{const e=env(),r=await hook(e,{id:'ZZZ'});assert.equal(r.status,200);assert.equal(e.seen.length,0);});
test('簽章錯誤、時間過期、格式錯誤一律拒絕且不轉送',async()=>{
  const e=env();
  assert.equal((await hook(e,{sign:false})).status,401);
  assert.equal((await hook(e,{timestamp:String(Date.now()-10*60*1000)})).status,401);
  assert.equal((await hook(e,{body:'not json'})).status,400);
  assert.equal(e.seen.length,0);
  const noKey={...env(),SHOPLINE_SIGN_KEY:''};assert.equal((await hook(noKey)).status,401);
});
test('產品端失敗時回 502 讓 SHOPLINE 重送；其他路徑與方法 404',async()=>{
  assert.equal((await hook(env(503))).status,502);
  assert.equal((await worker.fetch(new Request('https://pay.example.com/shopline/webhook'),env())).status,404);
  assert.equal((await worker.fetch(new Request('https://pay.example.com/x',{method:'POST'}),env())).status,404);
  assert.equal((await worker.fetch(new Request('https://pay.example.com/health'),env())).status,200);
});
test('SHOPLINE 的 RL 編號不影響路由：用 order.customer.referenceCustomerId 判斷產品',async()=>{
  const e=env(),body=JSON.stringify({type:'trade.succeeded',data:{referenceOrderId:'RL0126102900977667489309682366',order:{customer:{referenceCustomerId:'MABC'}}}});
  assert.equal((await hook(e,{body})).status,200);assert.equal(e.seen.length,1);
});
test('提供信件用的小圖示',async()=>{
  const r=await worker.fetch(new Request('https://pay.example.com/assets/macmp4-icon.png'),env());
  assert.equal(r.status,200);assert.equal(r.headers.get('Content-Type'),'image/png');
  const bytes=new Uint8Array(await r.arrayBuffer());assert.deepEqual([...bytes.slice(0,4)],[0x89,0x50,0x4e,0x47]);assert.ok(bytes.length<30000);
});
