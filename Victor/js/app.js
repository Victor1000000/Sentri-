const Victor = (() => {
  const pages = {};        // pageId -> { render, init, onShow, onHide }
  const order = [];        // ordered page ids for the tab bar
  let current = null;
  window.$ = (sel) => document.getElementById(sel) || document.querySelector(sel);
  let alarmActivityId = null;
  let alarmInterval = null;

  const $ = (sel) => document.querySelector(sel);
  const pagesEl = $('#pages');
  const tabBar = $('#tab-bar');
  const titleEl = $('#page-title');
  const backBtn = $('#back-btn');
  const topRight = $('#top-right');
  const alarm = $('#alarm-banner');
  const alarmTitle = $('#alarm-title');
  const alarmSub = $('#alarm-sub');

  function register(pageId, def, tab) {
    pages[pageId] = def;
    if (tab) order.push({ id: pageId, ...tab });
  }

  function toast(msg, ms = 2600) {
    const t = $('#toast');
    t.textContent = msg;
    t.classList.add('show');
    setTimeout(() => t.classList.remove('show'), ms);
  }

  function showPage(pageId) {
    if (current && pages[current].onHide) pages[current].onHide();
    document.querySelectorAll('.page').forEach((p) => p.classList.remove('active'));
    current = pageId;
    const page = pages[pageId];
    let el = document.getElementById(pageId);
    if (!el) {
      el = document.createElement('section');
      el.id = pageId;
      el.className = 'page';
      pagesEl.appendChild(el);
    }
    el.classList.add('active');
    if (page.onShow) page.onShow();
    tick();
    titleEl.textContent = page.label || 'Victor';
    backBtn.classList.toggle('hidden', pageId === 'page-home');
    topRight.innerHTML = '';
    renderTabBar();
  }

  function navigate(pageId) {
    if (pages[pageId]) showPage(pageId);
  }

  function renderTabBar() {
    tabBar.innerHTML = '';
    order.forEach((t) => {
      const btn = document.createElement('button');
      btn.className = `tab ${current === t.id ? 'active' : ''} ${t.notify ? 'notify' : ''}`;
      btn.innerHTML = `<span class="tab-icon">${t.icon}</span><span class="tab-label">${t.label}</span>`;
      btn.onclick = () => showPage(t.id);
      tabBar.appendChild(btn);
    });
  }

  function setNotify(pageId, v) {
    const t = order.find((o) => o.id === pageId);
    if (t) t.notify = !!v;
    renderTabBar();
  }

  // ---------- persistent alarm ----------
  function showAlarm(title, sub, activityId) {
    alarmActivityId = activityId;
    alarmTitle.textContent = title;
    alarmSub.textContent = sub;
    alarm.classList.remove('hidden');
    setNotify('page-scheduler', true);
    if (alarmInterval) clearInterval(alarmInterval);
    alarmInterval = setInterval(() => {
      VictorNotify.show(title, { body: sub, tag: 'alarm' });
    }, 60000);
  }

  function hideAlarm() {
    alarm.classList.add('hidden');
    alarmActivityId = null;
    setNotify('page-scheduler', false);
    if (alarmInterval) { clearInterval(alarmInterval); alarmInterval = null; }
  }

  // ---------- global tick (due alarms, bible/water cadence) ----------
  function tick() {
    if (pages['page-scheduler'] && pages['page-scheduler'].checkDue) pages['page-scheduler'].checkDue(true);
    if (pages['page-bible'] && pages['page-bible'].tick) pages['page-bible'].tick();
    if (pages['page-water'] && pages['page-water'].tick) pages['page-water'].tick();
  }

  function init() {
    $('#back-btn').onclick = () => showPage('page-home');
    $('#alarm-started').onclick = () => {
      if (alarmActivityId) {
        const sched = VictorStorage.get('victor-scheduler');
        const item = sched.find((a) => a.id === alarmActivityId);
        if (item && !item.started) { item.started = true; VictorStorage.set('victor-scheduler', sched); }
      }
      hideAlarm(); toast('Great — keep going!');
    };
    $('#alarm-snooze').onclick = () => {
      const id = alarmActivityId;
      hideAlarm();
      if (id) {
        const sched = VictorStorage.get('victor-scheduler');
        const item = sched.find((a) => a.id === id);
        if (item) { item.snoozeUntil = Date.now() + 5 * 60 * 1000; VictorStorage.set('victor-scheduler', sched); }
      }
      toast('I will remind you again in 5 minutes.');
    };
    document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); });
    setInterval(tick, 30000);
    tick();
    showPage('page-home');
  }

  return { register, showPage, navigate, toast, init, showAlarm, hideAlarm, tick, setNotify, alarmActive: () => alarmActivityId != null, pages: pages };
})();