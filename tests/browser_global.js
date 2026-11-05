// v1.5.1 headless check: Global / Standalone checkboxes, global section, mismatch badge, search.
// Usage: node browser_global.js <report.html> [screenshot-dir] [shot-prefix]
const p = require('puppeteer-core'), path = require('path'), fs = require('fs');
const fails = []; let n = 0; const ok = (c, m) => { n++; if (!c) fails.push(m); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  const file = path.resolve(process.argv[2]), shots = process.argv[3], pre = process.argv[4] || '';
  if (shots) fs.mkdirSync(shots, {recursive: true});
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('dialog', d => { errs.push('dialog ' + d.message()); d.dismiss(); });
  await g.setViewport({width: 1280, height: 900});
  await g.goto('file://' + file, {waitUntil: 'load'});
  const D = await g.evaluate(() => JSON.parse(document.getElementById('pc-data').textContent));
  const aur = x => /^aurora/.test(x.engine), R = D.rows;
  const st = () => g.evaluate(() => {
    const vis = x => x && x.style.display !== 'none' && !(x.closest('[style*="display: none"]'));
    const rows = [...document.querySelectorAll('table.main tbody tr[data-i]')].filter(t => t.style.display !== 'none');
    const gd = [...document.querySelectorAll('details.gdb')];
    return { n: rows.length, idx: rows.map(t => +t.dataset.i).sort((a, b) => a - b),
      box: !document.getElementById('g-box').hidden, gl: document.getElementById('f-gl').checked, sa: document.getElementById('f-sa').checked,
      gvis: gd.filter(d => d.style.display !== 'none').map(d => d.dataset.g), gopen: gd.filter(d => d.open).map(d => d.dataset.g),
      gsec: (document.getElementById('globals') || {style: {}}).style.display !== 'none',
      card: document.querySelector('.card[data-k="global-databases"] .v').textContent, csub: document.querySelector('.card[data-k="global-databases"] .s').textContent,
      con: document.querySelector('.card[data-k="global-databases"]').classList.contains('on'),
      secOpen: [...document.querySelectorAll('details.eng-sec')].filter(d => d.open && d.style.display !== 'none').map(d => d.dataset.e),
      secVis: [...document.querySelectorAll('details.eng-sec')].filter(d => d.style.display !== 'none').map(d => d.dataset.e),
      eng: [...document.querySelectorAll('#eng-tbl tr.er')].map(t => t.dataset.e), cnt: document.getElementById('f-count').textContent,
      empty: !document.getElementById('empty').hidden, servers: document.querySelector('.card[data-k="servers-clusters"] .v').textContent,
      acc: [...document.querySelectorAll('#accounts tbody tr[data-a]')].filter(t => t.style.display !== 'none').length,
      reg: [...document.querySelectorAll('#regions tbody tr[data-k]')].filter(t => t.style.display !== 'none').length };
  });
  const want = f => R.map((x, i) => f(x) ? i : -1).filter(i => i >= 0);
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const A = await st();
  ok(!(await g.$('#f-global')), 'old Global cluster dropdown removed');
  ok(A.box === R.some(aur), 'checkboxes visible with All engines');
  ok(A.gopen.length === 0 && A.gvis.length === D.globals.length, 'global section: one collapsed line per global DB');
  const mm = await g.evaluate(() => [...document.querySelectorAll('details.gdb[data-mm]')].map(d => d.dataset.g));
  ok(mm.length === 0 || A.csub.includes(mm.length + ' mismatched'), 'card sub shows N mismatched: ' + A.csub);
  const amber = await g.evaluate(() => [...document.querySelectorAll('.gb.mm')].map(x => x.title));
  ok(mm.length === 0 || (amber.length > 0 && amber.every(t => /differ/.test(t))), 'amber badge with tip on mismatched global members');
  // checkboxes
  await g.click('#f-gl'); await sleep(30); let s = await st();
  ok(same(s.idx, want(x => aur(x) && !!x.global_cluster)), 'Global = Aurora global members only');
  ok(s.con, 'Global ticked highlights the Global databases card');
  ok(s.secVis.every(e => /^aurora/.test(e)) && s.eng.every(e => /^aurora/.test(e)), 'Global hides Oracle / SQL Server sections and engine rows');
  await g.click('#f-sa'); await sleep(30); s = await st(); ok(s.n === R.length, 'both ticked = no restriction');
  await g.click('#f-gl'); await sleep(30); s = await st();
  ok(same(s.idx, want(x => aur(x) && !x.global_cluster && x.global_role !== 'unknown')), 'Standalone = Aurora not in a global DB');
  ok(s.gvis.length === 0 && !s.gsec, 'Standalone hides the global section');
  await g.click('#f-sa'); await sleep(30);
  const nonA = R.find(x => !aur(x)), anA = R.find(aur);
  if (nonA) { await g.click('#f-gl'); await g.select('#f-engine', nonA.engine); await sleep(30); s = await st();
    ok(!s.box && !s.gl && s.n === R.filter(x => x.engine === nonA.engine).length, 'non-Aurora engine hides and clears the checkboxes'); }
  if (anA) { await g.select('#f-engine', anA.engine); await sleep(30); s = await st(); ok(s.box, 'aurora engine shows the checkboxes');
    await g.click('#f-gl'); await sleep(30); s = await st();
    ok(same(s.idx, want(x => x.engine === anA.engine && !!x.global_cluster)), 'aurora engine + Global');
    if (shots) { await g.evaluate(() => window.scrollTo(0, 0)); await g.screenshot({path: path.join(shots, pre + 'filters.png'), clip: {x: 0, y: 0, width: 1280, height: 560}}); } }
  await g.click('#f-reset'); await sleep(30); s = await st(); ok(s.n === R.length && !s.gl && !s.sa, 'Reset clears the checkboxes');
  // card
  if (nonA) await g.select('#f-engine', nonA.engine);
  await g.click('.card[data-k="global-databases"]'); await sleep(50); s = await st();
  ok(s.gl && !s.sa && same(s.idx, want(x => aur(x) && !!x.global_cluster)), 'card ticks Global (and drops a non-Aurora engine)');
  ok(await g.evaluate(() => { const r = document.getElementById('globals').getBoundingClientRect(); return r.top >= -2 && r.top < 200; }), 'card scrolls to the global section');
  await g.click('.card[data-k="global-databases"]'); await sleep(30); s = await st(); ok(!s.gl && s.n === R.length, 'second card click clears Global');
  if (D.globals.length) { const g0 = mm[0] || D.globals[0].g; await g.click('details.gdb[data-g="' + g0 + '"] summary'); await sleep(30);
    const mem = await g.evaluate(k => [...document.querySelectorAll('details.gdb[data-g="' + k + '"] tbody tr')].map(t => t.cells.length), g0);
    ok(mem.length >= 1 && mem.every(c => c === 5), 'expanded global DB lists members (role, region, cluster, version, status)');
    if (shots) { await g.evaluate(() => document.getElementById('globals').scrollIntoView()); await sleep(30); await g.screenshot({path: path.join(shots, pre + 'globals.png')}); }
    await g.click('details.gdb[data-g="' + g0 + '"] summary'); }
  // search
  const q = async v => { await g.$eval('#q', (e, v) => { e.value = v; e.dispatchEvent(new Event('input')); }, v); await sleep(40); return st(); };
  const hay = x => [x.identifier, [].concat(x.members || []).join(' '), x.global_cluster, x.account_id, x.account_name, x.engine, x.current_version].map(v => v == null ? '' : String(v)).join('\n').toLowerCase();
  const sq = v => want(x => hay(x).includes(v.trim().toLowerCase()));
  const terms = [['identifier', R[0].identifier], ['partial upper-case', R[0].identifier.slice(1, 5).toUpperCase()], ['account number', R[0].account_id],
    ['engine', (R.find(x => !aur(x)) || R[0]).engine], ['version', (R.find(x => x.current_version) || R[0]).current_version], ['trimmed', '  ' + R[0].identifier + '  ']];
  const mem = R.find(x => x.members && String(x.members).trim()); if (mem) terms.push(['cluster member', String(mem.members).split(/[ ,(]/)[0]]);
  if (D.globals.length) terms.push(['global DB name', D.globals[0].g]);
  const named = R.find(x => x.account_name); if (named) terms.push(['account name', named.account_name.toUpperCase()]);
  for (const [k, v] of terms) { s = await q(v); ok(s.idx.length > 0 && same(s.idx, sq(v)), `search ${k} "${v}": ${s.idx.length} vs ${sq(v).length}`); }
  if (D.globals.length) { s = await q(D.globals[0].g); ok(same(s.gopen, [D.globals[0].g]) && same(s.gvis, [D.globals[0].g]), 'search auto-opens the matching global DB');
    ok(s.secVis.length > 0 && same(s.secOpen, s.secVis), 'search auto-opens the matching engine sections');
    ok(+s.card === 1 && +s.servers === s.n && s.cnt.includes('showing ' + s.n + ' of'), 'search updates cards and count');
    ok(s.acc >= 1 && s.reg >= 1 && s.eng.length === new Set(sq(D.globals[0].g).map(i => R[i].engine)).size, 'search updates engine table, per account and per region');
    const csv = await g.evaluate(() => window.__pcCsv().trim().split('\r\n').length - 1); ok(csv === s.n, 'CSV export honours the search: ' + csv);
    if (shots) { await g.evaluate(() => window.scrollTo(0, 0)); await g.screenshot({path: path.join(shots, pre + 'search.png'), fullPage: true}); } }
  // combined with checkbox / status / flag / card
  const v0 = anA ? anA.engine.slice(0, 6) : R[0].engine;
  await q(v0); await g.click('#f-sa'); await sleep(30); s = await st();
  ok(same(s.idx, want(x => hay(x).includes(v0) && aur(x) && !x.global_cluster && x.global_role !== 'unknown')), 'search + Standalone');
  await g.click('#f-sa'); await g.select('#f-status', 'NON-COMPLIANT'); await sleep(30); s = await st();
  ok(same(s.idx, want(x => hay(x).includes(v0) && x.compliance_status === 'NON-COMPLIANT')), 'search + Status');
  await g.select('#f-status', ''); await g.click('.card[data-k="auto-minor-upgrade-off"]'); await sleep(30); s = await st();
  ok(same(s.idx, want(x => hay(x).includes(v0) && (x.auto_minor_upgrade === 'false' || x.auto_minor_upgrade === 'mixed'))), 'search + Flag card');
  await g.click('.card[data-k="auto-minor-upgrade-off"]'); await sleep(30);
  // clearing restores
  s = await q(''); ok(s.n === R.length && s.gopen.length === 0 && s.secOpen.length === 0 && s.card === String(D.globals.length) && !s.empty, 'clearing the search restores everything');
  // literal special characters, no match, no injection
  for (const v of ['.', '.*', '(', '[', '+', '?', '\\', '"', "'", '<', '&', '<img src=x onerror=window.__xss=1>', '$(id)', '%', '^', '|']) {
    s = await q(v); ok(same(s.idx, sq(v)), 'literal search ' + JSON.stringify(v)); ok(s.empty === (s.n === 0), 'empty state for ' + JSON.stringify(v)); }
  s = await q('zz-no-such-db'); ok(s.n === 0 && s.empty && s.eng.length === 0 && s.gvis.length === 0 && s.secVis.length === 0, 'no match: empty state, sections hidden');
  await g.click('#empty-reset'); await sleep(30); s = await st(); ok(s.n === R.length && !s.empty && (await g.$eval('#q', e => e.value)) === '', 'Clear filters button');
  ok(await g.evaluate(() => !window.__xss && !document.querySelector('img[src="x"]')), 'hostile search did not inject');
  ok(errs.length === 0, 'js errors ' + errs);
  await b.close();
  console.log(JSON.stringify({checks: n, fails})); process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: n, fails: [String(e)]})); process.exit(1); });
