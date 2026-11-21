// Headless check of the v1.7.0 two-tab HTML report (run_tests.sh runs it with puppeteer-core + Chrome).
// Usage: node browser_tabs.js <report.html> [screenshot-dir]  -> prints JSON {checks, fails, r}; exit 1 on any failure.
// Covers: tab switching (+ #pending link), nothing about maintenance left in tab 1, Aurora global members adjacent in
// both tabs (primary first), Pending tab cards / every filter / search / Reset / empty state, soonest-first order,
// red / amber dates, "N pending" -> tab 2 filtered to that server, server name -> its row in tab 1 (highlighted),
// Export CSV from both tabs (one shared layout, one row per server; tab 2 = servers with visible actions), a 390px mobile width, no JS errors, no network.
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
  const dl = fs.mkdtempSync(path.join(os.tmpdir(), 'pctabs'));
  const cdp = await g.target().createCDPSession(); await cdp.send('Page.setDownloadBehavior', {behavior: 'allow', downloadPath: dl});
  await g.goto('file://' + file, {waitUntil: 'load'});
  const D = await g.evaluate(() => JSON.parse(document.getElementById('pc-data').textContent));
  const P = D.pend, R = D.rows;
  const vis = sel => g.evaluate(s => [...document.querySelectorAll(s)].filter(t => t.style.display !== 'none' && t.offsetParent !== null).length, sel);
  const pvis = () => g.evaluate(() => [...document.querySelectorAll('#p-tbl tbody tr[data-p]')].filter(t => t.style.display !== 'none').map(t => +t.dataset.p));
  const shown = id => g.evaluate(i => { const n = document.getElementById(i); return !!n && !n.hidden && n.offsetParent !== null; }, id);
  const sel = async (id, v) => { await g.select('#' + id, v); await sleep(30); };
  const dlCsv = async btn => { fs.readdirSync(dl).forEach(f => fs.unlinkSync(path.join(dl, f))); await g.click(btn); await sleep(40); await g.click('#cpk [data-a="go"]'); let got = [];   // v1.7.0: both buttons open the column picker
    for (let i = 0; i < 50 && !(got = fs.readdirSync(dl).filter(f => f.endsWith('.csv'))).length; i++) await sleep(100);
    return got.length ? {name: got[0], rows: parseCsv(fs.readFileSync(path.join(dl, got[0]), 'utf8').replace(/^\ufeff/, ''))} : null; };

  // --- tabs
  ok(await shown('tab-comp') && !(await shown('tab-pend')), 'opens on Patch compliance');
  ok(await g.evaluate(() => document.querySelectorAll('.tabs [role=tab]').length === 2 && document.getElementById('tb-comp').getAttribute('aria-selected') === 'true'), 'two tabs, first selected');
  ok(await g.evaluate(n => +document.querySelector('#tb-pend .tn').textContent === n, P.length), 'tab 2 label counts the actions');
  // --- tab 1 carries no maintenance details
  ok(await g.evaluate(() => !document.querySelector('#tab-comp .card[data-k="pending-maintenance"]') && !document.querySelector('details.pend') && !document.querySelector('#f-flag option[value="pend"]')
    && ![...document.querySelectorAll('table.main th, #regions th, #accounts th')].some(t => /Pending|Maint/i.test(t.textContent))), 'tab 1: no Pending card / column / flag / window column / region + account pending count');
  ok(await g.evaluate(() => !/pending:/.test(document.getElementById('tab-comp').textContent)), 'tab 1: no "pending:" lines (global section)');
  // --- global members adjacent (tab 1), primary first
  const t1 = await g.evaluate(() => [...document.querySelectorAll('table.main tbody tr[data-i]')].map(t => +t.dataset.i));
  const gk = x => x.global_cluster ? x.account_id + '|' + x.global_cluster : null;
  const adjacent = idx => { const seen = {}; let last = null, okk = true; idx.forEach(i => { const k = gk(R[i]); if (k && k !== last && seen[k]) okk = false; if (k) seen[k] = 1; last = k; }); return okk; };
  ok(adjacent(t1), 'tab 1: members of one global database sit together');
  const prim = Object.keys(D.globals.reduce((o, x) => (o[x.a + '|' + x.g] = 1, o), {})).every(k => { const m = t1.filter(i => gk(R[i]) === k).map(i => R[i].global_role);
    return !m.includes('primary') || m[0] === 'primary'; });
  ok(prim, 'tab 1: primary first in each global group');
  ok(await g.evaluate(() => [...document.querySelectorAll('table.main tr.gg .gb')].every(x => /^Global: /.test(x.textContent))), 'tab 1: "Global: name" label on grouped rows');
  r.globals = D.globals.length;
  // --- N pending links
  const withP = R.map((x, i) => [x, i]).filter(([x]) => x.pending_actions_count > 0);
  ok(await g.evaluate(() => document.querySelectorAll('a.pl').length) === withP.length, 'tab 1: one "N pending" link per server with actions: ' + withP.length);
  if (shots) { await g.evaluate(() => document.querySelectorAll('details.eng-sec').forEach(d => d.open = true)); await g.screenshot({path: path.join(shots, 'tab1_compliance.png'), fullPage: false});
    await g.evaluate(() => document.querySelectorAll('details.eng-sec').forEach(d => d.open = false)); }
  // tab 1 CSV: visible rows only
  await sel('f-status', 'NON-COMPLIANT');
  const c1 = await g.evaluate(() => window.__pcCsv());
  const c1r = parseCsv(c1.replace(/^\ufeff/, ''));
  ok(c1r.length - 1 === R.filter(x => x.compliance_status === 'NON-COMPLIANT').length && JSON.stringify(c1r[0]) === JSON.stringify(D.cols), 'tab 1 CSV: filtered rows, all columns via __pcCsv');
  const UCOLS = ['account_id','account_name','profile','region','resource_type','identifier','members','engine','major_version','current_version','latest_minor_version','versions_behind','newer_versions',
    'compliance_status','auto_minor_upgrade','standard_support_end','extended_support_end','support_flag','deprecated_version','global_cluster','global_role','maint_window_ist','pending_count','next_due','next_action','pending_actions'];
  ok(JSON.stringify(D.cols.slice(0, 26)) === JSON.stringify(UCOLS), 'v1.7.0 shared CSV layout: the 26 columns in order');
  const H = D.cols, col = (row, c) => row[H.indexOf(c)];
  ok(c1r.slice(1).every(x => +col(x, 'pending_count') === R.find(y => y.identifier === col(x, 'identifier') && y.account_id === col(x, 'account_id') && y.region === col(x, 'region')).pending_actions_count), 'tab 1 CSV: pending_count = actions per server');
  await g.click('#f-reset'); await sleep(30);

  // --- switch to tab 2
  await g.click('#tb-pend'); await sleep(50);
  ok(await shown('tab-pend') && !(await shown('tab-comp')) && await g.evaluate(() => location.hash === '#pending'), 'tab 2 shown, tab 1 hidden, #pending in the address');
  if (!P.length) {
    ok(await shown('p-none'), 'empty state: No pending maintenance');
  } else {
    const all = await pvis();
    ok(all.length === P.length, 'tab 2: one row per action ' + all.length + '/' + P.length);
    ok(await g.evaluate(() => !document.querySelector('#tab-pend details')), 'tab 2: nothing to expand');
    ok(await g.evaluate(() => [...document.querySelectorAll('#p-tbl thead th')].map(t => t.textContent).join('|')) ===
      'Server|Account|Region|Engine / version|Action|Applies to|Auto-apply (IST)|Forced (IST)|Maintenance window (IST)|Description', 'tab 2 columns');
    // soonest first, globals grouped: outside global groups the dates never go down; no-date rows last among them
    const units = []; all.forEach(k => { const x = R[P[k].i], u = gk(x) || 'a' + k; if (!units.length || units[units.length - 1].u !== u) units.push({u, d: []}); units[units.length - 1].d.push(P[k].days_until); });
    const ud = units.map(u => { const n = u.d.filter(d => d !== null); return n.length ? Math.min(...n) : Infinity; });
    ok(ud.every((d, i) => i === 0 || d >= ud[i - 1]), 'tab 2: soonest first (by group): ' + JSON.stringify(ud));
    ok(new Set(units.map(u => u.u)).size === units.length, 'tab 2: each global database in one block');
    // red / amber dates
    const cls = await g.evaluate(() => [...document.querySelectorAll('#p-tbl tbody tr')].map(t => [t.cells[6].className, +t.cells[6].dataset.s]));
    ok(cls.every(([c, d]) => d === 99999 || (d <= 7 ? /bad/.test(c) : d <= 30 ? /warn/.test(c) : !/bad|warn/.test(c))), 'tab 2: red <= 7 days, amber <= 30');
    // cards
    const n7 = P.filter(x => x.due === 'over' || x.due === 'd7').length, n30 = P.filter(x => ['over', 'd7', 'd30'].includes(x.due)).length, nopt = P.filter(x => x.due === 'opt').length;
    const cv = await g.evaluate(() => [...document.querySelectorAll('#tab-pend .card .v')].map(x => +x.textContent));
    ok(JSON.stringify(cv) === JSON.stringify([P.length, n7, n30, nopt]), 'tab 2 cards: ' + cv);
    await g.click('#tab-pend .card[data-act="p:d30"]'); await sleep(30);
    ok((await pvis()).length === n30 && await g.evaluate(() => document.getElementById('p-due').value === 'd30' && document.querySelector('#tab-pend .card[data-act="p:d30"]').classList.contains('on')), 'card "Due within 30 days" filters + highlighted');
    await g.click('#tab-pend .card[data-act="p:d30"]'); await sleep(30);
    ok((await pvis()).length === P.length && !(await g.evaluate(() => !!document.querySelector('#tab-pend .card.on'))), 'second click clears it');
    // v1.7.1: Action dropdown = the 5 standard AWS types (always, with counts; 0 = disabled) + any other type in the data
    const STD = ['system-update', 'db-upgrade', 'os-upgrade', 'hardware-maintenance', 'ca-certificate-rotation'];
    const cnt = {}; P.forEach(q => { cnt[q.action] = (cnt[q.action] || 0) + 1; });
    const extra = Object.keys(cnt).filter(t => !STD.includes(t)).sort((a, b) => cnt[b] - cnt[a] || (a < b ? -1 : 1));
    const aopts = await g.$$eval('#p-action option', o => o.slice(1).map(x => [x.value, x.textContent, x.disabled]));
    ok(JSON.stringify(aopts) === JSON.stringify(STD.concat(extra).map(t => [t, t + ' (' + (cnt[t] || 0) + ')', !cnt[t]])), 'Action dropdown: 5 standard types + others, with counts, zero disabled: ' + JSON.stringify(aopts));
    r.extraTypes = extra;
    // count-by-type strip: every type once, non-zero clickable (sets Action, highlighted), zero muted
    const strip = await g.evaluate(() => [...document.querySelectorAll('#p-types .at')].map(x => [x.getAttribute('data-t') || x.textContent.replace(/ 0$/, ''), x.tagName, x.classList.contains('z')]));
    ok(strip.length === STD.length + extra.length && strip.every(([t, tag, z]) => (cnt[t] ? tag === 'BUTTON' && !z : tag === 'SPAN' && z)), 'strip: every type, non-zero clickable, zero muted: ' + JSON.stringify(strip));
    const t0 = Object.keys(cnt).sort((a, b) => cnt[a] - cnt[b])[0];
    await g.click('#p-types .at[data-t="' + t0 + '"]'); await sleep(30);
    ok((await pvis()).length === cnt[t0] && await g.evaluate(t => document.getElementById('p-action').value === t && document.querySelector('#p-types .at[data-t="' + t + '"]').classList.contains('on'), t0), 'strip click sets Action=' + t0 + ' + highlight');
    await g.click('#p-reset'); await sleep(30);
    ok((await pvis()).length === P.length && await g.evaluate(() => document.getElementById('p-action').value === '' && !document.querySelector('#p-types .at.on')), 'Reset clears the strip selection');
    await g.click('#p-types .at[data-t="' + t0 + '"]'); await sleep(20); await g.click('#p-types .at[data-t="' + t0 + '"]'); await sleep(20);
    ok((await pvis()).length === P.length, 'second strip click clears it');
    // every filter
    const f1 = async (id, v, fn, label) => { await sel(id, v); const n = (await pvis()).length, want = P.filter(fn).length; ok(n === want, `filter ${label}=${v}: ${n}/${want}`); await sel(id, ''); };
    const x0 = R[P[0].i];
    await f1('p-acct', x0.account_id, q => R[q.i].account_id === x0.account_id, 'account');
    await f1('p-region', x0.region, q => R[q.i].region === x0.region, 'region');
    await f1('p-engine', x0.engine, q => R[q.i].engine === x0.engine, 'engine');
    await f1('p-action', P[0].action, q => q.action === P[0].action, 'action');
    for (const o of ['cluster', 'member', 'instance', 'global']) await f1('p-on', o, q => q.applies.split(' ')[0] === o, 'applies');
    for (const d of ['over', 'd7', 'd30', 'later', 'opt']) await f1('p-due', d, q => ({over: ['over'], d7: ['over', 'd7'], d30: ['over', 'd7', 'd30'], later: ['later'], opt: ['opt']})[d].includes(q.due), 'due');
    if (R.some(x => x.global_cluster)) { await f1('p-gl', 'g', q => !!R[q.i].global_cluster, 'global'); await f1('p-gl', 's', q => !R[q.i].global_cluster, 'global'); }
    else ok(await g.evaluate(() => document.getElementById('p-gl').hidden), 'Global filter hidden without global databases');
    // search + combined + reset + empty state
    await g.type('#p-q', x0.identifier.toUpperCase()); await sleep(40);
    ok((await pvis()).every(k => R[P[k].i].identifier === x0.identifier || (R[P[k].i].members || '').includes(x0.identifier)) && (await pvis()).length > 0, 'search by server name');
    await sel('p-action', 'no-such-action-xyz');
    await g.$eval('#p-q', e => { e.value = 'zz-no-match-zz'; e.dispatchEvent(new Event('input')); }); await sleep(30);
    ok((await pvis()).length === 0 && await shown('p-empty'), 'no match -> "No actions match"');
    await g.click('#p-empty-reset'); await sleep(30);
    ok((await pvis()).length === P.length && await g.evaluate(() => document.getElementById('p-q').value === '' && document.getElementById('p-due').value === ''), 'Clear filters');
    await sel('p-due', 'opt'); await g.type('#p-q', 'a'); await sleep(30); await g.click('#p-reset'); await sleep(30);
    ok((await pvis()).length === P.length && await g.evaluate(() => [...document.querySelectorAll('#p-filters select')].every(s => s.value === '') && document.getElementById('p-q').value === ''), 'Reset clears every filter');
    // tab 2 CSV (v1.7.0): same layout as tab 1, one row per server that has visible actions, in tab-2 order
    await sel('p-due', 'd30');
    if (shots) await g.screenshot({path: path.join(shots, 'tab2_filtered.png')});
    const vis30 = await pvis(), srv30 = [...new Set(vis30.map(k => P[k].i))];
    const c2 = await dlCsv('#p-csv');
    ok(c2 && /^rds_pending_maintenance_.*_filtered\.csv$/.test(c2.name), 'tab 2 CSV downloaded: ' + (c2 && c2.name));
    ok(c2 && JSON.stringify(c2.rows[0]) === JSON.stringify(D.cols) && JSON.stringify(c2.rows[0]) === JSON.stringify(c1r[0]), 'tab 2 CSV: identical header to tab 1');
    ok(c2 && c2.rows.length - 1 === srv30.length && c2.rows.slice(1).map(x => col(x, 'identifier')).join() === srv30.map(i => R[i].identifier).join(), 'tab 2 CSV: one row per server with visible actions, tab-2 order (' + (c2 && c2.rows.length - 1) + '/' + srv30.length + ')');
    ok(c2 && c2.rows.slice(1).every(x => x.length === H.length && /^(\d{4}-\d{2}-\d{2} \((in \d+ days?|today|\d+ days? overdue)\))?$/.test(col(x, 'next_due'))), 'tab 2 CSV: next_due "YYYY-MM-DD (in N days)"');
    await g.click('#p-reset'); await sleep(30);
    // one server: tab 2 (via its "N pending" link) and tab 1 (search) give the same single row with compliance + every action
    const [xs1, is1] = withP.reduce((a, b) => (b[0].pending_actions_count > a[0].pending_actions_count ? b : a));
    await g.click('#tb-comp'); await sleep(30);
    await g.evaluate(i => { const a = document.querySelector('a.pl[data-i="' + i + '"]'); a.closest('details').open = true; }, is1);
    await g.click('a.pl[data-i="' + is1 + '"]'); await sleep(60);
    const c3 = await dlCsv('#p-csv');
    const acts = P.filter(q => q.i === is1);
    const one = c3 && c3.rows[1], pa = one ? col(one, 'pending_actions') : '';
    ok(c3 && c3.rows.length === 2 && col(one, 'identifier') === xs1.identifier && col(one, 'compliance_status') !== '' && col(one, 'current_version') === xs1.current_version, 'one-server tab 2 CSV: exactly one row with the compliance columns');
    ok(one && +col(one, 'pending_count') === acts.length && pa.split('; ').length === acts.length && acts.every(q => pa.includes(q.action + ' on ' + q.applies + ', ') && (!q.description || pa.includes(' - ' + q.description))),
      'one-server CSV: pending_count + every action with its full description: ' + pa.slice(0, 200));
    ok(one && acts.every(q => q.auto_ist ? pa.includes('auto-apply ' + q.auto_ist) : q.forced_ist ? pa.includes('forced ' + q.forced_ist) : q.current_apply ? pa.includes('next window ' + q.current_apply) : pa.includes('optional (no date)')), 'one-server CSV: dates as auto-apply / forced IST, next window or optional');
    const dated = acts.filter(q => q.days_until != null).sort((a, b) => a.days_until - b.days_until);
    ok(one && (dated.length ? col(one, 'next_due').startsWith(dated[0].next_date + ' (') && col(one, 'next_action') === dated[0].action + ' on ' + dated[0].applies : col(one, 'next_due') === ''), 'one-server CSV: next_due / next_action = soonest action');
    await g.click('#p-srv-x'); await sleep(30); await g.click('#tb-comp'); await sleep(30);
    await g.click('#f-reset'); await sleep(30);
    await g.$eval('#q', (e, v) => { e.value = v; e.dispatchEvent(new Event('input')); }, xs1.identifier); await sleep(40);
    const t1one = parseCsv((await g.evaluate(() => window.__pcCsv())).replace(/^\ufeff/, '')).filter(x => col(x, 'identifier') === xs1.identifier && col(x, 'account_id') === xs1.account_id && col(x, 'region') === xs1.region);
    ok(one && t1one.length === 1 && JSON.stringify(t1one[0]) === JSON.stringify(one), 'tab 1 and tab 2 give the identical row for the same server');
    await g.click('#f-reset'); await sleep(30); await g.click('#tb-pend'); await sleep(30);
    await g.click('#p-reset'); await sleep(30);
    if (shots) await g.screenshot({path: path.join(shots, 'tab2_pending.png')});
    // cross-link tab 2 -> tab 1
    const k0 = (await pvis())[0], i0 = P[k0].i;
    await g.click('#p-tbl tbody tr[data-p="' + k0 + '"] a.sl'); await sleep(80);
    ok(await shown('tab-comp') && await g.evaluate(i => { const t = document.querySelector('table.main tr[data-i="' + i + '"]'); const r = t.getBoundingClientRect();
      return t.classList.contains('hl') && t.offsetParent !== null && r.top >= 0 && r.bottom <= innerHeight; }, i0), 'server name -> tab 1, row visible + highlighted');
    // filtered-out row: tab 1 filters are cleared so the row can be shown
    await g.click('#tb-pend'); await sleep(30); await g.click('#tb-comp'); await sleep(30);
    const other = R.find(x => x.engine !== R[i0].engine); if (other) { await sel('f-engine', other.engine); }
    await g.click('#tb-pend'); await sleep(30);
    await g.click('#p-tbl tbody tr[data-p="' + k0 + '"] a.sl'); await sleep(80);
    ok(await g.evaluate(i => document.querySelector('table.main tr[data-i="' + i + '"]').offsetParent !== null, i0), 'server name -> tab 1 resets filters that hid the row');
    // cross-link tab 1 -> tab 2
    const [xs, is] = withP[withP.length - 1];
    await g.evaluate(i => { const a = document.querySelector('a.pl[data-i="' + i + '"]'); a.closest('details').open = true; }, is);
    await g.click('a.pl[data-i="' + is + '"]'); await sleep(60);
    const pv = await pvis();
    ok(await shown('tab-pend') && pv.length === xs.pending_actions_count && pv.every(k => P[k].i === is), '"N pending" -> tab 2 with only that server: ' + pv.length + '/' + xs.pending_actions_count);
    ok(await g.evaluate(id => !document.getElementById('p-srv').hidden && document.querySelector('#p-srv b').textContent === id, xs.identifier), 'server chip shown');
    await g.click('#p-srv-x'); await sleep(30);
    ok((await pvis()).length === P.length, 'chip x shows every server again');
    // global grouping in tab 2 rows
    ok(await g.evaluate(() => [...document.querySelectorAll('#p-tbl tr.gg .gb')].every(x => /^Global: /.test(x.textContent))), 'tab 2: Global label');
  }
  // --- #pending deep link
  await g.goto('file://' + file + '#pending', {waitUntil: 'load'}); await sleep(50);
  ok(await shown('tab-pend'), '#pending opens tab 2');
  // --- mobile width
  await g.setViewport({width: 390, height: 844});
  await g.click('#tb-comp'); await sleep(40);
  const mob1 = await g.evaluate(() => ({w: document.documentElement.scrollWidth, tabs: document.querySelector('.tabs').getBoundingClientRect().width}));
  await g.click('#tb-pend'); await sleep(40);
  if (shots) await g.screenshot({path: path.join(shots, 'mobile_pending.png')});
  const mob2 = await g.evaluate(() => ({w: document.documentElement.scrollWidth, ps: document.querySelector('.pscroll') ? document.querySelector('.pscroll').scrollWidth > document.querySelector('.pscroll').clientWidth : true}));
  ok(mob2.w <= 400 && mob2.ps, 'mobile: Pending tab fits, table scrolls inside its box: ' + JSON.stringify(mob2));
  ok(mob1.tabs <= 400 && mob1.w <= 400, 'mobile: tab bar + Patch compliance tab fit (tables scroll inside): ' + JSON.stringify(mob1));
  r.mobile = {tab1: mob1.w, tab2: mob2.w};
  ok(errs.length === 0, 'JS errors: ' + errs.join(' | '));
  ok(net.length === 0, 'network requests: ' + net.join(' '));
  await b.close();
  r.actions = P.length;
  console.log(JSON.stringify({checks: nchk, fails, r}));
  process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: nchk, fails: ['crash: ' + e.message]})); process.exit(1); });
