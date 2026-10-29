// jimmy-tools 收款中樞：SHOPLINE 只登記這一個 Webhook，依訂單編號開頭轉給各產品 Worker。
// 轉送前先驗簽章與時間戳；產品 Worker 收到後會再驗一次並向 SHOPLINE 查詢確認。
import {hmacHex, verifyWebhookSignature} from './signature.mjs';
export {hmacHex};
// 訂單編號第一個字 → service binding 名稱。新增產品時在這裡與 wrangler.jsonc 各加一行。
export const ROUTES = {M:'MACMP4'};
const HEADERS = {'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'};
const reply = (body, status=200) => new Response(body, {status, headers:{...HEADERS,'Content-Type':'text/plain'}});
async function readBody(request) {
  const reader = request.body?.getReader();
  if (!reader) return null;
  const chunks=[]; let length=0;
  while (true) { const {done,value}=await reader.read(); if(done) break; length+=value.byteLength;
    if(length>65536) { await reader.cancel(); return null; } chunks.push(value); }
  const all=new Uint8Array(length); let offset=0;
  for(const chunk of chunks) { all.set(chunk,offset); offset+=chunk.byteLength; }
  try { return new TextDecoder('utf-8',{fatal:true}).decode(all); } catch { return null; }
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname==='/health') return reply('ok');
    if (url.pathname!=='/shopline/webhook' || request.method!=='POST') return reply('not found',404);
    const timestamp = request.headers.get('timestamp') ?? '', sign = request.headers.get('sign');
    const raw = await readBody(request);
    if (raw===null) return reply('invalid body',400);
    if (!/^\d{13}$/.test(timestamp) || Math.abs(Date.now()-Number(timestamp))>5*60*1000) return reply('timestamp',401);
    if (!env.SHOPLINE_SIGN_KEY || !await verifyWebhookSignature(timestamp,raw,sign,env.SHOPLINE_SIGN_KEY)) return reply('signature',401);
    let id=''; try { id=String(JSON.parse(raw)?.data?.referenceOrderId ?? ''); } catch { return reply('invalid json',400); }
    const binding = ROUTES[id[0]];
    if (!binding || !env[binding]) return reply('OK'); // 不是我們認得的產品：確認收到，不重試。
    // 原樣轉送（含 timestamp、sign），產品 Worker 以同一把 Sign Key 再驗一次。
    const forwarded = await env[binding].fetch('https://internal/shopline/webhook',
      {method:'POST',headers:{'Content-Type':'application/json',timestamp,sign},body:raw});
    // 產品端失敗（如資料庫暫時故障）就回非 200，讓 SHOPLINE 重送。
    return forwarded.ok ? reply('OK') : reply('upstream',502);
  }
};
