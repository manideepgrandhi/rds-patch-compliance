// Headless check of the v1.6.0 compliance exceptions in the patch HTML (run_tests.sh runs it with puppeteer-core + Chrome).
// Usage: node browser_exceptions.js <report-with-exceptions.html> <report-without.html> [screenshot-dir]
// Expects the run_tests.sh fixture: 4 applied exceptions (3 expiring soon / no longer needed), 1 expired.
const p = require('puppeteer-core');
const path = require('path'), fs = require('fs');
const fails = []; let nchk = 0; const ok = (c, m) => { nchk++; if (!c) fails.push(m); };
const sleep = ms => new Promise(x => setTimeout(x, ms));
(async () => {
  const [fx, fn, shots] = process.argv.slice(2).map((v, i) => i < 2 ? path.resolve(v) : v);
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await g.setViewport({width: 1500, height: 1000});
  await g.goto('file://' + fx, {waitUntil: 'load'});
  const st = () => g.evaluate(() => {
    const vis = n => n && n.offsetParent !== null;
    const card = k => { const c = document.querySelector('.card[data-k="' + k + '"]'); return c ? {v: c.querySelector('.v').textContent, s: c.querySelector('.s').textContent} : null; };
    const pop = [...document.querySelectorAll('.card[data-k="compliant"] .pop div')].map(d => d.textContent);
    const ft = document.querySelector('#regions tfoot tr');
    const rows = [...document.querySelectorAll('table.main tbody tr[data-i]')].filter(vis);
    return {compliant: card('compliant'), nc: card('non-compliant').v, pop, main: rows.length,
      excBadges: rows.filter(t => /COMPLIANT \(EXCEPTION\)/.test(t.cells[0].textContent)).length,
      foot: ft ? [+ft.cells[3].dataset.s, +ft.cells[4].dataset.s, +ft.cells[5].dataset.s] : null,
      acc: [...document.querySelectorAll('#accounts tbody tr')].filter(vis).map(t => +t.cells[4].dataset.s).reduce((a, x) => a + x, 0),
      eng: [...document.querySelectorAll('#eng-tbl tbody tr.er')].map(t => +t.cells[1].textContent).reduce((a, x) => a + x, 0),
      th: [...document.querySelectorAll('table.main thead')].every(h => /Exception/.test(h.textContent))}; });
  const sel = async (id, v) => { await g.select('#' + id, v); await sleep(60); };
  let s = await st();
  ok(s.th, 'every servers table has an Exception column');
  ok(s.compliant.v === '14' && /incl\. 4 exceptions/.test(s.compliant.s), 'Compliant card 14, incl. 4 exceptions: ' + JSON.stringify(s.compliant));
  ok(s.pop.join('|') === 'Compliant14 (incl. 4 exceptions)|Non-compliant5|Exceptions expiring soon or no longer needed3', 'compliant pop-up: ' + s.pop.join('|'));
  ok(s.excBadges === 4, 'four COMPLIANT (EXCEPTION) badges: ' + s.excBadges);
  ok(await g.$eval('#exc-note', n => /1 expired/.test(n.textContent) && /ghost-db \(line 8\)/.test(n.textContent)), 'notice names expired + unmatched entries');
  const opts = await g.$$eval('#f-exc option', o => o.map(x => x.value + '|' + x.textContent));
  ok(opts.join(',') === '|Exceptions: all,yes|Exceptions only,no|Non-exceptions,attn|Expiring soon or no longer needed,expired|Expired exceptions', 'quick filter options: ' + opts);
  await sel('f-exc', 'yes'); s = await st();
  ok(s.main === 4 && s.excBadges === 4, 'Exceptions only -> 4 rows: ' + s.main);
  ok(s.compliant.v === '4' && /incl\. 4 exceptions/.test(s.compliant.s), 'filtered compliant card: ' + JSON.stringify(s.compliant));
  ok(s.foot && s.foot.join() === '4,4,0', 'region footer follows filter: ' + s.foot);
  ok(s.acc === 4 && s.eng === 4, 'account + engine tables follow filter: ' + s.acc + '/' + s.eng);
  ok(s.pop.join('|') === 'Compliant4 (incl. 4 exceptions)|Non-compliant0|Exceptions expiring soon or no longer needed3', 'filtered pop-up: ' + s.pop.join('|'));
  const csv = await g.evaluate(() => window.__pcCsv());
  const lines = csv.replace(/^\ufeff/, '').trim().split('\r\n');
  ok(lines.length === 5, 'CSV export follows filter (header + 4): ' + lines.length);
  ok(/"?exception"?,"?exception_reason"?,"?exception_expires"?,"?exception_flag"?,"?actual_status"?$/.test(lines[0]) || /exception,exception_reason,exception_expires,exception_flag,actual_status$/.test(lines[0]), 'CSV header ends with exception columns: ' + lines[0].slice(-90));
  ok(lines.slice(1).every(l => /COMPLIANT \(EXCEPTION\)/.test(l) && /,yes,/.test(l)), 'CSV rows: COMPLIANT (EXCEPTION), exception=yes');
  if (shots) { fs.mkdirSync(shots, {recursive: true}); await g.screenshot({path: path.join(shots, 'patch_exceptions_only.png'), fullPage: false}); }
  await sel('f-exc', 'no'); s = await st(); ok(s.main === 15 && s.excBadges === 0, 'Non-exceptions -> 15 rows: ' + s.main);
  await sel('f-exc', 'attn'); s = await st(); ok(s.main === 3, 'Expiring soon or no longer needed -> 3 rows: ' + s.main);
  await sel('f-exc', 'expired'); s = await st(); ok(s.main === 1 && s.nc === '1', 'Expired -> 1 row, non-compliant: ' + s.main + '/' + s.nc);
  await sel('f-exc', 'yes'); await sel('f-status', 'COMPLIANT'); s = await st(); ok(s.main === 4, 'works with status filter: ' + s.main);
  await sel('f-engine', 'mysql'); s = await st(); ok(s.main === 1, 'works with engine filter (inv-mysql): ' + s.main);
  await g.click('#f-reset'); await sleep(60); s = await st();
  ok(s.main === 19 && await g.$eval('#f-exc', n => n.value === ''), 'Reset clears the exception filter: ' + s.main);
  await g.hover('.card[data-k="compliant"]'); await sleep(60);
  ok(await g.$eval('.card[data-k="compliant"] .pop', n => getComputedStyle(n).display === 'block'), 'pop-up shows on hover');
  if (shots) await g.screenshot({path: path.join(shots, 'patch_exceptions_popup.png'), clip: {x: 0, y: 0, width: 1500, height: 420}});
  // without an exceptions file: no column, no quick filter, no pop-up on Compliant
  await g.goto('file://' + fn, {waitUntil: 'load'});
  ok(!(await g.$('#f-exc')), 'no-file report: no exception filter');
  ok(await g.$$eval('table.main thead', h => h.every(x => !/Exception/.test(x.textContent))), 'no-file report: no Exception column');
  ok(!(await g.$('.card[data-k="compliant"] .pop')), 'no-file report: Compliant card has no pop-up');
  ok(errs.length === 0, 'no JS errors: ' + errs.join('; '));
  await b.close();
  console.log(JSON.stringify({checks: nchk, fails}));
  process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: nchk, fails: fails.concat(String(e))})); process.exit(1); });
