// 僅在部署獲核准後執行；透過 stdin 上傳，避免 argv、日誌及 shell history 暴露密鑰。
import {readFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
const environment=process.argv[2];
if(!['staging','production'].includes(environment))throw new Error('指定 staging 或 production');
const file=new URL(environment==='production'?'../.dev.vars.production':'../.dev.vars',import.meta.url);
const all={};for(const line of (await readFile(file,'utf8')).split('\n')){const i=line.indexOf('=');if(i>0)all[line.slice(0,i)]=line.slice(i+1);}
const secrets={};for(const key of ['ECPAY_MERCHANT_ID','ECPAY_HASH_KEY','ECPAY_HASH_IV','DATA_KEY','LOOKUP_KEY','LICENSE_SIGNING_JWK']) {
  if(!all[key])throw new Error(`缺少 ${key}`);secrets[key]=all[key];
}
const args=['secret','bulk','--config','wrangler.jsonc'];if(environment==='production')args.push('--env','production');
const result=spawnSync(new URL('../node_modules/.bin/wrangler',import.meta.url).pathname,args,
  {cwd:new URL('..',import.meta.url),input:JSON.stringify(secrets),encoding:'utf8',stdio:['pipe','pipe','pipe']});
if(result.status!==0)throw new Error('上傳失敗。請檢查 Wrangler 登入與 Worker 名稱；未顯示輸出以保護機密。');
console.log(`已上傳 ${Object.keys(secrets).length} 個機密欄位；未顯示值。`);
