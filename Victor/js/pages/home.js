(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-home';
  function render() {
    const st = ST.get('victor-screentime');
    const water = ST.get('victor-water');
    const sleep = ST.get('victor-sleep');
    const hr = ST.get('victor-heartrate');
    const today = new Date().toDateString();
    const used = st.daily[today] || 0;
    const left = Math.max(0, st.limitMinutes - used);
    const glasses = water.daily[today] || 0;
    const lastSleep = sleep.logs.length ? sleep.logs[sleep.logs.length - 1] : null;
    const lastHr = hr.readings.length ? hr.readings[hr.readings.length - 1] : null;
    const h = new Date().getHours();
    const greet = h < 12 ? 'morning' : h < 18 ? 'afternoon' : 'evening';
    return `<div class="section"><div class="row" style="align-items:flex-start;"><div style="flex:1;">
      <h2 style="margin:0 0 2px 0;font-size:22px;font-weight:700;letter-spacing:-0.02em;">Good <span style="color:var(--accent);">${greet}</span>, Victor.</h2>
      <span style="color:var(--text-secondary);font-size:15px;">${new Date().toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })}</span>
    </div></div></div>
    <div class="section">
      <div class="card"><div class="stat" style="color:var(--danger);">${used}<span class="unit"> min today</span></div>
        <div style="color:var(--text-secondary);font-size:15px;margin-top:6px;">${used >= st.limitMinutes ? 'Daily limit reached — time to log off' : left + ' min left of your 30 min social limit'}</div></div>
      <div class="card"><div class="stat" style="color:var(--accent);">${glasses}<span class="unit"> glasses today</span></div>
        <div style="color:var(--text-secondary);font-size:15px;margin-top:6px;">Drink water every hour — goal: ${water.goal} glasses</div></div>
      <div class="card"><div class="stat">${lastSleep ? Math.round(lastSleep.duration / 60) : '--'}<span class="unit"> hrs slept last night</span></div>
        <div style="color:var(--text-secondary);font-size:15px;margin-top:6px;">${lastSleep ? new Date(lastSleep.wake).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + ' wake-up' : 'Track your sleep tonight'}</div></div>
      <div class="card"><div class="stat">${lastHr ? lastHr.bpm : '--'}<span class="unit"> bpm</span></div>
        <div style="color:var(--text-secondary);font-size:15px;margin-top:6px;">${lastHr ? lastHr.zone : 'Check your heart rate'}</div></div>
    </div>
    <div class="section"><h2 class="section-title">Quick actions</h2>
      <div class="grid-4">
        <button class="btn btn-ghost" onclick="Victor.navigate('page-screentime')" style="height:88px;flex-direction:column;"><span style="font-size:28px;margin-bottom:8px;">⏱️</span>Screen Time</button>
        <button class="btn btn-ghost" onclick="Victor.navigate('page-workouts')" style="height:88px;flex-direction:column;"><span style="font-size:28px;margin-bottom:8px;">💪</span>Workout</button>
        <button class="btn btn-ghost" onclick="Victor.navigate('page-water')" style="height:88px;flex-direction:column;"><span style="font-size:28px;margin-bottom:8px;">💧</span>Log Water</button>
        <button class="btn btn-ghost" onclick="Victor.navigate('page-focus')" style="height:88px;flex-direction:column;"><span style="font-size:28px;margin-bottom:8px;">🎯</span>Focus</button>
      </div>
    </div>
    <div class="section"><h2 class="section-title">Today's schedule</h2><div id="home-schedule" class="list"></div></div>
    <div class="section" style="padding-bottom:14px;">
      <div class="card"><div style="display:flex;align-items:center;justify-content:space-between;">
        <div><div style="font-weight:700;color:var(--text);font-size:16px;">Bible verse reminders</div><div style="font-size:14px;color:var(--text-secondary);">Every 10 minutes</div></div>
        <label class="switch" style="margin-left:10px;"><input type="checkbox" id="home-bible-toggle"><span class="slider"></span></label>
      </div><p id="home-bible-next" style="margin:10px 0 0 0;font-size:14px;color:var(--text-secondary);"></p></div></div>
    `;
  }
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    const b = ST.get('victor-bible');
    $('#home-bible-toggle').checked = b.enabled;
    document.getElementById('home-bible-next').textContent = b.nextAt ? 'Next verse in ' + Math.ceil((b.nextAt - Date.now()) / 60000) + ' min' : 'Turn on to receive verses every 10 minutes';
    $('#home-bible-toggle').onchange = (e) => { b.enabled = e.target.checked; ST.set('victor-bible', b); Victor.toast(b.enabled ? 'Verse reminders on' : 'Verse reminders off'); if (b.enabled) VictorNotify.request(); };
    renderSchedule();
  }
  function renderSchedule() {
    const sched = ST.get('victor-scheduler');
    const today = new Date().toDateString();
    const due = sched.filter((a) => new Date(a.time).toDateString() === today && !a.done).sort((a, b) => new Date(a.time) - new Date(b.time));
    const box = $('#home-schedule');
    if (!due.length) { box.innerHTML = '<div class="empty"><span class="emoji">✅</span><h3>All caught up</h3><p>No activities scheduled for today.</p></div>'; return; }
    box.innerHTML = due.map((a) => `<div class="list-item"><div class="info"><span class="t">${a.title}</span><span class="s">${new Date(a.time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })} · ${a.category}</span></div><div style="display:flex;gap:8px;"><button class="btn btn-sm btn-ghost" onclick="Victor.navigate(\'page-scheduler\')">View</button></div></div>`).join('');
  }
  Victor.register(PAGE_ID, { render, onShow: onShow, label: 'Home' }, { icon: '🏠', label: 'Home' });
})();