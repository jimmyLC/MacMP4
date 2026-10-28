// 建立專屬授權金鑰，不輸出機密；不連線、不部署、不收款。
import {readFile,writeFile,chmod} from 'node:fs/promises';
import {randomToken,unbase64url} from '../src/crypto.mjs';
const [environment,apiURL,callbackURL=apiURL]=process.argv.slice(2);
if(!['staging','production'].includes(environment)||!apiURL)throw new Error('用法：node scripts/prepare-config.mjs staging|production https://API主機 https://回呼主機');
for(const value of [apiURL,callbackURL]) {
  const u=new URL(value);if(u.protocol!=='https:'||u.pathname!=='/'||u.search||u.hash||u.username||u.password||u.port)throw new Error('必須使用 HTTPS 主機網址');
}
const path=new URL(environment==='production'?'../.dev.vars.production':'../.dev.vars',import.meta.url);
let values={};
try {
  const source=await readFile(path,'utf8');
  for(const line of source.split('\n')){const i=line.indexOf('=');if(i>0)values[line.slice(0,i)]=line.slice(i+1);}
} catch(e){if(e.code!=='ENOENT')throw e;}
if(environment==='staging')Object.assign(values,{ECPAY_MERCHANT_ID:'3002607',ECPAY_HASH_KEY:'pwFHCqoQZGmho4w6',ECPAY_HASH_IV:'EkRm7iFT261dpevs'});
if(!values.LICENSE_SIGNING_JWK){
  const pair=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
  values.LICENSE_SIGNING_JWK=JSON.stringify(await crypto.subtle.exportKey('jwk',pair.privateKey));
}
values.DATA_KEY ||= randomToken();values.LOOKUP_KEY ||= randomToken();
Object.assign(values,{PAYMENT_ENV:environment,PUBLIC_BASE_URL:apiURL,CALLBACK_BASE_URL:callbackURL,CHECKOUT_ENABLED:'false',APPLE_PAY_ENABLED:'true'});
await writeFile(path,Object.entries(values).map(([k,v])=>`${k}=${v}`).join('\n')+'\n',{mode:0o600});await chmod(path,0o600);
const jwk=JSON.parse(values.LICENSE_SIGNING_JWK);
const publicRaw=Buffer.concat([Buffer.from([4]),Buffer.from(unbase64url(jwk.x)),Buffer.from(unbase64url(jwk.y))]);
const publicConfig={enabled:false,apiBaseURL:apiURL,environment,publicKey:publicRaw.toString('base64')};
const output=new URL(`../ProConfiguration.${environment}.public.json`,import.meta.url);
await writeFile(output,JSON.stringify(publicConfig,null,2)+'\n');
console.log(`已準備 ${environment} 本機私密設定（600）及對應的公開設定。收款維持關閉；未部署。`);
