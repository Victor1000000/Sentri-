(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-journal';
  const MOODS = ['😄', '🙂', '😐', '😔', '😭'];
  let selectedMood = null;
  function render() {
    return `<div class="section"><h2 class="section-title">Daily journal</h2>
      <p style="color:var(--text-secondary);font-size:14px;margin-bottom:12px;">Write down how you feel today. A few lines are enough.</p>
      <div class="card"><div style="display:flex;justify-content:center;gap:8px;margin-bottom:10px;">
        ${MOODS.map((m) => '<span class="chip" id="jm-' + m + '" data-mood="' + m + '">' + m + '</span>').join('')}
      </div>
      <div class="input-group" style="margin-bottom:0;"><label class="input-label">What\'s on your mind?</label><textarea id="jm-text" rows="4" placeholder="Today I feel…"></textarea></div>
      <button class="btn btn-full" id="jm-save">Save entry</button></div></div>
      <div class="section"><h2 class="section-title">Recent entries</h2><div id="jm-list" class="list"></div></div>`;
  }
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    MOODS.forEach((m) => { $('#jm-' + m).onclick = () => {
      document.querySelectorAll('.chip[data-mood]').forEach((x) => x.classList.remove('active'));
      $('#jm-' + m).classList.add('active');
      selectedMood = m; }; });
    $('#jm-save').onclick = () => {
      const text = $('#jm-text').value.trim();
      if (!text) { Victor.toast('Write something first'); return; }
      if (!selectedMood) { Victor.toast('Pick a mood'); return; }
      const journal = ST.get('victor-journal');
      journal.push({ id: 'jm-' + Date.now(), date: new Date().toDateString(), mood: selectedMood, text, createdAt: new Date().toISOString() });
      ST.set('victor-journal', journal);
      $('#jm-text').value = '';
      selectedMood = null;
      document.querySelectorAll('.chip[data-mood]').forEach((x) => x.classList.remove('active'));
      Victor.toast('Entry saved');
      onShow();
    };
    renderList();
  }
  function renderList() {
    const journal = ST.get('victor-journal');
    const box = $('#jm-list');
    const recent = journal.slice().sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt)).slice(0, 8);
    if (!recent.length) { box.innerHTML = '<div class="empty"><span class="emoji">📝</span><p>No entries yet.</p></div>'; return; }
    box.innerHTML = recent.map((e) => `<div class="list-item"><div class="info"><span class="t">${e.mood}</span><span class="s">${new Date(e.createdAt).toLocaleString()}</span></div><div style="padding:10px 16px 10px 0;border-top:1px solid var(--separator);font-size:15px;color:var(--text);">${e.text}</div></div>`).join('');
  }
  Victor.register(PAGE_ID, { render, onShow: onShow, label: 'Journal' }, { icon: '📝', label: 'Journal' });
})();