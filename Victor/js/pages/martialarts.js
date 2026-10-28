(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-martialarts';
  const BOXING = [
    { id: 'stance', name: 'Boxing stance', short: 'Feet shoulder-width, lead toe toward target, hands up guarding chin, elbows tucked.', svg: '<svg viewBox="0 0 100 100"><path d="M40 78L42 30Q42 16 58 16L60 30L62 78" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="43" cy="22" r="5" fill="#007aff"/><circle cx="59" cy="22" r="5" fill="#007aff"/><path d="M42 34L38 50L44 58" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><path d="M58 34L62 50L56 58" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/></svg>' },
    { id: 'jab', name: 'The jab', short: 'Quick straight punch with your lead hand. Snap it out and snap it back to guard.', svg: '<svg viewBox="0 0 100 100"><path d="M30 62L30 34Q30 20 50 20L78 28" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="30" cy="26" r="5" fill="#007aff"/><path d="M30 38L38 46L32 54" fill="none" stroke="#86868d" stroke-width="3" stroke-linecap="round"/></svg>' },
    { id: 'cross', name: 'The cross', short: 'Power straight punch with your rear hand, rotating your hips and shoulders into it.', svg: '<svg viewBox="0 0 100 100"><path d="M70 62L70 34Q70 20 50 20L22 28" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="70" cy="26" r="5" fill="#007aff"/><path d="M70 38L62 46L68 54" fill="none" stroke="#86868d" stroke-width="3" stroke-linecap="round"/></svg>' },
    { id: 'hook', name: 'The hook', short: "Bent-arm punch coming from the side, aiming at the opponent's head or body.", svg: '<svg viewBox="0 0 100 100"><path d="M20 48Q60 48 60 20" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="20" cy="48" r="5" fill="#007aff"/><circle cx="60" cy="20" r="5" fill="#007aff"/><path d="M20 54L30 62L24 70" fill="none" stroke="#86868d" stroke-width="3" stroke-linecap="round"/></svg>' },
    { id: 'uppercut', name: 'The uppercut', short: 'Vertical punch traveling upward from your waist, aimed at the chin.', svg: '<svg viewBox="0 0 100 100"><path d="M50 78Q50 42 70 40" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><circle cx="50" cy="78" r="5" fill="#007aff"/><circle cx="70" cy="40" r="5" fill="#007aff"/><path d="M50 82L46 96" fill="none" stroke="#86868d" stroke-width="3" stroke-linecap="round"/></svg>' },
    { id: 'footwork', name: 'Footwork', short: 'Lead foot first when moving forward, rear foot first when moving back — never cross your feet.', svg: '<svg viewBox="0 0 100 100"><path d="M25 72L45 72 M55 72 L75 72" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><path d="M45 72L60 56" fill="none" stroke="#007aff" stroke-width="3" stroke-linecap="round"/><path d="M55 72L40 56" fill="none" stroke="#007aff" stroke-width="3" stroke-linecap="round"/><circle cx="35" cy="72" r="4" fill="#007aff"/><circle cx="65" cy="72" r="4" fill="#007aff"/></svg>' },
    { id: 'guard', name: 'High guard', short: 'Gloves at cheek level, elbows tight to ribs, chin tucked down — your default defensive position.', svg: '<svg viewBox="0 0 100 100"><path d="M40 40L40 70Q40 80 50 80L60 80Q70 80 70 70L70 40" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="42" cy="32" r="5" fill="#007aff"/><circle cx="68" cy="32" r="5" fill="#007aff"/></svg>' },
    { id: 'slip', name: 'The slip', short: 'Move your head off the centerline as a punch comes in, rotating at the waist.', svg: '<svg viewBox="0 0 100 100"><path d="M40 34Q40 60 50 60Q60 60 60 34" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><path d="M30 40Q50 60 70 40" fill="none" stroke="#86868d" stroke-width="3" stroke-linecap="round"/><circle cx="45" cy="50" r="5" fill="#007aff"/></svg>' },
  ];
  const JIUJITSU = [
    { id: 'shrimp', name: 'Shrimping (hip escape)', short: 'The foundation movement of BJJ — use your feet and shoulder to create space and move your hips away.', svg: '<svg viewBox="0 0 100 100"><path d="M30 70Q30 40 60 40T90 70" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><path d="M40 40L52 40L52 60L40 60Z" fill="#86868d"/><circle cx="30" cy="70" r="5" fill="#007aff"/><circle cx="90" cy="70" r="5" fill="#007aff"/></svg>' },
    { id: 'breakfall', name: 'Breakfall', short: 'Slap the mat with your arm at 45°, exhale, and distribute the impact so you land safely.', svg: '<svg viewBox="0 0 100 100"><path d="M20 74Q40 50 60 74T100 74" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><path d="M60 58L60 74" fill="none" stroke="#86868d" stroke-width="4" stroke-linecap="round"/><circle cx="60" cy="50" r="5" fill="#007aff"/></svg>' },
    { id: 'guard', name: 'Closed guard', short: "Wrap your legs around your opponent's waist and control their posture — your safety position on the back.", svg: '<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="22" fill="none" stroke="#007aff" stroke-width="5"/><path d="M50 28Q30 40 50 52Q70 40 50 28" fill="none" stroke="#86868d" stroke-width="4" stroke-linecap="round"/><circle cx="50" cy="32" r="5" fill="#86868d"/></svg>' },
    { id: 'mount', name: 'Mount position', short: 'Sit on your opponent\'s torso, knees in their armpits — a dominant position for striking and submissions.', svg: '<svg viewBox="0 0 100 100"><path d="M30 46Q50 46 50 20Q50 46 70 46" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><path d="M42 52L58 52Q50 62 50 62" fill="none" stroke="#007aff" stroke-width="4" stroke-linecap="round"/><circle cx="50" cy="28" r="5" fill="#007aff"/></svg>' },
    { id: 'side', name: 'Side control', short: 'Pin your opponent across their chest, controlling their far shoulder and hip so they cannot escape.', svg: '<svg viewBox="0 0 100 100"><path d="M30 58L70 58L70 44Q50 44 30 58Z" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><path d="M30 64L70 64" fill="none" stroke="#86868d" stroke-width="4" stroke-linecap="round"/><circle cx="40" cy="50" r="5" fill="#86868d"/><circle cx="60" cy="50" r="5" fill="#007aff"/></svg>' },
    { id: 'armbar', name: 'Armbar', short: 'Isolate an arm, trap it between your legs, and extend their elbow against your hips.', svg: '<svg viewBox="0 0 100 100"><path d="M35 50L65 50Q85 50 85 30" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><path d="M65 50L65 66L55 66Z" fill="none" stroke="#86868d" stroke-width="4" stroke-linecap="round"/><circle cx="35" cy="50" r="5" fill="#86868d"/><circle cx="65" cy="50" r="5" fill="#007aff"/></svg>' },
    { id: 'triangle', name: 'Triangle choke', short: 'Trap their head and one arm between your thighs and squeeze — a blood choke from your back.', svg: '<svg viewBox="0 0 100 100"><path d="M40 80L60 80L50 30Z" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><path d="M45 62L55 62Q50 54 50 54" fill="none" stroke="#86868d" stroke-width="4" stroke-linecap="round"/><circle cx="50" cy="38" r="5" fill="#86868d"/></svg>' },
    { id: 'rnc', name: 'Rear naked choke', short: 'From behind, slide one arm around the neck, grip your own biceps, and squeeze.', svg: '<svg viewBox="0 0 100 100"><path d="M30 42Q30 60 50 60T70 42" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round"/><path d="M50 60L50 70L62 70Q70 70 70 56" fill="none" stroke="#86868d" stroke-width="4" stroke-linecap="round"/><circle cx="50" cy="42" r="5" fill="#86868d"/><circle cx="70" cy="42" r="5" fill="#007aff"/></svg>' },
    { id: 'kimura', name: 'Kimura', short: 'Figure-four grip on the shoulder — rotate their arm behind their back to apply pressure.', svg: '<svg viewBox="0 0 100 100"><path d="M30 58L30 36Q50 36 50 20" fill="none" stroke="#007aff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><path d="M30 62L42 62Q50 54 50 20" fill="none" stroke="#86868d" stroke-width="4" stroke-linecap="round"/><circle cx="30" cy="48" r="5" fill="#86868d"/><circle cx="50" cy="28" r="5" fill="#007aff"/></svg>' },
  ];
  const TABS = [{ key: 'boxing', label: 'Boxing', list: BOXING }, { key: 'jiujitsu', label: 'Jiu Jitsu', list: JIUJITSU }];
  function render() {
    var st = ST.get('victor-martialarts');
    var activeTab = st.tab || 'boxing';
    var t = TABS.find(function (x) { return x.key === activeTab; }) || TABS[0];
    var chips = TABS.map(function (x) {
      return '<span class="chip ' + (x.key === activeTab ? 'active' : '') + '" onclick="Victor.pages.' + PAGE_ID + ".pickTab('" + x.key + "')\">" + x.label + '</span>';
    }).join('');
    return '<div class="section"><div class="chips" style="margin-bottom:14px;">' + chips + '</div><div id="ma-list" class="list"></div></div>';
  }
  function pickTab(key) {
    ST.update('victor-martialarts', { tab: key });
    onShow();
  }
  function onShow() {
    var el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    var st = ST.get('victor-martialarts');
    var t = TABS.find(function (x) { return x.key === (st.tab || 'boxing'); }) || TABS[0];
    $('#ma-list').innerHTML = t.list.map(function (tech) {
      return '<div class="list-item"><div class="illustration">' + tech.svg + '</div><div class="info" style="flex:1;"><span class="t">' + tech.name + '</span><span class="s">' + tech.short + '</span></div></div>';
    }).join('');
  }
  Victor.register(PAGE_ID, { render: render, onShow: onShow, pickTab: pickTab, label: 'Martial Arts' }, { icon: '🥋', label: 'Martial Arts' });
})();
