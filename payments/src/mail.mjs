// 購買完成信（繁體中文／English）。版面用表格與行內樣式，相容各家信箱；序號另附純文字版。
const escapeHTML = value => String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const SITE = 'https://jimmy-tools.com/MacMP4/';
const ICON = 'https://pay.jimmy-tools.com/assets/macmp4-icon.png';
const SUPPORT = 'contact@jimmy-tools.com';
const COPY = {
  'zh-Hant': {
    lang:'zh-Hant', subject:'你的 MacMP4 Pro 序號', title:'感謝你的購買！',
    intro:'Pro 已在你付款的這台電腦自動啟用。換電腦或重灌時，在新電腦輸入下方的序號就能恢復，不用再買一次。',
    product:'產品', productValue:'MacMP4 Pro（終身買斷）', email:'購買 Email', serial:'序號', button:'前往 MacMP4 下載頁',
    stepsTitle:'換電腦時怎麼做',
    steps:['在新電腦安裝 MacMP4，打開「超級感謝」。','選「已有序號？恢復 Pro」，輸入購買 Email 與序號，按「啟用 Pro」。','啟用後，原本的電腦會在下次連線時變回 Free。'],
    limit:'同一組序號同一時間只能有一台電腦使用；24 小時內只能更換一次。',
    footer:'有任何問題，直接回覆這封信，或寄到', keep:'請妥善保存這封信；任何人拿到 Email 與序號都能啟用，請不要公開分享。', terms:'服務條款', sep:'：',
    textIntro:'感謝你支持 MacMP4！\n\nPro 已在你付款的這台電腦自動啟用。請保存下面的序號：', textDownload:'下載',
  },
  en: {
    lang:'en', subject:'Your MacMP4 Pro serial number', title:'Thank you for your purchase!',
    intro:'Pro is now active on the Mac you paid from. If you switch computers or reinstall, enter the serial below on the new Mac to restore it — no need to buy again.',
    product:'Product', productValue:'MacMP4 Pro (lifetime)', email:'Purchase email', serial:'Serial', button:'Go to the MacMP4 download page',
    stepsTitle:'Switching to a new Mac',
    steps:['Install MacMP4 on the new Mac and open “Super Thanks”.','Choose “Have a serial? Restore Pro”, enter your purchase email and serial, then click “Activate Pro”.','The Mac you used before goes back to Free the next time it connects.'],
    limit:'One serial works on one Mac at a time. You can switch computers once every 24 hours.',
    footer:'Questions? Just reply to this email or write to', keep:'Please keep this email. Anyone with your email and serial can activate Pro, so don’t share it publicly.', terms:'Terms', sep:': ',
    textIntro:'Thank you for supporting MacMP4!\n\nPro is now active on the Mac you paid from. Please keep the serial below:', textDownload:'Download',
  },
};
export const mailLanguage = value => value==='en' ? 'en' : 'zh-Hant';
export function serialEmail(serial, email, language) {
  const c = COPY[mailLanguage(language)];
  const font = "-apple-system,'PingFang TC','Helvetica Neue',Arial,sans-serif";
  const text = `${c.textIntro}

${c.product}${c.sep}${c.productValue}
${c.email}${c.sep}${email}
${c.serial}${c.sep}${serial}

${c.stepsTitle}
${c.steps.map((step,i)=>`${i+1}. ${step}`).join('\n')}
${c.limit}

${c.textDownload}: ${SITE}

${c.keep}
${c.footer} ${SUPPORT}.

MacMP4 · jimmy-tools.com`;
  const step = (n, body) => `<tr><td valign="top" style="padding:0 12px 10px 0;width:22px"><div style="width:22px;height:22px;line-height:22px;border-radius:11px;background:#e8f0fe;color:#0061cc;font-size:13px;font-weight:700;text-align:center">${n}</div></td><td valign="top" style="padding:0 0 10px 0;font-size:15px;line-height:1.6;color:#1d2433">${escapeHTML(body)}</td></tr>`;
  const html = `<!doctype html><html lang="${c.lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta name="color-scheme" content="light only"><title>${escapeHTML(c.subject)}</title></head>
<body style="margin:0;padding:0;background:#f4f6f9">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6f9"><tr><td align="center" style="padding:28px 14px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:16px;border:1px solid #e3e8ef">
<tr><td align="center" style="padding:34px 32px 6px"><img src="${ICON}" width="84" height="84" alt="MacMP4" style="display:block;border-radius:20px;border:0"></td></tr>
<tr><td align="center" style="padding:14px 32px 4px;font:700 26px/1.3 ${font};color:#0061cc">${escapeHTML(c.title)}</td></tr>
<tr><td style="padding:12px 32px 4px;font:16px/1.7 ${font};color:#1d2433">${escapeHTML(c.intro)}</td></tr>
<tr><td style="padding:16px 32px 6px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef4ff;border-radius:12px"><tr><td style="padding:18px 20px;font:15px/1.9 ${font};color:#1d2433">
<b>${c.product}${c.sep}</b>${escapeHTML(c.productValue)}<br><b>${c.email}${c.sep}</b>${escapeHTML(email)}<br><b>${c.serial}${c.sep}</b><span style="display:inline-block;margin-top:4px;font:700 17px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;letter-spacing:.4px;color:#0b1f44;word-break:break-all">${escapeHTML(serial)}</span>
</td></tr></table></td></tr>
<tr><td align="center" style="padding:20px 32px 6px"><a href="${SITE}" style="display:block;background:#0061cc;color:#ffffff;text-decoration:none;font:700 16px/1 ${font};padding:16px 20px;border-radius:10px">${escapeHTML(c.button)}</a></td></tr>
<tr><td style="padding:22px 32px 4px;font:700 16px/1.4 ${font};color:#1d2433">${escapeHTML(c.stepsTitle)}</td></tr>
<tr><td style="padding:8px 32px 2px;font-family:${font}"><table role="presentation" cellpadding="0" cellspacing="0">
${c.steps.map((body,i)=>step(i+1,body)).join('\n')}
</table></td></tr>
<tr><td style="padding:4px 32px 0;font:14px/1.7 ${font};color:#5b6472">${escapeHTML(c.limit)}</td></tr>
<tr><td style="padding:22px 32px 0"><div style="border-top:1px solid #0061cc;height:1px;line-height:1px;font-size:1px">&nbsp;</div></td></tr>
<tr><td align="center" style="padding:14px 32px 30px;font:12.5px/1.7 ${font};color:#6b7482">${escapeHTML(c.footer)} <a href="mailto:${SUPPORT}" style="color:#0061cc">${SUPPORT}</a>.<br>${escapeHTML(c.keep)}<br>© 2026 JimmyLC · <a href="${SITE}terms/" style="color:#6b7482">${escapeHTML(c.terms)}</a></td></tr>
</table></td></tr></table></body></html>`;
  return {subject:c.subject, text, html};
}
