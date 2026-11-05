// Regression check (v1.4.1): a tampered --merge data file must not execute script in the HTML report.
// Usage: node xss_check.js <report.html>  -> prints JSON {checks, fails}; exit 1 if any injected payload ran.
// v1.5.0: also hovers/clicks every card (pop-ups), the engine table and the CSV picker.
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
  for (const c of await g.$$('.card')) { try { await c.hover(); await c.click(); await c.click(); } catch (e) {} }
  for (const c of await g.$$('#eng-tbl .car, #eng-tbl a.en, #eng-tbl .lnk, #eng-tbl th, #eng-all')) { try { await c.click(); } catch (e) {} }
  try { await g.click('#f-csv'); for (const c of await g.$$('#cpk input')) await c.click(); await g.click('#cpk [data-a="x"]'); } catch (e) {}
  for (const c of await g.$$('#f-gl, #f-sa, details.gdb summary')) { try { await c.click(); } catch (e) {} }
  const XQ = ['<img src=x data-xss=1 onerror="window.__xss=9">', '"><svg onload=window.__xss=8>', "'); window.__xss=7; ('", '.*[(+?\\', '&amp;<'];
  for (const v of XQ) { await g.$eval('#q', (e, v) => { e.value = v; e.dispatchEvent(new Event('input')); }, v); await new Promise(r => setTimeout(r, 30)); }
  ok(await g.evaluate(() => !document.getElementById('empty').hidden || document.querySelectorAll('table.main tbody tr[data-i]:not([style*="none"])').length > 0), 'hostile search: empty state or rows, page intact');
  const tips = await g.$$eval('.gb, details.gdb summary', x => x.map(e => (e.title || '') + e.innerHTML).join(''));
  ok(!/<img|<svg/i.test(tips), 'global badge tip / section rendered markup from data');
  await g.$eval('#q', e => { e.value = 'data-xss'; e.dispatchEvent(new Event('input')); });
  ok(await g.evaluate(() => [...document.querySelectorAll('details.gdb')].some(d => d.open) || !document.querySelector('details.gdb')), 'search for the payload opens the hostile global DB');
  const popTxt = await g.$$eval('.pop', p => p.map(x => x.innerHTML).join(''));
  ok(!/<img/i.test(popTxt), 'pop-up rendered markup from data');
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
