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
// 規格核對：2026-10-28 https://developers.ecpay.com.tw/2902.md
// 翻譯基準：官方 SDK_PHP/src/Services/CheckMacValueService.php、UrlService.php。
export async function checkMacValue(params, hashKey, hashIV) {
  const sorted = Object.keys(params).filter(k => k.toLowerCase() !== 'checkmacvalue')
    .sort((a,b) => a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0);
  const source = `HashKey=${hashKey}&${sorted.map(k=>`${k}=${params[k]}`).join('&')}&HashIV=${hashIV}`;
  const encoded = encodeURIComponent(source).replaceAll('~', '%7E').replaceAll("'", '%27').replaceAll('%20', '+').toLowerCase();
  const digest = await crypto.subtle.digest('SHA-256', bytes(encoded));
  return [...new Uint8Array(digest)].map(n=>n.toString(16).padStart(2,'0')).join('').toUpperCase();
}
export async function verifyMac(params, hashKey, hashIV) {
  if (!/^[A-Fa-f0-9]{64}$/.test(params.CheckMacValue ?? '')) return false;
  const expected = await checkMacValue(params, hashKey, hashIV);
  // WebCrypto 的 HMAC verify 為時間安全比對，不以字串 == 比對機密。
  const key = await crypto.subtle.importKey('raw', bytes(hashKey), {name:'HMAC', hash:'SHA-256'}, false, ['sign','verify']);
  const tag = await crypto.subtle.sign('HMAC', key, bytes(expected));
  return crypto.subtle.verify('HMAC', key, tag, bytes(params.CheckMacValue.toUpperCase()));
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
