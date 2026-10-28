(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-sleep';
  function render() {
    const sleep = ST.get('victor-sleep');
    const logs = sleep.logs.slice().sort((a, b) => new Date(b.wake) - new Date(a.wake));
    const last = logs[0];
    const week = logs.slice(0, 7);
    const avg = week.length ? Math.round(week.reduce((s, l) => s + l.duration, 0) / week.length) : 0;
    return `<div class="section"><div class="card"><div style="display:flex;gap:10px;flex-wrap:wrap;">
      <div style="flex:1;min-width:140px;"><div class="stat" style="color:var(--accent);">${last ? Math.round(last.duration / 60) : '--'}<span class="unit"> hrs last night</span></div>
        <div style="color:var(--text-secondary);font-size:14px;margin-top:4px;">${last ? new Date(last.wake).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + ' woke up' : 'No sleep logged yet'}</div></div>
      <div style="flex:1;min-width:140px;"><div class="stat" style="color:var(--text-secondary);">${avg || '--'}<span class="unit"> hrs avg (7 nights)</span></div>
        <div style="color:var(--text-secondary);font-size:14px;margin-top:4px;">Aim for 7–9 hours</div></div>
    </div></div></div>
    <div class="section"><h2 class="section-title">Log your sleep</h2>
      <div class="card"><div class="input-group" style="display:flex;gap:10px;">
        <div style="flex:1;"><label class="input-label">Bedtime</label><input type="datetime-local" id="sl-bed"></div>
        <div style="flex:1;"><label class="input-label">Wake time</label><input type="datetime-local" id="sl-wake"></div>
      </div><button class="btn btn-full" id="sl-add">Log sleep</button></div></div>
      <div class="section"><h2 class="section-title">Sleep history</h2><div id="sl-list" class="list"></div></div>`;
  }
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    const now = new Date(); now.setMinutes(now.getMinutes() - now.getTimezoneOffset(), 0, 0);
    $('#sl-bed').value = now.toISOString().slice(0, 16);
    $('#sl-add').onclick = () => {
      const bed = $('#sl-bed').value, wake = $('#sl-wake').value;
      if (!bed || !wake) { Victor.toast('Pick both times'); return; }
      if (new Date(wake) <= new Date(bed)) { Victor.toast('Wake time must be after bedtime'); return; }
      const duration = Math.round((new Date(wake) - new Date(bed)) / 60000);
      const sleep = ST.get('victor-sleep');
      sleep.logs.push({ bed, wake, duration, at: new Date().toISOString() });
      ST.set('victor-sleep', sleep);
      Victor.toast('Logged ' + Math.floor(duration / 60) + 'h ' + (duration % 60) + 'm');
      onShow();
    };
    renderHistory();
  }
  function renderHistory() {
    const sleep = ST.get('victor-sleep');
    const logs = sleep.logs.slice().sort((a, b) => new Date(b.wake) - new Date(a.wake)).slice(0, 10);
    const box = $('#sl-list');
    if (!logs.length) { box.innerHTML = '<div class="empty"><span class="emoji">😴</span><p>No sleep logs yet.</p></div>'; return; }
    box.innerHTML = logs.map((l) => { const h = Math.floor(l.duration / 60), m = l.duration % 60;
      return `<div class="list-item"><div class="info"><span class="t">${new Date(l.wake).toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })}</span><span class="s">${new Date(l.bed).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })} → ${new Date(l.wake).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span></div><span class="badge">${h}h ${m}m</span></div>`; }).join('');
  }
  Victor.register(PAGE_ID, { render, onShow: onShow, label: 'Sleep' }, { icon: '😴', label: 'Sleep' });
})();