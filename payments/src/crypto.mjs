const encoder = new TextEncoder();
export const bytes = value => encoder.encode(value);
export function base64url(data) {
  return btoa(String.fromCharCode(...new Uint8Array(data))).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}
export function unbase64url(value) {
  return Uint8Array.from(atob(value.replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0));
}
export const randomToken = () => base64url(crypto.getRandomValues(new Uint8Array(32)));
export async function sha256(value) { return base64url(await crypto.subtle.digest('SHA-256', bytes(value))); }
export async function keyedHash(secret, value) {
  const key = await crypto.subtle.importKey('raw', unbase64url(secret), {name:'HMAC', hash:'SHA-256'}, false, ['sign']);
  return base64url(await crypto.subtle.sign('HMAC', key, bytes(value)));
}
// SHOPLINE Webhook 簽章：HMAC-SHA256(`${timestamp}.${body}`, signKey)，十六進位。
// 規格核對：2026-10-29 shopline-payments-skill references/webhook.md。
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
export async function seal(value, secret) {
  const key = await crypto.subtle.importKey('raw', unbase64url(secret), 'AES-GCM', false, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({name:'AES-GCM', iv}, key, bytes(JSON.stringify(value)));
  return `${base64url(iv)}.${base64url(encrypted)}`;
}
export async function unseal(value, secret) {
  const [iv, data] = value.split('.');
  const key = await crypto.subtle.importKey('raw', unbase64url(secret), 'AES-GCM', false, ['decrypt']);
  const plain = await crypto.subtle.decrypt({name:'AES-GCM', iv:unbase64url(iv)}, key, unbase64url(data));
  return JSON.parse(new TextDecoder().decode(plain));
}
export async function signLicense(order, email, jwk) {
  const key = await crypto.subtle.importKey('jwk', JSON.parse(jwk), {name:'ECDSA', namedCurve:'P-256'}, false, ['sign']);
  const payload = {version:1, product:'macmp4-pro-lifetime', environment:order.environment,
    licenseId:order.id, email, issuedAt:order.paid_at, lifetime:true};
  const encoded = base64url(bytes(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign({name:'ECDSA', hash:'SHA-256'}, key, bytes(encoded));
  return `${encoded}.${base64url(signature)}`;
}
export function normalizeEmail(value) {
  if (typeof value !== 'string') return null;
  const email = value.trim().toLowerCase();
  return email.length <= 254 && /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}$/.test(email) ? email : null;
}
