/* rds_patch_compliance_report.sh HTML filters, cards, engine table + CSV export (inlined into the report; no network). */
(function(){
var el=document.getElementById('pc-data'); if(!el) return;
var D=JSON.parse(el.textContent), R=D.rows, F0={a:'',r:'',e:'',s:'',g:'',f:'',q:''}, F=Object.assign({},F0);
var SEL={a:'f-acct',r:'f-region',e:'f-engine',s:'f-status',g:'f-global',f:'f-flag',q:'q'};
function $(id){return document.getElementById(id);}
function esc(v){return String(v==null?'':v).replace(/[&<>"']/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];});}
function uniq(a){var o={},out=[];a.forEach(function(x){if(x!=null&&x!==''&&!o[x]){o[x]=1;out.push(x);}});return out.sort();}
function opt(sel,v,t){var o=document.createElement('option');o.value=v;o.textContent=t;sel.appendChild(o);}
D.accounts.slice().sort(function(a,b){return a.account<b.account?-1:1;}).forEach(function(a){opt($('f-acct'),a.account,a.name?a.name+' ('+a.account+')':a.account+' ('+a.profile+')');});
uniq(R.map(function(x){return x.region;})).forEach(function(v){opt($('f-region'),v,v);});
uniq(R.map(function(x){return x.engine;})).forEach(function(v){opt($('f-engine'),v,v);});
['COMPLIANT','NON-COMPLIANT','UNKNOWN'].forEach(function(v){opt($('f-status'),v,v);});
if(R.some(function(x){return x.global_cluster;}))opt($('f-global'),'__all','All global databases');
uniq(R.map(function(x){return x.global_cluster;})).forEach(function(v){opt($('f-global'),v,v);});
opt($('f-global'),'__none','Not global');if(R.some(function(x){return x.global_role==='unknown';}))opt($('f-global'),'__unk','Global: unknown');
function gok(x){return !F.g||(F.g==='__all'?!!x.global_cluster:F.g==='__none'?x.global_cluster==='':F.g==='__unk'?x.global_role==='unknown':x.global_cluster===F.g);}
function aoff(x){return x.auto_minor_upgrade==='false'||x.auto_minor_upgrade==='mixed';}
var FLAG={past:function(x){return !!x.past_standard_support;},near:function(x){return !!x.nearing_end_of_support;},aoff:aoff,
  pend:function(x){return x.pending_actions_count>0;},dep:function(x){return !!x.deprecated_version;}};
function active(){return !!(F.a||F.r||F.e||F.s||F.g||F.f||F.q);}
function match(x){return (!F.a||x.account_id===F.a)&&(!F.r||x.region===F.r)&&(!F.e||x.engine===F.e)&&(!F.s||x.compliance_status===F.s)&&gok(x)
  &&(!F.f||!FLAG[F.f]||FLAG[F.f](x))
  &&(!F.q||((x.identifier||'')+' '+[].concat(x.members||[]).join(' ')+' '+(x.account_name||'')).toLowerCase().indexOf(F.q)>=0);}
function cnt(rs){var c={total:rs.length,compliant:0,nc:0,unknown:0,wp:0,pt:0,past:0,near:0,aoff:0,dep:0};
  rs.forEach(function(x){var s=x.compliance_status;if(s==='COMPLIANT')c.compliant++;else if(s==='NON-COMPLIANT')c.nc++;else c.unknown++;
    if(x.pending_actions_count>0)c.wp++;c.pt+=(+x.pending_actions_count)||0;if(x.past_standard_support)c.past++;if(x.nearing_end_of_support)c.near++;
    if(aoff(x))c.aoff++;if(x.deprecated_version)c.dep++;});
  c.pct=c.total?Math.round(c.compliant*1000/c.total)/10:null;return c;}
function pctc(p){return p==null?'muted':p>=100?'ok':p>=80?'warn':'bad';}
function bar(c){return c.pct==null?'-':c.pct+'%<div class="bar"><i class="'+pctc(c.pct)+'" style="width:'+c.pct+'%"></i></div>';}
function td(t,i,html,s,cls){var d=t.cells[i];d.innerHTML=html;d.setAttribute('data-s',s);d.className='n'+(cls?' '+cls:'');}
function setCells(t,c){td(t,3,'<b>'+c.total+'</b>',c.total);td(t,4,c.compliant,c.compliant,c.compliant>0?'ok':'');
  td(t,5,c.nc,c.nc,c.nc>0?'bad':'');td(t,6,c.unknown,c.unknown);
  td(t,7,bar(c),c.pct==null?-1:c.pct,pctc(c.pct));
  td(t,8,c.wp+(c.pt>0?'<div class="sub">'+c.pt+' action(s)</div>':''),c.wp,c.wp>0?'warn':'');td(t,9,c.past,c.past,c.past>0?'bad':'');}
var saved=[];
function save(n){saved.push([n,n.innerHTML,n.className]);}
document.querySelectorAll('.card .v, .card .s, #globals tbody tr, #regions tbody tr, #regions tfoot tr, #accounts tbody tr').forEach(save);
var cards={}; document.querySelectorAll('.card').forEach(function(c){cards[c.getAttribute('data-k')]=c;});
function setCard(k,v,sub){var c=cards[k];if(!c)return;var a=c.querySelector('.v'),b=c.querySelector('.s');if(a)a.textContent=v;if(b&&sub!=null)b.textContent=sub;}
/* risk cards: amber / red edge when above 0, grey when 0 */
var RISK={'extended-support':['past','bad'],'support-ending':['near','warn'],'auto-minor-upgrade-off':['aoff','warn'],'pending-maintenance':['wp','warn'],'version-not-returned':['dep','bad']};
function riskCls(c){Object.keys(RISK).forEach(function(k){var n=cards[k];if(!n)return;n.classList.remove('bad','warn','zero');n.classList.add(c[RISK[k][0]]>0?RISK[k][1]:'zero');});}
function cardOn(){document.querySelectorAll('.card[data-act]').forEach(function(n){var a=n.getAttribute('data-act'),p=a.split(':'),on=false;
  if(p[0]==='s')on=F.s===p[1];else if(p[0]==='f')on=F.f===p[1];else if(p[0]==='g')on=F.g===p[1];n.classList.toggle('on',on);n.setAttribute('aria-pressed',String(on));});}
/* hover pop-up: "engine count", descending, from the filtered rows (textContent only) */
function pops(rs){[['non-compliant','NON-COMPLIANT'],['unknown','UNKNOWN']].forEach(function(p){var c=cards[p[0]];if(!c)return;var pop=c.querySelector('.pop');if(!pop)return;
  var g={};rs.forEach(function(x){if(x.compliance_status===p[1]||(p[1]==='UNKNOWN'&&x.compliance_status!=='COMPLIANT'&&x.compliance_status!=='NON-COMPLIANT'))g[x.engine]=(g[x.engine]||0)+1;});
  var ks=Object.keys(g).sort(function(a,b){return g[b]-g[a]||(a<b?-1:1);});
  while(pop.firstChild)pop.removeChild(pop.firstChild);
  ks.forEach(function(k){var d=document.createElement('div'),a=document.createElement('span'),b=document.createElement('b');a.textContent=k;b.textContent=String(g[k]);d.appendChild(a);d.appendChild(b);pop.appendChild(d);});
  pop.classList.toggle('has',ks.length>0);});}
/* engine compliance table */
var OPEN={},SORT={c:'nc',d:-1},ENGBY={};D.engines.forEach(function(e){ENGBY[e.engine]=e;});
function srank(f){f=f||'';return f.indexOf('past')===0?4:f.indexOf('standard support ends')===0?3:f.indexOf('unknown')===0?2:f==='ok'?1:0;}
var SSHORT=['n/a','OK','unknown','Ending soon','Extended Support'],SCLS=['muted','ok','muted','warn','bad'];
function sfc(f){var r=srank(f);return SCLS[r];}
function engTable(rs){
  var g={};rs.forEach(function(x){var e=g[x.engine]=g[x.engine]||{rows:[],m:{}};e.rows.push(x);(e.m[String(x.major_version)]=e.m[String(x.major_version)]||[]).push(x);});
  var list=D.engines.filter(function(e){return g[e.engine];}).map(function(e){var m=e.majors.filter(function(j){return g[e.engine].m[String(j.major)];}).map(function(j){return {j:j,c:cnt(g[e.engine].m[String(j.major)])};});
    return {e:e,c:cnt(g[e.engine].rows),m:m,w:Math.max.apply(null,[0].concat(m.map(function(x){return srank(x.j.support_flag);})))};});
  var key={e:function(x){return x.e.engine;},n:function(x){return x.c.total;},p:function(x){return x.c.pct==null?-1:x.c.pct;},nc:function(x){return x.c.nc;},s:function(x){return x.w;}}[SORT.c];
  list.sort(function(a,b){var va=key(a),vb=key(b),r=typeof va==='string'?va.localeCompare(vb):va-vb;r*=SORT.d;
    if(!r&&SORT.c!=='e')r=(b.c.nc>0)-(a.c.nc>0)||a.e.engine.localeCompare(b.e.engine);return r;});
  if(SORT.c==='nc'&&SORT.d===-1)list.sort(function(a,b){return (b.c.nc>0)-(a.c.nc>0)||b.c.nc-a.c.nc||a.e.engine.localeCompare(b.e.engine);});
  var all=$('eng-all').checked,h=[];
  function tip(c){return 'Compliant '+c.compliant+' · Unknown '+c.unknown;}
  list.forEach(function(x){var e=x.e,op=!!OPEN[e.engine];
    h.push('<tr class="er" data-e="'+esc(e.engine)+'"><td><button type="button" class="car" aria-expanded="'+op+'" aria-label="Majors">▸</button><a class="en" href="#'+esc(e.anchor)+'">'+esc(e.engine)+'</a></td>'
      +'<td class="n"><span class="lnk" data-f="all">'+x.c.total+'</span></td><td class="n '+pctc(x.c.pct)+'" title="'+tip(x.c)+'">'+bar(x.c)+'</td>'
      +'<td class="n'+(x.c.nc>0?' bad':'')+'"><span class="lnk" data-f="nc">'+x.c.nc+'</span></td><td class="'+SCLS[x.w]+'">'+SSHORT[x.w]+'</td><td></td></tr>');
    if(!op)return;
    var ms=x.m.filter(function(m){return all||m.c.nc>0||m.c.unknown>0||srank(m.j.support_flag)>=3;});
    if(!ms.length)h.push('<tr class="mr" data-e="'+esc(e.engine)+'"><td colspan="6" class="muted">No issues &middot; tick Show all majors</td></tr>');
    ms.forEach(function(m){var j=m.j;h.push('<tr class="mr" data-e="'+esc(e.engine)+'"><td>'+esc(j.major)+'</td><td class="n"><span class="lnk" data-f="all">'+m.c.total+'</span></td>'
      +'<td class="n '+pctc(m.c.pct)+'" title="'+tip(m.c)+'">'+bar(m.c)+'</td><td class="n'+(m.c.nc>0?' bad':'')+'"><span class="lnk" data-f="nc">'+m.c.nc+'</span></td>'
      +'<td class="'+sfc(j.support_flag)+'">'+esc(j.support_flag||'-')+(j.standard_support_end?'<div class="sub">standard end '+esc(j.standard_support_end)+'</div>':'')+'</td>'
      +'<td class="mono">'+esc(j.latest_minor||'-')+'</td></tr>');});});
  if(!list.length)h.push('<tr><td colspan="6" class="muted">No servers match.</td></tr>');
  document.querySelector('#eng-tbl tbody').innerHTML=h.join('');
  document.querySelectorAll('#eng-tbl th[data-c]').forEach(function(th){th.classList.toggle('sd',th.getAttribute('data-c')===SORT.c&&SORT.d<0);th.classList.toggle('sa',th.getAttribute('data-c')===SORT.c&&SORT.d>0);});
}
function openSec(e,scroll){var en=ENGBY[e];var d=en&&$(en.anchor);if(!d)return;d.open=true;if(scroll)d.scrollIntoView({block:'start'});}
var wasOn=false;
function apply(){
  var on=active(), rs=on?R.filter(match):R, shown=0;
  document.querySelectorAll('table.main tbody tr[data-i]').forEach(function(t){var ok=!on||match(R[+t.getAttribute('data-i')]);t.style.display=ok?'':'none';if(ok)shown++;});
  document.querySelectorAll('details.eng-sec').forEach(function(sec){var e=sec.getAttribute('data-e'),g=rs.filter(function(x){return x.engine===e;}),c=cnt(g);
    sec.style.display=g.length?'':'none';if(on&&g.length)sec.open=true;else if(!on&&wasOn)sec.open=false;
    var es=sec.querySelector('.es');if(es)es.textContent=c.total+' · non-compliant '+c.nc+' · '+(c.pct==null?'-':c.pct+'%');});
  wasOn=on;
  document.body.classList.toggle('filtered',on);
  saved.forEach(function(x){x[0].innerHTML=x[1];x[0].className=x[2];x[0].style.display='';});
  $('f-count').textContent=on?('showing '+shown+' of '+R.length+' server(s)'):(R.length+' server(s)');
  var c=cnt(rs);riskCls(c);cardOn();pops(rs);engTable(rs);
  if(!on) return;
  var regs={};rs.forEach(function(x){regs[x.account_id+'|'+x.region]=1;});
  setCard('servers-clusters',c.total,'filtered');
  setCard('compliant',c.compliant,(c.pct==null?'-':c.pct+'%')+' of filtered');
  setCard('non-compliant',c.nc,null);setCard('unknown',c.unknown,null);
  setCard('regions',Object.keys(regs).length,'with DBs (filtered)');
  setCard('extended-support',c.past,null);
  setCard('support-ending',c.near,null);setCard('auto-minor-upgrade-off',c.aoff,null);
  var gs={};rs.forEach(function(x){if(x.global_cluster)gs[x.account_id+'|'+x.global_cluster]=1;});setCard('global-databases',Object.keys(gs).length,rs.filter(function(x){return x.global_cluster;}).length+' members (filtered)');
  setCard('pending-maintenance',c.wp,c.pt+' action(s)');setCard('version-not-returned',c.dep,null);
  document.querySelectorAll('#regions tbody tr[data-k]').forEach(function(t){var k=t.getAttribute('data-k');
    var g=rs.filter(function(x){return x.account_id+'|'+x.region===k;});if(!g.length){t.style.display='none';return;}setCells(t,cnt(g));});
  document.querySelectorAll('#globals tbody tr[data-g]').forEach(function(t){if(!rs.some(function(x){return x.global_cluster===t.getAttribute('data-g');}))t.style.display='none';});
  var ft=document.querySelector('#regions tfoot tr');if(ft)setCells(ft,c);
  document.querySelectorAll('#accounts tbody tr[data-a]').forEach(function(t){var a=t.getAttribute('data-a');
    var g=rs.filter(function(x){return x.account_id===a;});if(!g.length){t.style.display='none';return;}setCells(t,cnt(g));
    var n={};g.forEach(function(x){n[x.region]=1;});t.cells[2].innerHTML=Object.keys(n).length;});
}
function setF(o){Object.keys(o).forEach(function(k){F[k]=o[k];var n=$(SEL[k]);if(n)n.value=o[k];if(n&&n.value!==o[k]){n.value='';F[k]='';}});apply();}
function bind(k,lower){var n=$(SEL[k]);n.addEventListener(n.tagName==='INPUT'?'input':'change',function(){F[k]=lower?n.value.trim().toLowerCase():n.value;apply();});}
['a','r','e','s','g','f'].forEach(function(k){bind(k);});bind('q',true);
function reset(){Object.keys(SEL).forEach(function(k){$(SEL[k]).value='';});F=Object.assign({},F0);apply();}
$('f-reset').addEventListener('click',reset);
/* clickable cards */
document.querySelectorAll('.card[data-act]').forEach(function(n){var a=n.getAttribute('data-act'),p=a.split(':');
  var go=function(){if(a==='reset')return reset();if(p[0]==='scroll'){var t=$(p[1]);if(t)t.scrollIntoView({block:'start'});return;}
    var k=p[0],v=p[1],cur=F[k];var o={};o[k]=cur===v?'':v;setF(o);};
  n.addEventListener('click',go);
  n.addEventListener('keydown',function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault();go();}});});
/* engine table interactions */
$('eng-all').addEventListener('change',apply);
document.querySelector('#eng-tbl thead').addEventListener('click',function(e){var th=e.target.closest('th[data-c]');if(!th)return;var c=th.getAttribute('data-c');
  if(SORT.c===c)SORT.d=-SORT.d;else{SORT.c=c;SORT.d=c==='e'?1:-1;}apply();});
document.querySelector('#eng-tbl tbody').addEventListener('click',function(e){var t=e.target,tr=t.closest('tr[data-e]');if(!tr)return;var en=tr.getAttribute('data-e');
  if(t.closest('.car')){OPEN[en]=!OPEN[en];apply();return;}
  if(t.closest('a.en')){e.preventDefault();openSec(en,true);return;}
  var l=t.closest('.lnk');if(l)setF({e:en,s:l.getAttribute('data-f')==='nc'?'NON-COMPLIANT':''});});
$('x-open').addEventListener('click',function(){document.querySelectorAll('details.eng-sec').forEach(function(d){d.open=true;});});
$('x-close').addEventListener('click',function(){document.querySelectorAll('details.eng-sec').forEach(function(d){d.open=false;});});
document.querySelectorAll('a[href^="#eng-"]').forEach(function(a){a.addEventListener('click',function(){var d=$(a.getAttribute('href').slice(1));if(d&&d.tagName==='DETAILS')d.open=true;});});
/* CSV: RFC 4180 quoting, UTF-8 BOM, formula-injection guard (same as RDS_Inventory_Explorer). */
function csvCell(x){var s=x==null?'':Array.isArray(x)?x.join(' '):String(x);
  if(/^[=+\-@\t\r]/.test(s)&&!/^-?[0-9]+(\.[0-9]+)?$/.test(s)) s="'"+s;
  if(/[",\r\n]/.test(s)) s='"'+s.replace(/"/g,'""')+'"'; return s;}
function csvText(rows){return '\ufeff'+rows.map(function(r){return r.map(csvCell).join(',');}).join('\r\n')+'\r\n';}
window.__pcCsv=function(cols){cols=cols||D.cols;return csvText([cols].concat((active()?R.filter(match):R).map(function(x){return cols.map(function(c){return x[c];});})));};
var LSK='rds-pc-csv-off';
function lsGet(){try{var v=JSON.parse(localStorage.getItem(LSK)||'[]');return Array.isArray(v)?v:[];}catch(e){return [];}}
function lsSet(v){try{localStorage.setItem(LSK,JSON.stringify(v));}catch(e){}}
function download(cols){var ac=F.a||D.csv_acct;var name='rds_patch_compliance_'+(ac?ac+'_':(D.accounts.length>1?'all_accounts_':''))+D.csv_stamp+(active()?'_filtered':'')+'.csv';
  var b=new Blob([window.__pcCsv(cols)],{type:'text/csv;charset=utf-8'}),a=document.createElement('a');
  a.href=URL.createObjectURL(b);a.download=name;document.body.appendChild(a);a.click();
  setTimeout(function(){URL.revokeObjectURL(a.href);a.remove();},500);}
/* column picker: one checkbox per column; unticked names remembered, new columns ticked; standard order kept */
function picker(){var old=$('cpk');if(old)old.remove();var off=lsGet(),n=(active()?R.filter(match):R).length;
  var d=document.createElement('div');d.id='cpk';d.setAttribute('role','dialog');d.setAttribute('aria-label','CSV columns');
  d.innerHTML='<div class="box"><div class="hd"><b>CSV columns</b><button type="button" class="pri" data-a="go">Download ('+n+' rows)</button><button type="button" data-a="x">Cancel</button><button type="button" data-a="all">All</button><button type="button" data-a="none">None</button></div>'
    +D.cols.map(function(c){return '<label><input type="checkbox" value="'+esc(c)+'"'+(off.indexOf(c)<0?' checked':'')+'> '+esc(c)+'</label>';}).join('')+'</div>';
  document.body.appendChild(d);var bx=d.querySelectorAll('input');
  d.addEventListener('click',function(e){if(e.target===d){d.remove();return;}var a=e.target.getAttribute&&e.target.getAttribute('data-a');if(!a)return;
    if(a==='all'||a==='none')bx.forEach(function(b){b.checked=a==='all';});
    if(a==='go'){var on=[].filter.call(bx,function(b){return b.checked;}).map(function(b){return b.value;});if(!on.length)return;
      lsSet(D.cols.filter(function(c){return on.indexOf(c)<0;}));download(D.cols.filter(function(c){return on.indexOf(c)>=0;}));}
    if(a==='go'||a==='x')d.remove();});
  d.addEventListener('keydown',function(e){if(e.key==='Escape')d.remove();});
  d.querySelector('[data-a="go"]').focus();}
$('f-csv').addEventListener('click',picker);
apply();
})();
