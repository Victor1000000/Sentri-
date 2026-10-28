(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-water';
  function render() {
    const w = ST.get('victor-water');
    const today = new Date().toDateString();
    const drunk = w.daily[today] || 0;
    const pct = Math.min(100, Math.round((drunk / w.goal) * 100));
    return `<div class="section"><div class="card"><div style="display:flex;align-items:center;justify-content:space-between;gap:14px;">
      <div style="flex:1;"><div class="stat" style="color:var(--accent);">${drunk}<span class="unit"> / ${w.goal} glasses today</span></div>
        <div style="color:var(--text-secondary);font-size:14px;margin-top:4px;">Reminder every hour</div></div>
      <svg class="progress-ring" viewBox="0 0 100 100"><circle cx="50" cy="50" r="42" stroke="#e5e5ea" stroke-width="10" fill="none"/>
        <circle cx="50" cy="50" r="42" stroke="var(--accent)" stroke-width="10" fill="none" stroke-linecap="round" style="transform:rotate(-90deg);transform-origin:50% 50%;stroke-dasharray:264;stroke-dashoffset:${264 - (264 * pct) / 100}"/></svg>
    </div><div class="timer-controls" style="margin-top:12px;justify-content:center;">
      <button class="btn btn-sm" id="wa-plus">+1 glass</button>
      <button class="btn btn-outline btn-sm" id="wa-minus">−1 glass</button>
      <button class="btn btn-sm btn-outline" id="wa-goal">Change goal</button>
    </div></div></div>
    <div class="section"><h2 class="section-title">Hourly reminder</h2>
      <label style="display:flex;align-items:center;gap:10px;"><input type="checkbox" id="wa-toggle" ${w.enabled !== false ? 'checked' : ''}><span class="slider" style="margin-left:auto;"></span><span style="font-weight:600;">Remind me every hour</span></label>
      <p id="wa-next" style="margin:8px 0 0 0;font-size:14px;color:var(--text-secondary);"></p>
    </div>
    <div class="section"><h2 class="section-title">History</h2><div id="wa-list" class="list"></div></div>`;
  }
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    const w = ST.get('victor-water');
    $('#wa-plus').onclick = () => logWater(1);
    $('#wa-minus').onclick = () => logWater(-1);
    $('#wa-goal').onclick = () => { const g = parseInt(prompt('Daily water goal (glasses):', w.goal || 8), 10); if (g && g > 0) { w.goal = g; ST.set('victor-water', w); Victor.toast('Goal set to ' + g + ' glasses'); onShow(); } };
    $('#wa-toggle').onchange = (e) => { w.enabled = e.target.checked; ST.set('victor-water', w); Victor.toast(w.enabled ? 'Hourly water reminders on' : 'Hourly reminders off'); };
    updateNext();
    renderHistory();
  }
  function logWater(delta) {
    const w = ST.get('victor-water');
    const today = new Date().toDateString();
    w.daily[today] = Math.max(0, (w.daily[today] || 0) + delta);
    if (delta > 0) w.intake.push({ at: new Date().toISOString() });
    ST.set('victor-water', w);
    onShow();
    Victor.toast(delta > 0 ? 'Glass logged — keep it up!' : 'Glass removed');
  }
  function updateNext() { const w = ST.get('victor-water'); const ms = Math.max(0, (w.lastReminder || Date.now()) + 3600000 - Date.now()); const m = Math.floor(ms / 60000);
    document.getElementById('wa-next').textContent = m > 0 ? 'Next reminder in ~' + m + ' min' : 'Reminder due now'; }
  function tick() {
    const w = ST.get('victor-water');
    if (!w.enabled) return;
    if (!w.lastReminder || Date.now() - w.lastReminder >= 3600000) { w.lastReminder = Date.now(); ST.set('victor-water', w);
      VictorNotify.request().then(() => VictorNotify.show('Time to drink water 💧', { body: 'Drink a glass of water every hour.', tag: 'water' })); }
    const p = document.getElementById('wa-next');
    if (p) { const ms = Math.max(0, (w.lastReminder || Date.now()) + 3600000 - Date.now()); p.textContent = ms > 0 ? 'Next reminder in ~' + Math.ceil(ms / 60000) + ' min' : 'Reminder due now'; }
  }
  function renderHistory() {
    const w = ST.get('victor-water');
    const box = $('#wa-list');
    const recent = w.intake.slice().sort((a, b) => new Date(b.at) - new Date(a.at)).slice(0, 10);
    if (!recent.length) { box.innerHTML = '<div class="empty"><span class="emoji">💧</span><p>No glasses logged yet.</p></div>'; return; }
    box.innerHTML = recent.map((g) => `<div class="list-item"><div class="info"><span class="t">1 glass</span><span class="s">${new Date(g.at).toLocaleString()}</span></div></div>`).join('');
  }
  Victor.register(PAGE_ID, { render, onShow: onShow, tick, logWater, label: 'Water' }, { icon: '💧', label: 'Water' });
})();