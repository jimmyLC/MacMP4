// 與 payments/src/crypto.mjs 相同的 Webhook 驗簽（只保留中樞需要的部分）。
const encoder = new TextEncoder();
const bytes = value => encoder.encode(value);
export async function hmacHex(secret, value) {
  const key = await crypto.subtle.importKey('raw', bytes(secret), {name:'HMAC', hash:'SHA-256'}, false, ['sign']);
  return [...new Uint8Array(await crypto.subtle.sign('HMAC', key, bytes(value)))].map(n=>n.toString(16).padStart(2,'0')).join('');
}
export async function verifyWebhookSignature(timestamp, bodyString, sign, signKey) {
  if (!/^[A-Fa-f0-9]{64}$/.test(sign ?? '')) return false;
  const key = await crypto.subtle.importKey('raw', bytes(signKey), {name:'HMAC', hash:'SHA-256'}, false, ['sign','verify']);
  const expected = await hmacHex(signKey, `${timestamp}.${bodyString}`);
  const tag = await crypto.subtle.sign('HMAC', key, bytes(expected));
  // WebCrypto 的 HMAC verify 為時間安全比對，不以字串 == 比對機密。
  return crypto.subtle.verify('HMAC', key, tag, bytes(sign.toLowerCase()));
}
