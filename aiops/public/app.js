const $=id=>document.getElementById(id);
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const time=s=>new Date(s).toLocaleString('en-GB',{timeZone:'Europe/London',day:'2-digit',month:'short',hour:'2-digit',minute:'2-digit',second:'2-digit'});
const label=s=>s.replaceAll('_',' ');
const good=['healthy','recovered','source_resolved'];
const active=['queued','investigating','acting','verifying'];
const badge=s=>`<span class="badge ${good.includes(s)?'good':active.includes(s)?'':'warn'}">${escape(label(s))}</span>`;
let state,selected=new URLSearchParams(location.search).get('incident'),refreshing=false,editing=false,fleetUnavailable=false;
async function api(path,body) {
  const r=await fetch(path,{method:body===undefined?'GET':'POST',
    headers:body===undefined?{}:{'Content-Type':'application/json','X-AIOps-Control':'1'},
    body:body===undefined?undefined:JSON.stringify(body)});
  const data=await r.json();
  if(r.status===401){$('login').hidden=false;$('console').hidden=true;$('logout').hidden=true;}
  if(!r.ok)throw new Error(data.error||'Request failed');
  return data;
}
function error(e){$('error').textContent=e.message;$('error').hidden=false;}
function clearError(){$('error').hidden=true;}
async function refresh() {
  if(refreshing)return;refreshing=true;
  try {
    state=await api('/api/state');fleetUnavailable=false;$('login').hidden=true;$('console').hidden=false;$('logout').hidden=false;clearError();
    $('host-label').textContent=state.host.toUpperCase();
    $('summary').textContent=state.busy?'An incident is being investigated.':state.paused?'Recovery is paused. Alerts continue to be collected.':'Watching for incidents. Recovery follows your approved procedures.';
    $('pause').textContent=state.paused?'Resume recovery':'Pause recovery';
    $('pause').className=state.paused?'primary':'';
    $('status-strip').innerHTML=`<span><i class="dot ${state.paused?'warn':''}"></i><strong>${state.paused?'Paused':state.automatic?'Automatic recovery':'Diagnosis only'}</strong></span><span>Cloud limit <strong>$${escape(state.budgetUsd.toFixed(2))}</strong> / incident</span>`+
      state.peers.map(p=>`<span><i class="dot ${p.available?'':'warn'}"></i><a href="${escape(p.url)}">${escape(p.host)}</a> ${p.available?'connected':'unreachable'}</span>`).join('');
    if(!editing){$('automatic').checked=state.automatic;$('budget').value=state.budgetUsd;}
    $('connections').innerHTML=state.providers.map(p=>`<div class="connection">${escape(p.kind)} · ${escape(p.model)} · ${p.configured?'configured':'credential missing'}</div>`).join('')+
      `<div class="connection">Pushover: ${state.notifications.pushover?'connected':'not configured'} · Email summaries: ${state.notifications.email?'connected':'not configured'}</div><div class="connection">Email intake: ${state.emailIntake?'queue configured':'forwarding to Gmail; Worker pending'} · ${state.notifications.pending} notifications awaiting delivery</div>`;
    renderFleet();renderList();renderServices();if(selected)await renderDetail(selected);
    $('updated').textContent='Updated '+time(state.now);
  }catch(e){fleetUnavailable=true;renderFleet();if(e.message!=='Sign in required')error(e);}
  finally{refreshing=false;}
}
function renderFleet() {
  if(!state)return;
  const names={process:'Process stopped',endpoint:'Local endpoint failed',public:'Public endpoint failed'};
  const order={unhealthy:0,unknown:1,stale:2,healthy:3};
  const rows=(state.serviceHealth||state.services.map(s=>({...s,status:'unknown',checks:{}}))).map(s=>{
    if(fleetUnavailable)return {...s,status:'unknown',reason:'Dashboard connection unavailable'};
    if(s.checkedAt&&Date.now()-Date.parse(s.checkedAt)>65000)return {...s,status:'stale',reason:'Check is out of date'};
    return s;
  }).sort((a,b)=>order[a.status]-order[b.status]||a.host.localeCompare(b.host)||a.name.localeCompare(b.name));
  const counts=status=>rows.filter(s=>s.status===status).length;
  $('fleet-summary').innerHTML=`<strong>${rows.length} services</strong><span class="health-healthy">${counts('healthy')} healthy</span><span class="health-unhealthy">${counts('unhealthy')} unhealthy</span><span class="health-unknown">${counts('unknown')+counts('stale')} unknown / stale</span>`;
  $('fleet-services').innerHTML=rows.map(s=>{
    const failed=Object.entries(s.checks||{}).filter(([,ok])=>ok===false).map(([key])=>names[key]||key);
    const detail=s.status==='healthy'?'All configured checks passed':s.status==='unhealthy'?failed.join(' · '):s.reason||'Waiting for health checks';
    return `<li class="fleet-service health-${escape(s.status)}"><div class="fleet-heading"><strong>${escape(s.name)}</strong><span class="health-label">${escape(label(s.status))}</span></div><div class="meta">${escape(s.host)} · ${s.checkedAt?'Checked '+time(s.checkedAt):'Not checked yet'}</div><p>${escape(detail)}</p></li>`;
  }).join('');
}
function renderList() {
  let items=[...state.incidents,...state.peers.flatMap(p=>(p.incidents||[]).map(i=>({...i,peerUrl:p.url,responder:p.host})))]
    .sort((a,b)=>Date.parse(b.created)-Date.parse(a.created));
  if($('filter').value==='attention')items=items.filter(i=>!good.includes(i.status));
  if($('filter').value==='resolved')items=items.filter(i=>good.includes(i.status));
  $('incidents').innerHTML=items.length?items.map(i=>{
    const content=`<div class="incident-head"><span class="incident-title">${escape(i.service)}</span>${badge(i.status)}</div><p>${escape(i.alert.name)}</p><div class="meta">${escape(i.host)} · ${time(i.created)} · $${i.spent.toFixed(4)}</div>`;
    if(i.peerUrl) {
      const destination=i.responder.charAt(0).toUpperCase()+i.responder.slice(1);
      const current=state.host.charAt(0).toUpperCase()+state.host.slice(1);
      return `<a class="incident incident-peer" href="${escape(i.peerUrl)}/?incident=${encodeURIComponent(i.id)}">${content}<div class="incident-destination"><span>Open in ${escape(destination)} dashboard <span aria-hidden="true">→</span></span><small>Leaves ${escape(current)} dashboard</small></div></a>`;
    }
    return `<button class="incident" data-id="${escape(i.id)}" aria-pressed="${i.id===selected}">${content}</button>`;
  }).join(''):
    '<div class="empty"><h3>No incidents in this view</h3><p>New alerts will appear here with their evidence and recovery timeline.</p></div>';
  for(const b of $('incidents').querySelectorAll('button'))b.onclick=()=>{
    selected=b.dataset.id;history.replaceState(null,'',`?incident=${selected}`);renderList();renderDetail(selected).catch(error);
  };
}
async function renderDetail(id) {
  const data=await api(`/api/incidents/${id}`);if(id!==selected)return;
  const i=data.incident;
  $('detail').innerHTML=`<div class="detail-top"><div><p class="eyebrow">${escape(i.host)} · ${escape(i.alert.source)}</p><h2>${escape(i.service)}</h2><span class="meta">${time(i.created)}</span></div>${badge(i.status)}</div>
    <p>${escape(i.alert.summary)}</p><div class="detail-section"><h3>Assessment</h3><p class="diagnosis">${escape(i.diagnosis||'Waiting for investigation.')}</p></div>
    ${i.status==='needs_approval'?`<div class="approval"><h3>Approval requested</h3><p><strong>${escape(i.action)}</strong> on <strong>${escape(i.service)}</strong> (${escape(i.host)}). Approval expires ${time(i.approvalExpires)}. The service will be checked again before execution.</p><button class="primary" id="approve">Approve ${escape(i.action)}</button><button id="reject">Reject action</button></div>`:''}
    <div class="detail-section"><h3>Recovery timeline</h3><ol class="timeline">${data.events.map(e=>`<li><time>${time(e.at)}</time><details ${['action_result','verification'].includes(e.kind)?'open':''}><summary>${escape(label(e.kind))}</summary><pre>${escape(JSON.stringify(e.data,null,2))}</pre></details></li>`).join('')}</ol></div>`;
  if($('approve'))$('approve').onclick=async()=>{const b=$('approve');b.disabled=true;b.textContent='Executing and verifying…';try{await api(`/api/incidents/${id}/approve`,{action:i.action});await refresh();}catch(e){error(e);b.disabled=false;}};
  if($('reject'))$('reject').onclick=async()=>{try{await api(`/api/incidents/${id}/reject`,{});await refresh();}catch(e){error(e);}};
}
function renderServices() {
  $('services').innerHTML=state.services.map(s=>`<div class="service-row"><strong>${escape(s.name)}</strong><span>${escape(s.host)} · ${s.autoActions.length?'automatic procedures':'approval required'}</span><span class="service-owner">Responder: ${escape(s.owner)}</span>${s.owner===state.host?`<button data-service="${escape(s.name)}">${s.paused?'Resume':'Pause'}</button>`:'<span>Managed by peer</span>'}</div>`).join('');
  for(const b of $('services').querySelectorAll('button'))b.onclick=async()=>{try{const s=state.services.find(s=>s.name===b.dataset.service);await api('/api/controls',{service:s.name,paused:!s.paused});await refresh();}catch(e){error(e);}};
}
$('login-form').onsubmit=async e=>{e.preventDefault();try{await api('/api/login',{password:$('password').value});$('password').value='';await refresh();}catch(e){error(e);}};
$('logout').onclick=async()=>{try{await api('/api/logout',{});location.reload();}catch(e){error(e);}};
$('refresh').onclick=refresh;
$('filter').onchange=renderList;
$('pause').onclick=async()=>{try{await api('/api/controls',{paused:!state.paused});await refresh();}catch(e){error(e);}};
$('settings-form').oninput=()=>editing=true;
$('settings-form').onsubmit=async e=>{e.preventDefault();try{await api('/api/controls',{automatic:$('automatic').checked,budgetUsd:Number($('budget').value)});editing=false;await refresh();}catch(e){error(e);}};
let theme=localStorage.getItem('aiops-theme')||'system';
function applyTheme(){if(theme==='system')delete document.documentElement.dataset.theme;else document.documentElement.dataset.theme=theme;$('theme').textContent='Theme: '+theme;localStorage.setItem('aiops-theme',theme);}
$('theme').onclick=()=>{theme=['system','light','dark'][(['system','light','dark'].indexOf(theme)+1)%3];applyTheme();};
let refreshInterval=Number(localStorage.getItem('aiops-refresh-ms'))||30000;
if(![30000,60000,120000].includes(refreshInterval))refreshInterval=30000;
$('refresh-interval').value=String(refreshInterval);
let refreshTimer;
function scheduleRefresh(){clearInterval(refreshTimer);refreshTimer=setInterval(()=>{if(!document.hidden&&!$('console').hidden)refresh();},refreshInterval);}
$('refresh-interval').onchange=()=>{refreshInterval=Number($('refresh-interval').value);localStorage.setItem('aiops-refresh-ms',String(refreshInterval));scheduleRefresh();refresh();};
document.addEventListener('visibilitychange',()=>{if(!document.hidden){renderFleet();refresh();}});
setInterval(()=>{if(!document.hidden&&!$('console').hidden)renderFleet();},5000);
applyTheme();refresh();scheduleRefresh();
