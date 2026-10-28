(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-screentime';
  const APPS = ['Instagram', 'TikTok', 'YouTube', 'X / Twitter', 'Facebook', 'Snapchat', 'Other'];
  let timer = null;
  function fmt(ms) {
    const s = Math.floor(ms / 1000), m = Math.floor(s / 60), h = Math.floor(m / 60);
    return (h ? h + 'h ' : '') + (m % 60) + 'm ' + (s % 60) + 's';
  }
  function render() {
    const st = ST.get('victor-screentime');
    const today = new Date().toDateString();
    const used = st.daily[today] || 0;
    const active = st.active;
    const limit = st.limitMinutes;
    let html = `<div class="section"><div class="card"><div class="stat" style="color:var(--danger);">${used}<span class="unit"> min on social media today</span></div>
      <div style="color:var(--text-secondary);font-size:15px;margin-top:6px;">Daily limit: ${limit} min — ${used >= limit ? 'LIMIT REACHED' : limit - used + ' min remaining'}</div></div></div>
      <div class="section"><h2 class="section-title">Start a session</h2>
        <p style="color:var(--text-secondary);font-size:14px;margin-bottom:14px;">Pick the app you are opening. Victor warns at 25 min and alerts at 30 min.</p>
        <div class="chips" id="st-chips"></div>
        <div style="margin-top:14px;"><button class="btn btn-full" id="st-start" disabled>Start session</button></div></div>`;
    if (active) {
      const spent = Math.floor((Date.now() - new Date(active.startedAt)) / 1000 / 60);
      const over = spent >= limit;
      const warn = spent >= 25 && spent < 30;
      html += `<div class="section"><div class="card" style="border-color:${over ? 'var(--danger)' : warn ? 'var(--warning)' : 'var(--separator)'};background:${over ? '#fbeaea' : warn ? '#fef3e7' : 'var(--bg-elevated)'};">
        <div style="font-size:13px;font-weight:700;color:var(--text-secondary);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:8px;">Active session — ${active.app}</div>
        <div class="timer-display" id="st-timer">${fmt(Date.now() - new Date(active.startedAt))}</div>
        <div class="timer-hint">${over ? '⏰ Time to log off — 30+ minutes on ' + active.app + '.' : warn ? '⚠️ 5 minutes left before your 30 min limit.' : 'Time elapsed since start'}</div>
        <div class="timer-controls"><button class="btn btn-outline btn-sm" id="st-end">End session</button></div>
      </div></div>`;
    }
    html += `<div class="section"><h2 class="section-title">Session history</h2><div id="st-history" class="list"></div></div>`;
    return html;
  }
  let selected = null;
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    const st = ST.get('victor-screentime');
    el.innerHTML = render();
    const chipBox = $('#st-chips');
    chipBox.innerHTML = APPS.map((a) => `<span class="chip" data-app="${a}">${a}</span>`).join('');
    chipBox.onclick = (e) => {
      const c = e.target.closest('.chip');
      if (!c) return;
      document.querySelectorAll('#st-chips .chip').forEach((x) => x.classList.remove('active'));
      c.classList.add('active');
      selected = c.dataset.app;
      $('#st-start').disabled = !selected;
    };
    $('#st-start').onclick = () => {
      const st = ST.get('victor-screentime');
      if (st.active) return;
      st.active = { app: selected, startedAt: Date.now() };
      ST.set('victor-screentime', st);
      startTimer();
      renderPage();
    };
    $('#st-end').onclick = endSession;
    if (st.active) startTimer();
    renderHistory();
  }
  function renderPage() { document.getElementById(PAGE_ID).innerHTML = render(); onShow(); }
  function startTimer() {
    if (timer) clearInterval(timer);
    timer = setInterval(() => {
      const st = ST.get('victor-screentime');
      if (!st.active) { clearInterval(timer); timer = null; return; }
      const spent = Math.floor((Date.now() - new Date(st.active.startedAt)) / 1000 / 60);
      const el = document.getElementById(PAGE_ID);
      const t = el.querySelector('#st-timer');
      const h = el.querySelector('.timer-hint');
      if (t) t.textContent = fmt(Date.now() - new Date(st.active.startedAt));
      if (h) h.innerHTML = spent >= st.limitMinutes ? '⏰ Time to log off — 30+ minutes on ' + st.active.app + '.' : spent >= 25 ? '⚠️ 5 minutes left before your 30 min limit.' : 'Time elapsed';
      if (spent >= st.limitMinutes) VictorNotify.request().then(() => VictorNotify.show('Time to log off', { body: 'You have been on ' + st.active.app + ' for 30 minutes.', tag: 'screentime' }));
    }, 1000);
  }
  function endSession() {
    const st = ST.get('victor-screentime');
    if (!st.active) return;
    const spent = Math.floor((Date.now() - new Date(st.active.startedAt)) / 1000 / 60);
    const today = new Date().toDateString();
    st.daily[today] = (st.daily[today] || 0) + spent;
    st.sessions.push({ app: st.active.app, minutes: spent, at: new Date().toISOString() });
    st.active = null;
    ST.set('victor-screentime', st);
    if (timer) { clearInterval(timer); timer = null; }
    Victor.toast('Session saved — ' + spent + ' min');
    renderPage();
  }
  function renderHistory() {
    const st = ST.get('victor-screentime');
    const box = $('#st-history');
    const recent = st.sessions.slice().sort((a, b) => new Date(b.at) - new Date(a.at)).slice(0, 8);
    if (!recent.length) { box.innerHTML = '<div class="empty"><span class="emoji">📵</span><h3>No sessions yet</h3><p>Start tracking your social media time.</p></div>'; return; }
    box.innerHTML = recent.map((s) => `<div class="list-item"><div class="info"><span class="t">${s.app}</span><span class="s">${s.minutes} min · ${new Date(s.at).toLocaleString()}</span></div><span class="badge">${s.minutes}m</span></div>`).join('');
  }
  Victor.register(PAGE_ID, { render, onShow: onShow, label: 'Screen Time' }, { icon: '⏱️', label: 'Screen Time' });
})();