import { createHash } from 'node:crypto';

/**
 * The admin console: one static page, no framework, no external files, no data inside it.
 * - Rendering uses textContent only, so nothing from the server is ever parsed as HTML.
 * - The session token lives in a JS variable (never in storage) and lasts 15 minutes.
 * - A strict CSP allows only this exact script and style (by hash), and same-origin requests.
 */
const CSS = String.raw`
:root{--bg:#f6f7f9;--card:#fff;--ink:#14181f;--mute:#5b6572;--line:#e2e6ec;--brand:#0b6b4f;--brand-ink:#fff;--warn:#a15c00;--bad:#b3261e;--ok:#0b6b4f}
@media(prefers-color-scheme:dark){:root{--bg:#0f1318;--card:#171c23;--ink:#e8ecf1;--mute:#98a2b0;--line:#2a323d;--brand:#34b48a;--brand-ink:#06251b;--warn:#e0a24a;--bad:#f2867f;--ok:#5fd3ab}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{display:flex;gap:12px;align-items:center;justify-content:space-between;padding:12px 16px;background:var(--card);border-bottom:1px solid var(--line);position:sticky;top:0;z-index:2;flex-wrap:wrap}
h1{font-size:17px;margin:0}h2{font-size:16px;margin:0 0 8px}main{max-width:1080px;margin:0 auto;padding:16px}
nav{display:flex;gap:6px;flex-wrap:wrap}nav button{background:none;border:1px solid transparent;color:var(--mute)}nav button.on{border-color:var(--line);color:var(--ink);background:var(--bg);font-weight:600}
button,select,input,textarea{font:inherit;color:inherit}
button{padding:8px 12px;border-radius:8px;border:1px solid var(--line);background:var(--card);cursor:pointer}
button.primary{background:var(--brand);color:var(--brand-ink);border-color:var(--brand);font-weight:600}
button.danger{color:var(--bad);border-color:var(--bad)}button:disabled{opacity:.5;cursor:default}
input,select,textarea{width:100%;padding:8px 10px;border-radius:8px;border:1px solid var(--line);background:var(--card)}
label{display:block;font-size:13px;color:var(--mute);margin:10px 0 4px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;margin-bottom:12px}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.grow{flex:1;min-width:140px}.sp{justify-content:space-between}
.mt8{margin-top:8px}.mt10{margin-top:10px}.mt12{margin-top:12px}.mt14{margin-top:14px}.mb10{margin-bottom:10px}.m0{margin:0}.inl{display:flex;gap:6px;align-items:center}.wauto{width:auto}.mute{color:var(--mute)}.small{font-size:13px}.mono{font-family:ui-monospace,Menlo,Consolas,monospace;word-break:break-all}
.badge{display:inline-block;padding:1px 8px;border-radius:99px;font-size:12px;border:1px solid var(--line)}
.ok{color:var(--ok);border-color:var(--ok)}.warn{color:var(--warn);border-color:var(--warn)}.bad{color:var(--bad);border-color:var(--bad)}
.item{cursor:pointer}.item:hover{border-color:var(--brand)}
.msg{padding:10px 12px;border-radius:8px;margin-bottom:12px;border:1px solid var(--line)}.msg.err{border-color:var(--bad);color:var(--bad)}.msg.good{border-color:var(--ok);color:var(--ok)}
.secret{border:2px dashed var(--warn);padding:10px;border-radius:8px;margin-top:8px}
.tablewrap{overflow-x:auto}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px;border-bottom:1px solid var(--line);vertical-align:top;font-size:14px}th{color:var(--mute);font-weight:600}
dl{display:grid;grid-template-columns:max-content 1fr;gap:4px 12px;margin:8px 0}dt{color:var(--mute)}dd{margin:0;word-break:break-word}
.login{max-width:380px;margin:12vh auto 0}
@media(max-width:560px){main{padding:12px}}
`;

const JS = String.raw`
(function(){
'use strict';
var S={token:null,me:null,admins:[],areas:[],rooms:[],tab:'requests',msg:null,secret:null,until:0};
var root=document.getElementById('app'),timer=null;

function el(tag,attrs){
  var n=document.createElement(tag);
  if(attrs){for(var k in attrs){var v=attrs[k];
    if(k==='class')n.className=v;
    else if(k.slice(0,2)==='on')n.addEventListener(k.slice(2),v);
    else if(v!==false&&v!=null)n.setAttribute(k,v===true?'':String(v));}}
  for(var i=2;i<arguments.length;i++){var c=arguments[i];
    if(c==null||c===false)continue;
    if(Array.isArray(c)){c.forEach(function(x){if(x!=null&&x!==false)n.appendChild(typeof x==='string'?document.createTextNode(x):x);});}
    else n.appendChild(typeof c==='string'?document.createTextNode(c):c);}
  return n;
}
function api(method,path,body){
  var h={'content-type':'application/json'};
  if(S.token)h.authorization='Bearer '+S.token;
  return fetch('/admin/v1'+path,{method:method,headers:h,body:body?JSON.stringify(body):undefined}).then(function(r){
    return r.json().catch(function(){return {};}).then(function(j){
      if(r.status===401&&S.token){logout('Your session ended. Please sign in again.');}
      if(!r.ok){var e=new Error(j.message||j.error||('error '+r.status));e.status=r.status;throw e;}
      return j;});
  });
}
function logout(m){S.token=null;S.me=null;S.secret=null;S.msg=m?{t:'err',x:m}:null;if(timer)clearInterval(timer);render();}
function say(t,x){S.msg={t:t,x:x};}
function fail(e){say('err',e.message||'Something went wrong');render();}
function fmt(ms){return new Date(ms).toLocaleString();}
function who(id){var a=S.admins.filter(function(x){return x.id===id;})[0];return a?a.email:String(id).slice(0,8);}
function areaName(id){var a=S.areas.filter(function(x){return x.id===id;})[0];return a?a.name:('area '+id);}
function roomName(id){var r=S.rooms.filter(function(x){return x.id===id;})[0];return r?(r.area+' / '+r.name):String(id).slice(0,8);}
var KIND={directory_upsert:'Add or edit police entry',directory_verify:'Verify police entry',directory_retire:'Retire police entry',data_access:'Open user data (break-glass)',admin_add:'Add admin',admin_remove:'Remove admin'};
var STATE_CLASS={pending:'warn',approved:'ok',executed:'ok',rejected:'bad',expired:'bad'};

/* ---------- login ---------- */
function loginView(){
  var email=el('input',{type:'email',autocomplete:'username',required:true}),
      pw=el('input',{type:'password',autocomplete:'current-password',required:true}),
      code=el('input',{inputmode:'numeric',autocomplete:'one-time-code',maxlength:'6',pattern:'[0-9]{6}',required:true}),
      btn=el('button',{class:'primary',type:'submit'},'Sign in');
  var f=el('form',{class:'card login',onsubmit:function(ev){ev.preventDefault();btn.disabled=true;
    api('POST','/login',{email:email.value,password:pw.value,code:code.value.trim()}).then(function(r){
      S.token=r.token;S.until=Date.now()+r.expiresIn*1000;S.msg=null;return boot();
    }).catch(function(e){btn.disabled=false;say('err',e.status===429?'Too many attempts. Try again later.':'Sign-in failed. Check your details and use a fresh code.');render();});}},
    el('h1',null,'Sentri admin'),el('p',{class:'mute small'},'Sign in with your password and the 6-digit code from your authenticator app. Sessions last 15 minutes.'),
    S.msg&&el('div',{class:'msg err'},S.msg.x),
    el('label',null,'Email'),email,el('label',null,'Password'),pw,el('label',null,'Authenticator code'),code,
    el('div',{class:'mt14'},btn));
  return f;
}
function boot(){
  return Promise.all([api('GET','/me'),api('GET','/admins'),api('GET','/areas'),api('GET','/directory')]).then(function(r){
    S.me=r[0];S.admins=r[1].admins;S.areas=r[2].areas;S.rooms=r[3].rooms;
    if(timer)clearInterval(timer);
    timer=setInterval(function(){var left=S.until-Date.now();var c=document.getElementById('clock');
      if(left<=0)logout('Your session ended. Please sign in again.');else if(c)c.textContent=Math.floor(left/60000)+':'+('0'+Math.floor(left/1000)%60).slice(-2);},1000);
    render();
  });
}
function reload(){return Promise.all([api('GET','/admins'),api('GET','/directory')]).then(function(r){S.admins=r[0].admins;S.rooms=r[1].rooms;});}

/* ---------- shell ---------- */
function shell(body){
  var tabs=[['requests','Requests'],['directory','Police directory'],['new','New request'],['team','Team']];
  return el('div',null,
    el('header',null,el('h1',null,'Sentri admin'),
      el('nav',null,tabs.map(function(t){return el('button',{class:S.tab===t[0]?'on':'',onclick:function(){S.tab=t[0];S.msg=null;S.detail=null;S.form=null;render();}},t[1]);})),
      el('div',{class:'row small mute'},S.me.email,' · session ',el('b',{id:'clock'},''),el('button',{onclick:function(){logout();}},'Sign out'))),
    el('main',null,S.msg&&el('div',{class:'msg '+(S.msg.t==='err'?'err':'good')},S.msg.x),body));
}

/* ---------- requests ---------- */
function requestsView(){
  if(S.detail)return detailView();
  var box=el('div',null,el('div',{class:'card muted'},'Loading…'));
  var sel=el('select',{onchange:function(){S.filter=sel.value;render();}},
    ['pending','approved','executed','rejected','expired',''].map(function(s){return el('option',{value:s,selected:(S.filter||'pending')===s},s||'all');}));
  api('GET','/requests'+((S.filter||'pending')?('?state='+(S.filter||'pending')):'')).then(function(r){
    box.replaceChildren.apply(box,r.requests.length?r.requests.map(function(q){
      return el('div',{class:'card item',onclick:function(){openRequest(q.id);}},
        el('div',{class:'row sp'},el('b',null,KIND[q.kind]||q.kind),el('span',{class:'badge '+(STATE_CLASS[q.state]||'')},q.state)),
        el('div',{class:'small mute'},'By '+who(q.requestedBy)+' · '+fmt(q.createdAt)),el('div',null,q.reason));
    }):[el('div',{class:'card mute'},'Nothing here.')]);
  }).catch(fail);
  return el('div',null,el('div',{class:'row mb10'},el('label',{class:'m0'},'Show'),sel),box);
}
function openRequest(id){api('GET','/requests/'+id).then(function(r){S.detail=r;render();}).catch(fail);}
function payloadList(q){
  var rows=[];Object.keys(q.payload).forEach(function(k){var v=q.payload[k];
    if(k==='adminAreaId')v=areaName(v);else if(k==='controlRoomId')v=roomName(v);else if(k==='adminId')v=who(v);
    rows.push(el('dt',null,k),el('dd',null,String(v)));});
  return el('dl',null,rows);
}
function detailView(){
  var q=S.detail.request,ap=S.detail.approvals,mine=ap.some(function(a){return a.adminId===S.me.id;}),own=q.requestedBy===S.me.id,btns=[];
  function act(path,okMsg){return function(){api('POST','/requests/'+q.id+'/'+path).then(function(r){
      if(r.provisioned)S.secret=r.provisioned;
      say('good',(r.note?r.note:okMsg));return Promise.all([reload(),api('GET','/requests/'+q.id)]).then(function(x){S.detail=x[1];render();});}).catch(fail);};}
  if(q.state==='pending'&&!own&&!mine){btns.push(el('button',{class:'primary',onclick:act('approve','Approved.')},'Approve'),el('button',{class:'danger',onclick:act('reject','Rejected.')},'Reject'));}
  if(q.state==='pending'&&own)btns.push(el('span',{class:'mute small'},'You requested this, so someone else must answer it.'));
  if(q.state==='pending'&&!own&&mine)btns.push(el('span',{class:'mute small'},'You already answered.'));
  if(q.state==='approved')btns.push(el('button',{class:'primary',onclick:act('execute','Done.')},'Carry out'));
  var extra=[];
  if(q.kind==='data_access'&&q.state==='executed'&&own)extra.push(el('button',{onclick:function(){api('GET','/requests/'+q.id+'/events').then(function(r){S.events=r.events;render();}).catch(fail);}},'Read SOS summaries (logged)'));
  if(S.events){extra.push(S.events.length?el('div',{class:'tablewrap'},el('table',null,el('tr',null,['Started','State','Trigger','Last position'].map(function(h){return el('th',null,h);})),
    S.events.map(function(e){return el('tr',null,el('td',null,fmt(e.startedAt)),el('td',null,e.state),el('td',null,e.trigger),el('td',null,e.lastGeo?(e.lastGeo.lat.toFixed(4)+', '+e.lastGeo.lon.toFixed(4)):'-'));}))):el('p',{class:'mute'},'No events in that window.'));}
  var sec=S.secret&&el('div',{class:'secret'},el('b',null,'Shown once. Give these to '+S.secret.email+' through a safe channel, then close this page.'),
    el('dl',null,el('dt',null,'Password'),el('dd',{class:'mono'},S.secret.password),el('dt',null,'Authenticator key'),el('dd',{class:'mono'},S.secret.totpSecret),el('dt',null,'Setup link'),el('dd',{class:'mono'},S.secret.otpauthUri)),
    el('button',{onclick:function(){S.secret=null;render();}},'I have saved these'));
  return el('div',null,el('button',{onclick:function(){S.detail=null;S.events=null;S.secret=null;render();}},'← Back'),
    el('div',{class:'card mt10'},
      el('div',{class:'row sp'},el('h2',null,KIND[q.kind]||q.kind),el('span',{class:'badge '+(STATE_CLASS[q.state]||'')},q.state)),
      el('div',{class:'small mute'},'Requested by '+who(q.requestedBy)+' · '+fmt(q.createdAt)+' · expires '+fmt(q.expiresAt)),
      el('p',null,el('b',null,'Reason: '),q.reason),payloadList(q),
      el('h2',{class:'mt14'},'Answers'),
      ap.length?el('ul',null,ap.map(function(a){return el('li',null,who(a.adminId)+' '+(a.decision==='approve'?'approved':'rejected')+' · '+fmt(a.at));})):el('p',{class:'mute small'},'No answers yet.'),
      el('div',{class:'row mt10'},btns),extra,sec));
}

/* ---------- forms ---------- */
function field(label,input){return el('div',null,el('label',null,label),input);}
function reasonField(){return el('textarea',{rows:'2',placeholder:'Why is this needed? (at least 10 characters)'});}
function submitRequest(kind,payload,reason){
  return api('POST','/requests',{kind:kind,payload:payload,reason:reason}).then(function(r){
    S.form=null;S.tab='requests';S.filter='pending';say('good','Request sent. Another admin must approve it.');return reload().then(function(){openRequest(r.request.id);});}).catch(function(e){fail(e);});
}
function directoryForm(room){
  var area=el('select',null,S.areas.map(function(a){return el('option',{value:a.id,selected:room&&room.areaId===a.id},a.name);})),
      name=el('input',{value:room?room.name:'',placeholder:'e.g. Lagos State Police Command, control room'}),
      kind=el('select',null,[['state_command','State command'],['area_command','Area command'],['control_room','Control room'],['emergency_line','National emergency line']].map(function(k){return el('option',{value:k[0],selected:room&&room.kind===k[0]},k[1]);})),
      ph=el('input',{value:room&&room.officialPhone||'',inputmode:'tel',placeholder:'Official voice line'}),
      sms=el('input',{value:room&&room.officialSms||'',inputmode:'tel',placeholder:'Official SMS number (optional)'}),
      src=el('input',{value:room&&room.source||'',placeholder:'Where you confirmed it: letter ref, official page, call log'}),
      why=reasonField();
  return el('div',{class:'card'},el('h2',null,room?'Edit police entry':'Add police entry'),
    el('p',{class:'small mute'},'Official lines only. Saving makes the entry unverified. It receives no alerts until a second admin approves a separate verification.'),
    field('State',area),field('Name',name),field('Type',kind),field('Phone',ph),field('SMS number',sms),field('Source (required)',src),field('Reason',why),
    el('div',{class:'row mt12'},el('button',{class:'primary',onclick:function(){
      var p={adminAreaId:Number(area.value),name:name.value,kind:kind.value,source:src.value};
      if(room)p.controlRoomId=room.id;if(ph.value.trim())p.officialPhone=ph.value;if(sms.value.trim())p.officialSms=sms.value;
      submitRequest('directory_upsert',p,why.value);}},'Send for approval'),el('button',{onclick:function(){S.form=null;render();}},'Cancel')));
}
function simpleForm(title,intro,fields,kind,build,btn){
  var why=reasonField();
  return el('div',{class:'card'},el('h2',null,title),intro&&el('p',{class:'small mute'},intro),fields.map(function(f){return field(f[0],f[1]);}),field('Reason',why),
    el('div',{class:'row mt12'},el('button',{class:'primary',onclick:function(){submitRequest(kind,build(),why.value);}},btn||'Send for approval'),el('button',{onclick:function(){S.form=null;render();}},'Cancel')));
}
function verifyForm(room){
  var src=el('input',{placeholder:'How you checked it, e.g. called the line on 2026-10-15 and confirmed with the duty officer'});
  return simpleForm('Verify: '+room.area+' / '+room.name,'Only verify after confirming the number with the police command itself. Verified entries start receiving real alerts.',
    [['Number to verify',el('input',{value:room.officialPhone||room.officialSms||'',disabled:true})],['How it was confirmed (required)',src]],'directory_verify',
    function(){return {controlRoomId:room.id,source:src.value};},'Send for approval');
}
function retireForm(room){
  return simpleForm('Retire: '+room.area+' / '+room.name,'Retired entries stop receiving alerts. They stay in the record.',[],'directory_retire',function(){return {controlRoomId:room.id};});
}

/* ---------- directory ---------- */
function directoryView(){
  if(S.form)return S.form();
  var q=el('input',{placeholder:'Search name or number',value:S.q||'',oninput:function(){S.q=q.value;drawRows();}}),
      st=el('select',{onchange:function(){S.dstate=st.value;drawRows();}},[el('option',{value:''},'All states')].concat(S.areas.map(function(a){return el('option',{value:a.name,selected:S.dstate===a.name},a.name);}))),
      un=el('input',{type:'checkbox',class:'wauto',checked:!!S.unv,onchange:function(){S.unv=un.checked;drawRows();}}),
      body=el('tbody',null),count=el('span',{class:'mute small'});
  function drawRows(){
    var t=(q.value||'').toLowerCase();
    var rows=S.rooms.filter(function(r){return (!S.dstate||r.area===S.dstate)&&(!S.unv||!r.verified)&&(!t||(r.name+' '+(r.officialPhone||'')+' '+(r.officialSms||'')).toLowerCase().indexOf(t)>=0);});
    count.textContent=rows.length+' of '+S.rooms.length+' entries';
    body.replaceChildren.apply(body,rows.length?rows.map(function(r){
      var badge=!r.active?el('span',{class:'badge bad'},'Retired'):r.verified?el('span',{class:'badge ok'},'Verified'):el('span',{class:'badge warn'},'Unverified');
      return el('tr',null,el('td',null,r.area),el('td',null,el('b',null,r.name),el('div',{class:'small mute'},r.kind.replace('_',' '))),
        el('td',{class:'mono'},[r.officialPhone,r.officialSms&&('SMS '+r.officialSms)].filter(Boolean).join(' · ')||'-'),el('td',null,badge,r.source&&el('div',{class:'small mute'},r.source)),
        el('td',null,el('div',{class:'row'},
          el('button',{onclick:function(){S.form=function(){return directoryForm(r);};render();}},'Edit'),
          r.active&&!r.verified&&el('button',{onclick:function(){S.form=function(){return verifyForm(r);};render();}},'Verify'),
          r.active&&el('button',{class:'danger',onclick:function(){S.form=function(){return retireForm(r);};render();}},'Retire'))));
    }):[el('tr',null,el('td',{colspan:'5',class:'mute'},S.rooms.length?'No entries match.':'The directory is empty. Add the first entry with the button above.'))]);
  }
  setTimeout(drawRows,0);
  return el('div',null,el('div',{class:'row sp mb10'},el('div',{class:'row grow'},el('div',{class:'grow'},q),el('div',null,st),el('label',{class:'m0 inl'},un,'Unverified only')),
    el('button',{class:'primary',onclick:function(){S.form=function(){return directoryForm(null);};render();}},'+ Add entry')),count,
    el('div',{class:'card tablewrap mt8'},el('table',null,el('thead',null,el('tr',null,['State','Entry','Number','Status',''].map(function(h){return el('th',null,h);}))),body)));
}

/* ---------- new request & team ---------- */
function newView(){
  if(S.form)return S.form();
  function card(title,text,fn){return el('div',{class:'card item',onclick:function(){S.form=fn;render();}},el('b',null,title),el('div',{class:'small mute'},text));}
  return el('div',null,
    card('Add a police entry','Create a new directory entry. It starts unverified.',function(){return directoryForm(null);}),
    card('Open user data (break-glass)','Needs two other admins. Read-only summaries for one hour.',function(){
      var u=el('input',{placeholder:'User id (uuid)'}),h=el('input',{type:'number',value:'24',min:'1',max:'720'});
      return simpleForm('Open user data','Shows SOS summaries only: no phone numbers and no contacts. Every read is logged.',[['User id',u],['Look back (hours)',h]],'data_access',function(){return {userId:u.value.trim(),sinceHours:Number(h.value)};});}),
    card('Add an admin','Creates an account. Credentials are shown once after approval.',function(){
      var e=el('input',{type:'email',placeholder:'name@organisation.ng'});
      return simpleForm('Add an admin',null,[['Email',e]],'admin_add',function(){return {email:e.value.trim()};});}),
    card('Remove an admin','At least two active admins must always remain.',function(){
      var s=el('select',null,S.admins.filter(function(a){return a.active&&a.id!==S.me.id;}).map(function(a){return el('option',{value:a.id},a.email);}));
      return simpleForm('Remove an admin',null,[['Admin',s]],'admin_remove',function(){return {adminId:s.value};});}));
}
function teamView(){
  return el('div',{class:'card'},el('h2',null,'Admins'),el('ul',null,S.admins.map(function(a){return el('li',null,a.email+(a.id===S.me.id?' (you)':'')+(a.active?'':' · disabled'));})),
    el('p',{class:'small mute'},'No one can approve their own request. Sensitive actions always need a second person, and user-data access needs two.'));
}

function render(){
  var body;
  if(!S.token)body=loginView();
  else body=shell(S.tab==='requests'?requestsView():S.tab==='directory'?directoryView():S.tab==='new'?newView():teamView());
  root.replaceChildren(body);
  if(S.token){var c=document.getElementById('clock'),left=S.until-Date.now();if(c)c.textContent=Math.max(0,Math.floor(left/60000))+':'+('0'+Math.max(0,Math.floor(left/1000)%60)).slice(-2);}
}
render();
})();
`;

const sri = (s: string) => `'sha256-${createHash('sha256').update(s).digest('base64')}'`;

export const ADMIN_CSP = [
  "default-src 'none'",
  `script-src ${sri(JS)}`,
  `style-src ${sri(CSS)}`,
  "connect-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join('; ');

export const ADMIN_HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>Sentri admin</title>
<style>${CSS}</style></head><body><div id="app"></div><script>${JS}</script></body></html>`;
