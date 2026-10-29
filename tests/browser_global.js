// v1.4.0 headless check of the "Global cluster" dropdown. Usage: node browser_global.js <report.html> [screenshot-dir]
const p = require('puppeteer-core'), path = require('path'), fs = require('fs');
const fails = []; let n = 0; const ok = (c, m) => { n++; if (!c) fails.push(m); };
(async () => {
  const file = path.resolve(process.argv[2]), shots = process.argv[3];
  if (shots) fs.mkdirSync(shots, {recursive: true});
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [];
  g.on('pageerror', e => errs.push(e.message));
  await g.setViewport({width: 1400, height: 1000});
  await g.goto('file://' + file, {waitUntil: 'load'});
  const st = () => g.evaluate(() => {
    const vis = x => x && x.offsetParent !== null;
    const rows = [...document.querySelectorAll('table.main tbody tr')].filter(vis);
    return { n: rows.length, ids: rows.map(r => r.getAttribute('data-id') || r.cells[0].textContent.trim()),
      opts: [...document.querySelectorAll('#f-global option')].map(o => o.value),
      gvis: [...document.querySelectorAll('#globals tbody tr[data-g]')].filter(vis).map(t => t.getAttribute('data-g')),
      card: (document.querySelector('.card[data-k="global-databases"] .v') || {}).textContent,
      bad: /arn:aws|Copy|modify-db|Owner/.test(document.querySelector('table.main').innerText) };
  });
  const all = await st();
  ok(all.opts.includes('orders-global') && all.opts.includes('shop-global') && all.opts.includes('__none'), 'options ' + all.opts);
  ok(!all.bad, 'table shows ARN / command / tag'); ok(all.card === '2', 'card ' + all.card);
  await g.select('#f-global', 'orders-global'); const o = await st();
  ok(o.n === 2, 'orders-global rows ' + o.n); ok(o.card === '1', 'filtered card ' + o.card);
  ok([...new Set(o.gvis)].join() === 'orders-global', 'globals table ' + o.gvis);
  if (shots) await g.screenshot({path: path.join(shots, 'global_filter_orders.png'), fullPage: true});
  await g.select('#f-global', '__none'); const nn = await st();
  ok(nn.n === all.n - 4, 'not global rows ' + nn.n + ' of ' + all.n);
  await g.select('#f-global', ''); const back = await st(); ok(back.n === all.n, 'reset');
  if (shots) await g.screenshot({path: path.join(shots, 'global_report_full.png'), fullPage: true});
  ok(errs.length === 0, 'js errors ' + errs);
  await b.close();
  console.log(JSON.stringify({checks: n, fails})); process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({fails: [String(e)]})); process.exit(1); });
