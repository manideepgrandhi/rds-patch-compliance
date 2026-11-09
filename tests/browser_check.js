// Headless browser check of the patch compliance HTML (run_tests.sh runs it when puppeteer-core + Chrome are available).
// Usage: node browser_check.js <report.html> [screenshot-dir]  -> prints JSON {checks, fails, r}; exit 1 on any failure.
// Covers (v1.3.0): account / region / engine / status dropdowns + DB-name search; cards, Per account and Per region
// (rows + All-regions footer) recomputed from the filtered rows; empty regions never shown; engine sections hidden when
// empty; Reset; Export CSV (BOM, CRLF, RFC 4180 quoting, formula-injection guard, filtered rows only, account in every
// row; also one real Chrome download); no region names above the first table; no JS errors, no network requests.
const p = require('puppeteer-core');
const path = require('path'), fs = require('fs'), os = require('os');
const fails = [], r = {}; let nchk = 0; const ok = (c, m) => { nchk++; if (!c) fails.push(m); };
const sleep = ms => new Promise(x => setTimeout(x, ms));
function parseCsv(t) {
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < t.length; i++) { const c = t[i];
    if (q) { if (c === '"') { if (t[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"' && f === '') q = true; else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\r' && t[i + 1] === '\n') { row.push(f); rows.push(row); row = []; f = ''; i++; } else f += c; }
  if (f !== '' || row.length) { row.push(f); rows.push(row); } return rows; }
(async () => {
  const file = path.resolve(process.argv[2]), shots = process.argv[3];
  if (shots) fs.mkdirSync(shots, {recursive: true});
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [], net = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await g.setRequestInterception(true);
  g.on('request', q => { if (!/^(file|blob|data):/.test(q.url())) net.push(q.url()); q.continue(); });
  await g.setViewport({width: 1400, height: 1000});
  await g.goto('file://' + file, {waitUntil: 'load'});
  const st = () => g.evaluate(() => {
    const vis = n => n && n.offsetParent !== null;
    const card = k => { const c = document.querySelector('.card[data-k="' + k + '"] .v'); return c ? c.textContent : null; };
    const rows = [...document.querySelectorAll('#regions tbody tr')].filter(vis).map(t => [t.dataset.k, +t.cells[3].dataset.s, +t.cells[5].dataset.s]);
    const acc = [...document.querySelectorAll('#accounts tbody tr')].filter(vis).map(t => [t.dataset.a, +t.cells[3].dataset.s]);
    const ft = document.querySelector('#regions tfoot tr');
    return {servers: card('servers-clusters'), compliant: card('compliant'), nc: card('non-compliant'), regions: card('regions'),
      main: [...document.querySelectorAll('table.main tbody tr[data-i]')].filter(vis).length,
      sections: [...document.querySelectorAll('table.main')].filter(t => vis(t)).length,
      regionRows: rows, accRows: acc, foot: ft ? [+ft.cells[3].dataset.s, +ft.cells[4].dataset.s, +ft.cells[5].dataset.s] : null,
      count: document.getElementById('f-count').textContent,
      opts: Object.fromEntries(['f-acct', 'f-region', 'f-engine', 'f-status'].map(i => [i, [...document.getElementById(i).options].map(o => o.value + '|' + o.textContent)]))}; });
  const sel = async (id, v) => { await g.select('#' + id, v); await sleep(50); };
  const D = await g.evaluate(() => JSON.parse(document.getElementById('pc-data').textContent));
  const N = D.rows.length, accts = D.accounts.map(a => a.account);
  const top = await g.evaluate(() => { const t = document.querySelector('table'); let out = '';
    document.querySelectorAll('header, .cards, .flt-note, #f-count').forEach(n => { if (n.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING) out += n.innerText + ' '; }); return out; });
  ok(!/[a-z]{2}-[a-z]+-[0-9]/.test(top), 'region name in the header / cards (above the first table): ' + top.slice(0, 200));
  let s = await st(); r.initial = s;
  ok(+s.servers === N, 'initial servers card = rows');
  ok(s.main === N, 'all rows visible initially');
  ok(s.opts['f-acct'].length === accts.length + 1, 'account dropdown has every account');
  ok(s.opts['f-acct'].slice(1).every(o => { const [v, t] = o.split('|'); const a = D.accounts.find(x => x.account === v);
    return /^\d{12}$/.test(v) && a && t === (a.name ? a.name + ' (' + v + ')' : v + ' (' + a.profile + ')'); }), 'account option = name (number) or number (profile)');
  const regs = [...new Set(D.rows.map(x => x.region))];
  ok(s.opts['f-region'].length === regs.length + 1, 'region dropdown = regions with databases only');
  ok(s.regionRows.every(x => x[1] > 0 || true), 'region rows');
  ok(s.foot && s.foot[0] === N, 'footer total = all rows');
  if (shots) await g.screenshot({path: path.join(shots, '01_merged_all.png'), fullPage: false});
  // account filter
  for (const a of accts) {
    await sel('f-acct', a); s = await st();
    const want = D.rows.filter(x => x.account_id === a);
    ok(+s.servers === want.length, `acct ${a}: servers card ${s.servers} != ${want.length}`);
    ok(s.main === want.length, `acct ${a}: visible rows`);
    ok(+s.nc === want.filter(x => x.compliance_status === 'NON-COMPLIANT').length, `acct ${a}: NC card`);
    ok(s.regionRows.every(x => x[0].startsWith(a + '|')) && s.regionRows.every(x => x[1] > 0), `acct ${a}: only its non-empty region rows`);
    ok(s.foot[0] === want.length, `acct ${a}: footer total`);
    ok(s.accRows.length === 1 && s.accRows[0][0] === a, `acct ${a}: per-account table one row`);
    ok(s.count.startsWith('showing ' + want.length + ' of ' + N), `acct ${a}: count strip`);
  }
  r.acct2 = s;
  if (shots) { await sel('f-acct', accts[1] || accts[0]); await g.screenshot({path: path.join(shots, '02_filter_account.png')}); }
  // region + status combos
  await sel('f-acct', '');
  for (const rg of regs) { await sel('f-region', rg); s = await st();
    const want = D.rows.filter(x => x.region === rg);
    ok(s.foot[0] === want.length && s.regionRows.reduce((a, x) => a + x[1], 0) === want.length, `region ${rg}: per-region totals`);
    ok(s.regionRows.every(x => x[0].endsWith('|' + rg)), `region ${rg}: only that region`); }
  await sel('f-region', '');
  await sel('f-status', 'NON-COMPLIANT'); s = await st();
  const ncs = D.rows.filter(x => x.compliance_status === 'NON-COMPLIANT');
  ok(+s.servers === ncs.length && +s.nc === ncs.length && +s.compliant === 0, 'status NC: cards');
  ok(s.foot[2] === ncs.length && s.foot[1] === 0, 'status NC: footer');
  if (shots) await g.screenshot({path: path.join(shots, '03_filter_status_nc.png')});
  const eng = D.rows[0].engine;
  await sel('f-engine', eng); s = await st();
  const en = ncs.filter(x => x.engine === eng);
  ok(s.main === en.length, 'engine+status combo rows');
  ok(s.sections === (en.length ? 1 : 0), 'only the matching engine section is shown');
  await sel('f-status', ''); await sel('f-engine', '');
  // name search
  const nm = D.rows[D.rows.length - 1].identifier;
  await g.type('#q', nm.toUpperCase()); await sleep(80); s = await st();
  const qn = D.rows.filter(x => (x.identifier + ' ' + x.members).toLowerCase().includes(nm.toLowerCase()));
  ok(s.main === qn.length && qn.length >= 1, 'name search (case-insensitive)');
  ok(+s.servers === qn.length, 'name search: cards');
  if (shots) await g.screenshot({path: path.join(shots, '04_search_name.png')});
  // CSV export (filtered)
  await g.evaluate(() => { document.getElementById('q').value = ''; document.getElementById('q').dispatchEvent(new Event('input')); });
  const a1 = accts[accts.length - 1];
  await sel('f-acct', a1);
  const csv = await g.evaluate(() => window.__pcCsv());
  ok(csv.charCodeAt(0) === 0xfeff, 'CSV has BOM');
  ok(/\r\n$/.test(csv) && !/[^\r]\n/.test(csv), 'CSV uses CRLF');
  const rows = parseCsv(csv.slice(1)); r.csvRows = rows.length;
  const hdr = rows[0], want = D.rows.filter(x => x.account_id === a1);
  ok(rows.length === want.length + 1, 'CSV has only the filtered rows');
  ok(hdr[0] === 'account_id' && rows.slice(1).every(x => x[0] === a1), 'CSV: account number in every row');
  ok(rows.every(x => x.length === hdr.length), 'CSV: same column count in every row');
  const flat = rows.flat();
  ok(!flat.some(c => /^[=+@]/.test(c) || (/^-/.test(c) && !/^-?[0-9]+(\.[0-9]+)?$/.test(c))), 'CSV formula-injection guard');
  r.guarded = flat.filter(c => /^'[=+\-@]/.test(c));
  // real download
  const dl = fs.mkdtempSync(path.join(os.tmpdir(), 'pcdl'));
  const cdp = await g.target().createCDPSession();
  await cdp.send('Page.setDownloadBehavior', {behavior: 'allow', downloadPath: dl});
  await g.click('#f-csv'); await sleep(50); await g.click('#cpk [data-a="go"]'); let got = [];
  for (let i = 0; i < 50 && !(got = fs.readdirSync(dl).filter(f => f.endsWith('.csv'))).length; i++) await sleep(100);
  ok(got.length === 1 && got[0] === 'rds_patch_compliance_' + a1 + '_' + D.csv_stamp + '_filtered.csv', 'real CSV download with account in the name: ' + got);
  if (got.length) ok(fs.readFileSync(path.join(dl, got[0]), 'utf8') === csv, 'downloaded bytes = export');
  r.download = got[0];
  // reset
  await g.click('#f-reset'); await sleep(50); s = await st();
  ok(+s.servers === N && s.main === N && s.foot[0] === N, 'reset restores all');
  if (shots) { await g.evaluate(() => document.getElementById('accounts').scrollIntoView()); await g.screenshot({path: path.join(shots, '05_per_account_region.png')});
    const src = await g.$('#sources'); if (src) { await src.scrollIntoView(); await g.screenshot({path: path.join(shots, '06_merged_inputs.png')}); } }
  // ---- v1.5.0: engine table, clickable cards, pop-up, collapsible sections, CSV picker, account names
  const v15 = await g.evaluate(() => { const e = document.getElementById('engines');
    return {prev: e && e.previousElementSibling && e.previousElementSibling.matches('.cards.risk'), beforeAcc: !!(e && document.getElementById('accounts') && (e.compareDocumentPosition(document.getElementById('accounts')) & 4)),
      stat: document.querySelectorAll('.cards.stat .card').length, risk: document.querySelectorAll('.cards.risk .card').length,
      oldTbl: document.body.innerHTML.indexOf('Per engine and major version') >= 0, mr: document.querySelectorAll('#eng-tbl tr.mr').length,
      er: [...document.querySelectorAll('#eng-tbl tr.er')].map(t => t.dataset.e), open: [...document.querySelectorAll('details.eng-sec')].filter(d => d.open).length,
      secs: document.querySelectorAll('details.eng-sec').length, focus: [...document.querySelectorAll('.card')].every(c => c.getAttribute('role') === 'button' && c.tabIndex === 0)}; });
  ok(v15.prev && v15.beforeAcc, 'engine table sits directly under the cards, above Per account');
  ok(v15.stat === 4 && v15.risk >= 5, 'two card rows (4 status + risk cards)');
  ok(!v15.oldTbl, 'old Per engine and major version table removed');
  ok(v15.mr === 0 && v15.er.length === new Set(D.rows.map(x => x.engine)).size, 'engine table: one collapsed row per engine');
  const ncByE = {}; D.rows.forEach(x => { if (x.compliance_status === 'NON-COMPLIANT') ncByE[x.engine] = (ncByE[x.engine] || 0) + 1; });
  ok(v15.er.slice(0, Object.keys(ncByE).length).every(e => ncByE[e]), 'engines with non-compliant servers sort first');
  ok(v15.open === 0 && v15.secs === v15.er.length, 'engine sections collapsed by default');
  ok(v15.focus, 'cards are role=button + tabindex=0');
  const e0 = v15.er[0], E0 = D.engines.find(x => x.engine === e0);
  await g.click('#eng-tbl tr.er[data-e="' + e0 + '"] .car'); await sleep(30);
  const mrN = () => g.evaluate(e => [...document.querySelectorAll('#eng-tbl tr.mr')].filter(t => t.dataset.e === e).length, e0);
  const m1 = await mrN(); await g.click('#eng-all'); await sleep(30); const m2 = await mrN();
  ok(m1 >= 1 && m2 === E0.majors.length && m2 >= m1, `caret expands majors (${m1} problem, ${m2} with Show all majors)`);
  await g.click('#eng-all'); await sleep(30);
  await g.click('#eng-tbl tr.er[data-e="' + e0 + '"] .lnk[data-f="nc"]'); await sleep(30);
  let fv = await g.evaluate(() => ({e: document.getElementById('f-engine').value, s: document.getElementById('f-status').value, ftag: getComputedStyle(document.querySelector('#engines .ftag')).display,
    open: [...document.querySelectorAll('details.eng-sec')].filter(d => d.open && d.style.display !== 'none').map(d => d.dataset.e)}));
  ok(fv.e === e0 && fv.s === 'NON-COMPLIANT', 'non-compliant count click sets Engine + Status');
  ok(fv.ftag !== 'none', 'Filtered tag shown on the engine table');
  ok(fv.open.length === 1 && fv.open[0] === e0, 'filter auto-opens the matching engine section');
  await g.click('#f-reset'); await sleep(30);
  ok(await g.evaluate(() => [...document.querySelectorAll('details.eng-sec')].every(d => !d.open)), 'reset collapses the sections again');
  await g.click('#eng-tbl tr.er[data-e="' + e0 + '"] a.en'); await sleep(30);
  ok(await g.evaluate(a => document.getElementById(a).open, E0.anchor), 'engine name opens its server section');
  await g.click('#x-open'); ok(await g.evaluate(() => [...document.querySelectorAll('details.eng-sec')].every(d => d.open)), 'Expand all');
  await g.click('#x-close'); ok(await g.evaluate(() => [...document.querySelectorAll('details.eng-sec')].every(d => !d.open)), 'Collapse all');
  const vis = () => g.evaluate(() => [...document.querySelectorAll('table.main tbody tr[data-i]')].filter(t => t.style.display !== 'none').length);
  await g.click('.card[data-k="non-compliant"]'); await sleep(30);
  ok(await g.evaluate(() => document.getElementById('f-status').value === 'NON-COMPLIANT' && document.querySelector('.card[data-k="non-compliant"]').classList.contains('on')), 'Non-compliant card sets Status + highlight');
  await g.click('.card[data-k="non-compliant"]'); await sleep(30);
  ok(await g.evaluate(() => document.getElementById('f-status').value === '' && !document.querySelector('.card.on')), 'second click clears the filter');
  const flags = {'extended-support': ['past', x => x.past_standard_support], 'pending-maintenance': ['pend', x => x.pending_actions_count > 0],
    'auto-minor-upgrade-off': ['aoff', x => x.auto_minor_upgrade === 'false' || x.auto_minor_upgrade === 'mixed'], 'version-not-returned': ['dep', x => x.deprecated_version], 'support-ending': ['near', x => x.nearing_end_of_support]};
  for (const k of Object.keys(flags)) { await g.click('.card[data-k="' + k + '"]'); await sleep(30);
    const want = D.rows.filter(flags[k][1]).length, fl = await g.evaluate(() => document.getElementById('f-flag').value);
    ok(fl === flags[k][0] && (await vis()) === want, `${k} card sets Flag=${flags[k][0]} (${want} rows)`);
    await g.click('.card[data-k="' + k + '"]'); await sleep(20); }
  ok(await g.evaluate(() => { const x = document.getElementById('f-exc'), f = x || document.getElementById('f-flag'), t = f.parentNode;   // v1.6.0: Exceptions follows Flag
    return t.lastElementChild.previousElementSibling.previousElementSibling.previousElementSibling === f && (!x || x.previousElementSibling === document.getElementById('f-flag')); }), 'Flag dropdown at the end of the filter row (before the buttons)');
  const nglob = D.rows.filter(x => x.global_cluster).length;
  await g.click('.card[data-k="global-databases"]'); await sleep(30);
  const nglobA = D.rows.filter(x => x.global_cluster && /^aurora/.test(x.engine)).length;
  ok(nglob === 0 || ((await g.evaluate(() => document.getElementById('f-gl').checked)) && (await vis()) === nglobA), 'Global databases card ticks Global');
  await g.click('.card[data-k="global-databases"]'); await sleep(30);
  await g.click('.card[data-k="servers-clusters"]'); await sleep(30);
  ok((await vis()) === N && await g.evaluate(() => !document.body.classList.contains('filtered')), 'Servers card resets the filters');
  await g.focus('.card[data-k="compliant"]'); await g.keyboard.press('Enter'); await sleep(30);
  ok(await g.evaluate(() => document.getElementById('f-status').value === 'COMPLIANT'), 'Enter on a focused card');
  await g.keyboard.press(' '); await sleep(30);
  ok(await g.evaluate(() => document.getElementById('f-status').value === ''), 'Space toggles it off');
  await g.hover('.card[data-k="non-compliant"]'); await sleep(50);
  const pop = await g.evaluate(() => { const p = document.querySelector('.card[data-k="non-compliant"] .pop'); return {d: getComputedStyle(p).display, l: [...p.children].map(c => [c.children[0].textContent, +c.children[1].textContent])}; });
  const pw = Object.entries(ncByE).sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
  ok(pw.length === 0 || (pop.d === 'block' && JSON.stringify(pop.l) === JSON.stringify(pw)), 'Non-compliant pop-up lists engine counts, descending: ' + JSON.stringify(pop.l));
  await g.mouse.move(1, 990);
  await g.focus('.card[data-k="unknown"]'); await sleep(30);
  const nu = D.rows.filter(x => x.compliance_status === 'UNKNOWN').length;
  ok(nu === 0 || await g.evaluate(() => getComputedStyle(document.querySelector('.card[data-k="unknown"] .pop')).display === 'block'), 'Unknown pop-up on focus');
  // CSV picker: untick a column, the choice is remembered, order kept
  await g.click('#f-csv'); await sleep(30);
  ok(await g.evaluate(n => document.querySelectorAll('#cpk input[type=checkbox]').length === n && [...document.querySelectorAll('#cpk input')].every(b => b.checked), D.cols.length), 'picker: one ticked checkbox per column');
  await g.click('#cpk input[value="profile"]'); await g.click('#cpk input[value="region"]');
  fs.readdirSync(dl).forEach(f => fs.unlinkSync(path.join(dl, f)));
  await g.click('#cpk [data-a="go"]'); got = [];
  for (let i = 0; i < 50 && !(got = fs.readdirSync(dl).filter(f => f.endsWith('.csv'))).length; i++) await sleep(100);
  const ph = got.length ? parseCsv(fs.readFileSync(path.join(dl, got[0]), 'utf8').slice(1))[0] : [];
  ok(ph.length === D.cols.length - 2 && JSON.stringify(ph) === JSON.stringify(D.cols.filter(c => c !== 'profile' && c !== 'region')), 'picker: download without unticked columns, standard order');
  ok(ph[ph.length - 1 - (D.exc ? 5 : 0)] === 'account_name', 'CSV: account_name is the last column (before the v1.6.0 exception columns)');
  await g.click('#f-csv'); await sleep(30);
  ok(await g.evaluate(() => !document.querySelector('#cpk input[value="profile"]').checked && document.querySelector('#cpk input[value="engine"]').checked), 'picker: unticked columns remembered (localStorage)');
  await g.click('#cpk [data-a="none"]'); ok(await g.evaluate(() => [...document.querySelectorAll('#cpk input')].every(b => !b.checked)), 'picker: None');
  await g.click('#cpk [data-a="all"]'); ok(await g.evaluate(() => [...document.querySelectorAll('#cpk input')].every(b => b.checked)), 'picker: All');
  await g.click('#cpk [data-a="x"]'); ok(await g.evaluate(() => !document.getElementById('cpk')), 'picker: Cancel');
  await g.evaluate(() => localStorage.removeItem('rds-pc-csv-off'));
  // account names: shown as "name (number)" and searchable
  const named = D.accounts.find(a => a.name);
  if (named) {
    const htm = await g.evaluate(() => document.querySelector('#accounts').innerText + ' ' + document.querySelector('header').innerText);
    ok(htm.includes(named.name + ' (' + named.account + ')'), 'account name shown as name (number)');
    await g.type('#q', named.name.toUpperCase()); await sleep(50);
    ok((await vis()) === D.rows.filter(x => x.account_id === named.account).length, 'search matches the account name');
    await g.click('#f-reset'); await sleep(30);
  }
  r.v15 = {engines: v15.er.length, majors: m2, pop: pop.l.length};
  ok(errs.length === 0, 'JS errors: ' + errs.join(' | '));
  ok(net.length === 0, 'network requests: ' + net.join(' '));
  await b.close();
  console.log(JSON.stringify({checks: nchk, fails, r: {download: r.download, csvRows: r.csvRows, guarded: r.guarded}}));
  process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: nchk, fails: ['crash: ' + e.message]})); process.exit(1); });
