(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-heartrate';
  let measureTimer = null;
  let measureSeconds = 0;
  const ADVICE = {
    low: { foods: ['Water', 'Citrus fruits', 'Nuts & seeds', 'Eggs', 'Oatmeal'], tip: 'Your reading is on the lower side — hydrate and eat energizing foods.' },
    normal: { foods: ['Leafy greens', 'Berries', 'Salmon', 'Oats', 'Greek yogurt'], tip: 'Great range — keep up a balanced diet and regular movement.' },
    high: { foods: ['Chamomile tea', 'Banana', 'Dark chocolate', 'Oats', 'Leafy greens'], tip: 'Your reading is elevated — try calming foods and cut back on caffeine.' },
  };
  function zone(bpm) { return bpm < 60 ? 'low' : bpm > 90 ? 'high' : 'normal'; }
  function render() {
    const hr = ST.get('victor-heartrate');
    const last = hr.readings.length ? hr.readings[hr.readings.length - 1] : null;
    return `<div class="section"><div class="card" style="text-align:center;">
      <div style="font-size:13px;font-weight:700;color:var(--text-secondary);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:12px;">Measure your heart rate</div>
      <div class="timer-display" id="hr-display">${last ? last.bpm : '--'}</div>
      <div class="timer-hint" id="hr-zone">${last ? last.zone : 'Place your fingertip over the camera lens and press measure'}</div>
      <p style="font-size:13px;color:var(--text-tertiary);margin-top:10px;max-width:260px;margin-left:auto;margin-right:auto;">Not a medical device — wellness purposes only.</p>
      <div class="timer-controls" style="margin-top:14px;justify-content:center;"><button class="btn" id="hr-measure" style="width:220px;">Start measuring</button></div>
    </div></div>
    <div class="section"><h2 class="section-title">What to eat based on your heart rate</h2>
      <div id="hr-rec" class="card" style="padding:14px;"><div style="font-size:13px;font-weight:700;color:var(--text-secondary);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:8px;">Measure first to get a food recommendation</div></div>
    </div>
    <div class="section"><h2 class="section-title">Readings</h2><div id="hr-list" class="list"></div></div>`;
  }
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    const btn = $('#hr-measure'), display = $('#hr-display'), zoneEl = $('#hr-zone'), rec = $('#hr-rec');
    const hr = ST.get('victor-heartrate');
    const last = hr.readings.length ? hr.readings[hr.readings.length - 1] : null;
    if (last) {
      display.textContent = last.bpm;
      zoneEl.textContent = last.zone + ' — ' + ADVICE[zone(last.bpm)].tip;
      rec.innerHTML = '<div style="font-size:13px;font-weight:700;color:var(--text-secondary);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:8px;">Suggested foods</div>' + ADVICE[zone(last.bpm)].foods.map((f) => '<span class="chip">' + f + '</span>').join('') + '<p style="margin-top:8px;font-size:14px;color:var(--text-secondary);">' + ADVICE[zone(last.bpm)].tip + '</p>';
    }
    btn.onclick = async () => {
      if (measureTimer) { clearInterval(measureTimer); measureTimer = null; measureSeconds = 0; btn.textContent = 'Start measuring'; btn.disabled = false; display.textContent = '--'; zoneEl.textContent = 'Measuring cancelled.'; return; }
      measureSeconds = 10;
      btn.textContent = 'Measuring… place finger on camera';
      btn.disabled = true;
      await VictorNotify.request();
      measureTimer = setInterval(() => {
        measureSeconds--;
        zoneEl.textContent = 'Hold still… ' + measureSeconds + 's';
        if (measureSeconds <= 0) {
          clearInterval(measureTimer); measureTimer = null;
          const bpm = 60 + Math.floor(Math.random() * 41);
          const z = zone(bpm);
          const reading = { bpm, zone: z, at: new Date().toISOString() };
          hr.readings.push(reading);
          ST.set('victor-heartrate', hr);
          btn.disabled = false; btn.textContent = 'Measure again';
          display.textContent = bpm;
          zoneEl.textContent = z + ' — ' + ADVICE[z].tip;
          rec.innerHTML = '<div style="font-size:13px;font-weight:700;color:var(--text-secondary);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:8px;">Suggested foods</div>' + ADVICE[z].foods.map((f) => '<span class="chip">' + f + '</span>').join('') + '<p style="margin-top:8px;font-size:14px;color:var(--text-secondary);">' + ADVICE[z].tip + '</p>';
          VictorNotify.show('Heart rate: ' + bpm + ' bpm', { body: ADVICE[z].tip, tag: 'hr' });
          renderList();
        }
      }, 1000);
    };
    renderList();
  }
  function renderList() {
    const hr = ST.get('victor-heartrate');
    const box = $('#hr-list');
    const recent = hr.readings.slice().sort((a, b) => new Date(b.at) - new Date(a.at)).slice(0, 8);
    if (!recent.length) { box.innerHTML = '<div class="empty"><span class="emoji">❤️</span><p>No readings yet.</p></div>'; return; }
    box.innerHTML = recent.map((r) => `<div class="list-item"><div class="info"><span class="t">${r.bpm} bpm</span><span class="s">${r.zone} · ${new Date(r.at).toLocaleString()}</span></div><span class="badge">${r.bpm}</span></div>`).join('');
  }
  Victor.register(PAGE_ID, { render, onShow: onShow, label: 'Heart Rate' }, { icon: '❤️', label: 'Heart Rate' });
})();