(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-workouts';
  let timer = null;
  let timeLeft = 0;
  let running = false;
  const EXERCISES = [
    { id: 'pushup', name: 'Push-ups', cat: 'Beginner', target: 'Chest, Triceps', reps: '10–15 reps × 3', svg: '<svg viewBox="0 0 100 100"><path d="M20 78L78 78L78 70Q78 60 60 52L40 44Q28 44 20 56L20 64Z" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="30" cy="58" r="5" fill="#007aff"/><circle cx="70" cy="58" r="5" fill="#007aff"/><path d="M50 52Q50 70 78 78" fill="none" stroke="#86868d" stroke-width="3" stroke-linecap="round"/></svg>' },
    { id: 'squat', name: 'Squats', cat: 'Beginner', target: 'Legs, Glutes', reps: '15 reps × 3', svg: '<svg viewBox="0 0 100 100"><path d="M30 70L35 40Q35 30 45 30L55 30Q65 30 65 40L70 70" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="38" cy="30" r="5" fill="#007aff"/><path d="M30 78L70 78" stroke="#86868d" stroke-width="3" stroke-linecap="round"/></svg>' },
    { id: 'plank', name: 'Plank', cat: 'Beginner', target: 'Core', reps: '30–60 sec', svg: '<svg viewBox="0 0 100 100"><path d="M20 60L80 60L80 50Q80 40 60 40L40 40Q20 40 20 50Z" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="32" cy="44" r="4" fill="#007aff"/><circle cx="68" cy="44" r="4" fill="#007aff"/></svg>' },
    { id: 'jumpjack', name: 'Jumping Jacks', cat: 'Beginner', target: 'Full body, Cardio', reps: '20 reps × 3', svg: '<svg viewBox="0 0 100 100"><path d="M50 20Q20 20 20 50L25 75L50 55L75 75L80 50Q80 20 50 20Z" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="50" cy="32" r="5" fill="#007aff"/></svg>' },
    { id: 'lunge', name: 'Lunges', cat: 'Intermediate', target: 'Legs, Glutes', reps: '12 reps each leg × 3', svg: '<svg viewBox="0 0 100 100"><path d="M30 72L45 42Q45 32 55 32L65 72" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="30" cy="72" r="4" fill="#007aff"/><circle cx="66" cy="72" r="4" fill="#007aff"/><circle cx="48" cy="32" r="5" fill="#007aff"/><path d="M10 80L90 80" stroke="#86868d" stroke-width="3" stroke-linecap="round"/></svg>' },
    { id: 'burpee', name: 'Burpees', cat: 'Intermediate', target: 'Full body', reps: '8–10 reps × 3', svg: '<svg viewBox="0 0 100 100"><path d="M42 28L42 58L58 58L58 28Z" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><path d="M30 68L50 68L50 82L30 82Z" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><path d="M45 50Q50 70 55 82" fill="none" stroke="#86868d" stroke-width="3" stroke-linecap="round"/><circle cx="42" cy="28" r="4" fill="#007aff"/><circle cx="58" cy="28" r="4" fill="#007aff"/></svg>' },
    { id: 'situp', name: 'Sit-ups', cat: 'Intermediate', target: 'Abs, Core', reps: '15–20 reps × 3', svg: '<svg viewBox="0 0 100 100"><path d="M30 72Q50 72 50 30Q50 16 70 16L78 28" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="50" cy="44" r="5" fill="#007aff"/><path d="M22 80L78 80" stroke="#86868d" stroke-width="3" stroke-linecap="round"/></svg>' },
    { id: 'bridge', name: 'Glute Bridge', cat: 'Intermediate', target: 'Glutes, Lower back', reps: '12 reps × 3', svg: '<svg viewBox="0 0 100 100"><path d="M25 70Q40 70 40 50Q40 32 60 32Q80 32 80 50Q80 70 60 70Q40 70 25 70" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="44" cy="42" r="4" fill="#007aff"/><circle cx="56" cy="42" r="4" fill="#007aff"/></svg>' },
    { id: 'mountain', name: 'Mountain Climbers', cat: 'Intermediate', target: 'Core, Cardio', reps: '20 reps × 3', svg: '<svg viewBox="0 0 100 100"><path d="M22 64Q30 50 42 50L58 50Q70 50 78 64" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><circle cx="30" cy="56" r="4" fill="#007aff"/><circle cx="70" cy="56" r="4" fill="#007aff"/><path d="M42 50Q42 30 55 30" fill="none" stroke="#86868d" stroke-width="3" stroke-linecap="round"/><circle cx="55" cy="30" r="4" fill="#86868d"/></svg>' },
    { id: 'dip', name: 'Triceps Dips', cat: 'Advanced', target: 'Triceps, Shoulders', reps: '10–12 reps × 3', svg: '<svg viewBox="0 0 100 100"><path d="M30 50L30 30Q30 20 40 20L60 20Q70 20 70 30L70 50" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="34" cy="22" r="4" fill="#007aff"/><circle cx="66" cy="22" r="4" fill="#007aff"/><path d="M20 58L80 58" stroke="#86868d" stroke-width="3" stroke-linecap="round"/></svg>' },
    { id: 'pistol', name: 'Pistol Squat', cat: 'Advanced', target: 'Legs, Balance', reps: '6–8 reps each leg', svg: '<svg viewBox="0 0 100 100"><path d="M50 30L48 60L42 78" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><path d="M50 30L62 30Q70 30 70 44L70 78" fill="none" stroke="#86868d" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/><circle cx="46" cy="22" r="4" fill="#007aff"/><circle cx="70" cy="22" r="4" fill="#86868d"/></svg>' },
    { id: 'handstand', name: 'Handstand Push-up', cat: 'Advanced', target: 'Shoulders, Core', reps: '5–8 reps × 3', svg: '<svg viewBox="0 0 100 100"><path d="M42 82L42 40Q42 20 60 20L78 40L78 82" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="46" cy="32" r="4" fill="#007aff"/><circle cx="74" cy="32" r="4" fill="#007aff"/></svg>' },
  ];
  function fmt(sec) {
    const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    return (h ? h + 'h ' : '') + String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
  }
  function render() {
    return '<div class="section"><h2 class="section-title">Workout timer</h2>' +
      '<div class="card"><div class="timer-display" id="wo-timer">' + fmt(timeLeft) + '</div>' +
      '<div class="timer-hint" id="wo-hint">Set hours, minutes and seconds, then start</div>' +
      '<div class="timer-controls">' +
      '<input type="number" id="wo-h" min="0" max="23" style="width:78px;" placeholder="h">' +
      '<input type="number" id="wo-m" min="0" max="59" style="width:78px;" placeholder="m">' +
      '<input type="number" id="wo-s" min="0" max="59" style="width:78px;" placeholder="s">' +
      '</div><div class="timer-controls" style="margin-top:10px;">' +
      '<button class="btn" id="wo-start">' + (running ? 'Pause' : 'Start') + '</button>' +
      '<button class="btn btn-outline" id="wo-reset">Reset</button>' +
      '</div></div></div>' +
      '<div class="section"><h2 class="section-title">Home workouts</h2>' +
      '<p style="color:var(--text-secondary);font-size:14px;margin-bottom:12px;">Tap an exercise to see how to do it, or start its preset timer.</p>' +
      '<div id="wo-list" class="list"></div></div>';
  }
  function onShow() {
    const el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    $('#wo-start').onclick = toggleTimer;
    $('#wo-reset').onclick = function () {
      running = false;
      if (timer) { clearInterval(timer); timer = null; }
      timeLeft = 0;
      $('#wo-h').value = ''; $('#wo-m').value = ''; $('#wo-s').value = '';
      $('#wo-start').textContent = 'Start';
      $('#wo-hint').textContent = 'Set hours, minutes and seconds, then start';
      el.querySelector('#wo-timer').textContent = fmt(0);
    };
    ['wo-h', 'wo-m', 'wo-s'].forEach(function (id) {
      $(id).oninput = function () {
        if (!running) {
          timeLeft = (+$('#wo-h').value || 0) * 3600 + (+$('#wo-m').value || 0) * 60 + (+$('#wo-s').value || 0);
          el.querySelector('#wo-timer').textContent = fmt(timeLeft);
        }
      };
    });
    renderList();
    if (running) tickTimer();
  }
  function toggleTimer() {
    if (running) { running = false; if (timer) { clearInterval(timer); timer = null; } $('#wo-start').textContent = 'Resume'; return; }
    if (timeLeft <= 0) {
      timeLeft = (+$('#wo-h').value || 0) * 3600 + (+$('#wo-m').value || 0) * 60 + (+$('#wo-s').value || 0);
      if (timeLeft <= 0) { Victor.toast('Set a time first'); return; }
    }
    running = true;
    $('#wo-start').textContent = 'Pause';
    tickTimer();
  }
  function tickTimer() {
    timer = setInterval(function () {
      timeLeft--;
      var el = document.getElementById(PAGE_ID);
      var d = el.querySelector('#wo-timer');
      if (d) d.textContent = fmt(Math.max(0, timeLeft));
      if (timeLeft <= 0) {
        clearInterval(timer); timer = null; running = false;
        $('#wo-start').textContent = 'Start';
        VictorNotify.request().then(function () { VictorNotify.show('Workout complete', { tag: 'workout' }); });
        Victor.toast('Workout finished!');
      }
    }, 1000);
  }
  function startPreset(secs) {
    timeLeft = secs;
    var h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60), s = secs % 60;
    $('#wo-h').value = h; $('#wo-m').value = m; $('#wo-s').value = s;
    document.getElementById(PAGE_ID).querySelector('#wo-timer').textContent = fmt(secs);
  }
  function renderList() {
    var box = $('#wo-list');
    var secsMap = { pushup: 60, squat: 60, plank: 60, jumpjack: 60, lunge: 60, burpee: 45, situp: 60, bridge: 60, mountain: 45, dip: 45, pistol: 60, handstand: 60 };
    box.innerHTML = EXERCISES.map(function (e) {
      var secs = secsMap[e.id] || 60;
      return '<div class="list-item"><div style="display:flex;flex-direction:column;align-items:flex-start;gap:8px;">' +
        '<div class="illustration">' + e.svg + '</div>' +
        '<div class="info" style="align-items:flex-start;"><span class="t">' + e.name + '</span><span class="s">' + e.cat + ' · ' + e.target + ' · ' + e.reps + '</span></div>' +
        '</div><div style="display:flex;flex-direction:column;gap:8px;">' +
        '<button class="btn btn-sm btn-outline" onclick="Victor.pages.' + PAGE_ID + '.startPreset(' + secs + ')">Timer ' + Math.round(secs / 60) + 'm</button>' +
        '<button class="btn btn-sm btn-ghost" onclick="Victor.pages.' + PAGE_ID + '.showDetail(\'' + e.id + '\')">Details</button>' +
        '</div></div>';
    }).join('');
  }
  function showDetail(id) {
    var e = EXERCISES.find(function (x) { return x.id === id; });
    Victor.toast(e.name + ': ' + e.reps + ' — target: ' + e.target);
  }
  Victor.register(PAGE_ID, { render: render, onShow: onShow, startPreset: startPreset, showDetail: showDetail, label: 'Workouts' }, { icon: '💪', label: 'Workouts' });
})();
