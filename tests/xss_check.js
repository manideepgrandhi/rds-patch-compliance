// Regression check (v1.4.1): a tampered --merge data file must not execute script in the HTML report.
// Usage: node xss_check.js <report.html>  -> prints JSON {checks, fails}; exit 1 if any injected payload ran.
// Payloads set window.__xss; the check also exercises every <select> option and button, then looks for injected elements.
const p = require('puppeteer-core');
const path = require('path');
(async () => {
  const fails = []; let checks = 0; const ok = (c, m) => { checks++; if (!c) fails.push(m); };
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const dialogs = [];
  g.on('dialog', d => { dialogs.push(d.message()); d.dismiss(); });
  await g.goto('file://' + path.resolve(process.argv[2]), {waitUntil: 'load'});
  await new Promise(r => setTimeout(r, 300));
  const sels = await g.$$eval('select', s => s.map(x => [x.id, [...x.options].map(o => o.value)]));
  for (const [id, vals] of sels) { if (!id) continue; for (const v of vals) { await g.select('#' + id, v); } await g.select('#' + id, vals[0]); }
  const btns = await g.$$('button:not(#f-csv)'); for (const x of btns) { try { await x.click(); } catch (e) {} }
  await new Promise(r => setTimeout(r, 300));
  const st = await g.evaluate(() => ({xss: window.__xss || null, injected: document.querySelectorAll('[data-xss],img[src="x"],svg[onload]').length,
    text: document.body.textContent.includes('data-xss')}));
  ok(st.xss === null, 'payload executed (window.__xss=' + st.xss + ')');
  ok(st.injected === 0, st.injected + ' injected element(s) in the DOM');
  ok(dialogs.length === 0, 'dialog opened: ' + dialogs.join('|'));
  ok(st.text, 'payload text not shown as text (expected it escaped and visible)');
  await b.close();
  console.log(JSON.stringify({checks, fails})); process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: 0, fails: [String(e)]})); process.exit(1); });
