(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-focus';
  let timer = null;
  let timeLeft = 25 * 60;
  let running = false;
  let mode = 'work';
  function fmt(sec) {
    const m = Math.floor(sec / 60), s = sec % 60;
    return String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
  }
  function render() {
    const focus = ST.get('victor-focus');
    return `<div class="section"><h2 class="section-title">Focus timer</h2>
      <p style="color:var(--text-secondary);font-size:14px;margin-bottom:12px;">Work in sprints. Victor keeps distractions away while you focus.</p>
      <div class="card" style="text-align:center;">
        <div class="tag">${mode === 'work' ? 'Work time' : 'Break time'}</div>
        <div class="timer-display" id="fo-timer">${fmt(timeLeft)}</div>
        <div class="timer-hint" id="fo-hint">${running ? 'Stay focused — notifications silenced' : 'Ready to start'}</div>
        <div class="timer-controls" style="margin-top:12px;justify-content:center;">
          <button class="btn" id="fo-start">${running ? 'Pause' : 'Start'}</button>
          <button class="btn btn-outline btn-sm" id="fo-skip" style="display:${mode === 'work' ? 'inline-block' : 'none'}">Skip to break</button>
          <button class="btn btn-outline btn-sm" id="fo-reset">Reset</button>
        </div>
        <div style="margin-top:10px;font-size:15px;color:var(--text-secondary);">Sessions completed: <span class="stat" style="font-size:17px;">${focus.sessions}</span></div>
      </div></div>`;
  }
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    const btn = $('#fo-start'), skip = $('#fo-skip'), reset = $('#fo-reset'), hint = $('#fo-hint'), disp = $('#fo-timer');
    function refresh() { disp.textContent = fmt(timeLeft); hint.textContent = running ? (mode === 'work' ? 'Stay focused' : 'Relax and breathe') : (mode === 'work' ? 'Ready to start' : 'Break ready'); btn.textContent = running ? 'Pause' : 'Start'; skip.style.display = mode === 'work' ? 'inline-block' : 'none'; }
    refresh();
    btn.onclick = () => { if (running) { running = false; if (timer) { clearInterval(timer); timer = null; } refresh(); return; } running = true; refresh(); tick(); };
    skip.onclick = () => { if (timer) { clearInterval(timer); timer = null; } mode = 'break'; timeLeft = 5 * 60; running = false; refresh(); };
    reset.onclick = () => { if (timer) { clearInterval(timer); timer = null; } running = false; mode = 'work'; timeLeft = 25 * 60; refresh(); };
    function tick() {
      timer = setInterval(() => { timeLeft--; refresh();
        if (timeLeft <= 0) { clearInterval(timer); timer = null; running = false;
          if (mode === 'work') { const focus = ST.get('victor-focus'); focus.sessions = (focus.sessions || 0) + 1; ST.set('victor-focus', focus); VictorNotify.request().then(() => VictorNotify.show('Focus session complete', { body: 'Time for a 5-minute break.', tag: 'focus' })); Victor.toast('Session complete — take a break!'); }
          mode = 'break'; timeLeft = 5 * 60; refresh(); } }, 1000);
    }
  }
  Victor.register(PAGE_ID, { render, onShow: onShow, label: 'Focus' }, { icon: '🎯', label: 'Focus' });
})();