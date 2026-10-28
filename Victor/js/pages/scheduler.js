(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-scheduler';
  const CATEGORIES = ['Work', 'Personal', 'Health', 'Study', 'Other'];
  function render() {
    return `<div class="section"><h2 class="section-title">Plan your day</h2>
      <p style="color:var(--text-secondary);font-size:14px;margin-bottom:12px;">Victor will remind you until you start each activity.</p>
      <div class="card"><div class="input-group"><label class="input-label">Activity</label><input type="text" id="sch-title" placeholder="e.g. Morning jog"></div>
        <div class="input-group" style="display:flex;gap:10px;">
          <div style="flex:1;"><label class="input-label">Time</label><input type="datetime-local" id="sch-time"></div>
          <div style="flex:1;"><label class="input-label">Category</label><select id="sch-cat">${CATEGORIES.map((c) => '<option>' + c + '</option>').join('')}</select></div>
        </div>
        <div class="input-group" style="margin-bottom:0;"><label class="input-label">Notes (optional)</label><input type="text" id="sch-notes" placeholder="e.g. Bring running shoes"></div>
        <button class="btn btn-full" id="sch-add">Add activity</button>
      </div></div>
      <div class="section"><h2 class="section-title">Today</h2><div id="sch-list" class="list"></div></div>`;
  }
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    const now = new Date(); now.setSeconds(0, 0);
    $('#sch-time').value = now.toISOString().slice(0, 16);
    $('#sch-add').onclick = () => {
      const title = $('#sch-title').value.trim();
      if (!title) { Victor.toast('Enter an activity'); return; }
      const time = $('#sch-time').value;
      if (!time) { Victor.toast('Pick a time'); return; }
      const sched = ST.get('victor-scheduler');
      sched.push({ id: 'sch-' + Date.now(), title, time, category: $('#sch-cat').value, notes: $('#sch-notes').value.trim(), done: false, started: false, snoozeUntil: 0, createdAt: new Date().toISOString() });
      ST.set('victor-scheduler', sched);
      $('#sch-title').value = '';
      Victor.toast('Activity added');
      renderList();
    };
    renderList();
  }
  function renderList() {
    const sched = ST.get('victor-scheduler');
    const today = new Date().toDateString();
    const items = sched.filter((a) => new Date(a.time).toDateString() === today).sort((a, b) => new Date(a.time) - new Date(b.time));
    const box = $('#sch-list');
    if (!items.length) { box.innerHTML = '<div class="empty"><span class="emoji">📅</span><h3>Nothing planned yet</h3><p>Add your first activity above.</p></div>'; return; }
    box.innerHTML = items.map((a) => {
      const time = new Date(a.time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      const done = a.done, started = a.started;
      const overdue = !started && !done && new Date(a.time) < new Date() && (a.snoozeUntil || 0) < Date.now();
      const status = done ? '<span class="badge success">Done</span>' : started ? '<span class="badge success">Started</span>' : overdue ? '<span class="badge">Due now</span>' : '<span class="badge">Upcoming</span>';
      return `<div class="list-item"><div class="info" style="flex:1;"><span class="t">${a.title}</span><span class="s">${time} · ${a.category}${a.notes ? ' · ' + a.notes : ''} ${status}</span></div>
        <div style="display:flex;flex-direction:column;gap:6px;">
          ${!done && !started ? '<button class="btn btn-sm btn-outline" onclick="Victor.pages.' + PAGE_ID + ".start('" + a.id + "')\">I started</button>" : ''}
          <button class="btn btn-sm btn-ghost" onclick="Victor.pages.' + PAGE_ID + ".toggleDone('" + a.id + "')\">${done ? 'Undo' : 'Complete'}</button>
          <button class="btn btn-sm btn-ghost" style="color:var(--danger);" onclick="Victor.pages.' + PAGE_ID + ".remove('" + a.id + "')\">Delete</button>
        </div></div>`; }).join('');
  }
  function start(id) {
    const sched = ST.get('victor-scheduler');
    const item = sched.find((a) => a.id === id);
    if (item) { item.started = true; item.done = true; Victor.hideAlarm(); ST.set('victor-scheduler', sched); }
    renderList();
    Victor.toast('Great job getting started!');
  }
  function toggleDone(id) {
    const sched = ST.get('victor-scheduler');
    const item = sched.find((a) => a.id === id);
    if (item) { item.done = !item.done; if (!item.done) item.started = false; ST.set('victor-scheduler', sched); }
    renderList();
  }
  function remove(id) { ST.set('victor-scheduler', ST.get('victor-scheduler').filter((a) => a.id !== id)); renderList(); }
  function checkDue() {
    const sched = ST.get('victor-scheduler');
    const now = Date.now();
    const today = new Date().toDateString();
    let shown = false;
    for (const a of sched) {
      if (a.done || a.started) continue;
      if (new Date(a.time).toDateString() !== today) continue;
      if (a.snoozeUntil && now < a.snoozeUntil) continue;
      if (new Date(a.time) <= now) {
        if (!shown && document.visibilityState === 'visible') { Victor.showAlarm("It's time for '" + a.title + "'", a.category + ' · ' + new Date(a.time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }), a.id); VictorNotify.show('Time for ' + a.title, { body: a.notes || 'Get started now.', tag: 'sch-' + a.id }); }
        shown = true;
      }
    }
    if (!shown && !Victor.alarmActive()) Victor.hideAlarm();
  }
  Victor.register(PAGE_ID, { render, onShow: onShow, start, toggleDone, remove, checkDue, label: 'Schedule' }, { icon: '📅', label: 'Schedule' });
})();