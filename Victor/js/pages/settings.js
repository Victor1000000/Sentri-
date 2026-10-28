(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-settings';
  function render() {
    const bible = ST.get('victor-bible');
    return `<div class="section"><h2 class="section-title">Settings</h2>
      <div class="card"><div class="input-group" style="margin-bottom:0;">
        <label style="display:flex;align-items:center;justify-content:space-between;">
          <span>Bible verse reminders (every 10 min)</span>
          <label class="switch"><input type="checkbox" id="st-bible" ${bible.enabled ? 'checked' : ''}><span class="slider"></span></label>
        </label>
      </div><button class="btn btn-sm btn-outline" id="st-perm" style="margin-top:10px;">Enable notifications</button>
      <p style="font-size:13px;color:var(--text-secondary);margin-top:8px;">Notifications work best when you add Victor to your home screen (PWA).</p>
      </div></div>
      <div class="section"><h2 class="section-title">Data</h2>
      <div class="card">
        <button class="btn btn-outline btn-sm" id="st-export">Export my data (JSON)</button>
        <button class="btn btn-outline btn-sm" id="st-reset" style="color:var(--danger);border-color:var(--danger);">Reset all data</button>
      </div></div>
      <div class="section"><div class="card" style="text-align:center;">
        <div style="font-size:13px;font-weight:700;color:var(--text-secondary);text-transform:uppercase;letter-spacing:0.05em;">Victor</div>
        <div style="color:var(--text-secondary);font-size:14px;">All-in-one daily companion · v1.0.0</div>
        <div style="color:var(--text-secondary);font-size:13px;margin-top:8px;">Minimalist · Apple-inspired · Built for Victor</div>
      </div></div></div>`;
  }
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    const bible = ST.get('victor-bible');
    $('#st-bible').checked = bible.enabled;
    $('#st-bible').onchange = (e) => { bible.enabled = e.target.checked; ST.set('victor-bible', bible); Victor.toast(bible.enabled ? 'Verse reminders on' : 'Verse reminders off'); if (bible.enabled) VictorNotify.request(); };
    $('#st-perm').onclick = async () => { const ok = await VictorNotify.request(); Victor.toast(ok ? 'Notifications enabled' : 'Notifications not granted'); };
    $('#st-export').onclick = () => {
      const data = {};
      ['victor-screentime', 'victor-water', 'victor-sleep', 'victor-heartrate', 'victor-habits', 'victor-journal', 'victor-scheduler', 'victor-focus', 'victor-bible'].forEach((k) => { data[k] = ST.get(k); });
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = 'victor-data-backup.json'; a.click();
      URL.revokeObjectURL(url);
      Victor.toast('Data exported');
    };
    $('#st-reset').onclick = () => { if (!confirm('Reset all your Victor data? This cannot be undone.')) return; localStorage.clear(); Victor.toast('All data reset'); Victor.showPage('page-home'); };
  }
  Victor.register(PAGE_ID, { render, onShow: onShow, label: 'Settings' }, { icon: '⚙️', label: 'Settings' });
})();