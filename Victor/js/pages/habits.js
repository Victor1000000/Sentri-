(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-habits';
  const todayKey = () => new Date().toDateString();
  function streak(habit) {
    let s = 0, d = new Date();
    while (habit.completions[d.toDateString()]) { s++; d.setDate(d.getDate() - 1); }
    return s;
  }
  function render() {
    return `<div class="section"><h2 class="section-title">Daily habits</h2>
      <p style="color:var(--text-secondary);font-size:14px;margin-bottom:12px;">Tick each habit when you complete it. Streaks build every day you keep going.</p>
      <div class="card"><div class="input-group" style="display:flex;gap:10px;">
        <div style="flex:1;"><input type="text" id="hb-name" placeholder="e.g. Read 10 pages"></div>
        <button class="btn btn-sm" id="hb-add">Add</button>
      </div></div></div>
      <div class="section"><div id="hb-list" class="list"></div></div>`;
  }
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    const habits = ST.get('victor-habits');
    const key = todayKey();
    $('#hb-add').onclick = () => {
      const name = $('#hb-name').value.trim();
      if (!name) { Victor.toast('Enter a habit'); return; }
      habits.push({ id: 'hb-' + Date.now(), name, completions: {}, createdAt: new Date().toISOString() });
      ST.set('victor-habits', habits);
      $('#hb-name').value = '';
      onShow();
    };
    const box = $('#hb-list');
    if (!habits.length) { box.innerHTML = '<div class="empty"><span class="emoji">🎯</span><h3>No habits yet</h3><p>Add your first daily habit.</p></div>'; return; }
    box.innerHTML = habits.map((h) => { const done = !!h.completions[key];
      return `<div class="list-item"><div class="info" style="flex:1;"><span class="t">${h.name}</span><span class="s">${streak(h)} day streak</span></div>
        <div style="display:flex;gap:8px;">
          <button class="btn btn-sm ${done ? 'btn-success' : 'btn'}" style="${done ? 'background:var(--success);' : ''}" onclick="Victor.pages.' + PAGE_ID + ".toggle('" + h.id + "')\">${done ? 'Done ✓' : 'Done'}</button>
          <button class="btn btn-sm btn-ghost" style="color:var(--danger);" onclick="Victor.pages.' + PAGE_ID + ".remove('" + h.id + "')\">Delete</button>
        </div></div>`; }).join('');
  }
  function toggle(id) {
    const habits = ST.get('victor-habits');
    const h = habits.find((x) => x.id === id);
    if (h) { h.completions[todayKey()] = !h.completions[todayKey()]; ST.set('victor-habits', habits); }
    onShow();
  }
  function remove(id) { ST.set('victor-habits', ST.get('victor-habits').filter((x) => x.id !== id)); onShow(); }
  Victor.register(PAGE_ID, { render, onShow: onShow, toggle, remove, label: 'Habits' }, { icon: '🎯', label: 'Habits' });
})();