(function () {
  const ST = VictorStorage;
  const PAGE_ID = 'page-bible';
  const INTERVAL = 10 * 60 * 1000;
  const VERSES = [
    { ref: 'Jeremiah 29:11', text: '"For I know the plans I have for you," declares the Lord, "plans to prosper you and not to harm you, plans to give you hope and a future."' },
    { ref: 'Philippians 4:13', text: 'I can do all things through Christ who strengthens me.' },
    { ref: 'Psalm 23:1', text: 'The Lord is my shepherd; I shall not want.' },
    { ref: 'Proverbs 3:5-6', text: 'Trust in the Lord with all your heart and lean not on your own understanding; in all your ways submit to Him, and He will make your paths straight.' },
    { ref: 'Romans 8:28', text: 'And we know that in all things God works for the good of those who love Him, who have been called according to His purpose.' },
    { ref: 'Joshua 1:9', text: 'Be strong and courageous. Do not be afraid; do not be discouraged, for the Lord your God will be with you wherever you go.' },
    { ref: 'Matthew 6:33', text: 'But seek first His kingdom and His righteousness, and all these things will be given to you as well.' },
    { ref: 'Isaiah 40:31', text: 'But those who hope in the Lord will renew their strength. They will soar on wings like eagles.' },
    { ref: 'Psalm 46:1', text: 'God is our refuge and strength, an ever-present help in trouble.' },
    { ref: 'John 3:16', text: 'For God so loved the world that He gave His one and only Son, that whoever believes in Him shall not perish but have eternal life.' },
    { ref: 'Ephesians 2:8-9', text: 'For it is by grace you have been saved, through faith — and this is not from yourselves, it is the gift of God.' },
    { ref: 'Psalm 119:105', text: 'Your word is a lamp for my feet, a light on my path.' },
    { ref: '1 Peter 5:7', text: 'Cast all your anxiety on Him because He cares for you.' },
    { ref: 'Colossians 3:23', text: 'Whatever you do, work at it with all your heart, as working for the Lord, not for human masters.' },
    { ref: 'Psalm 37:4', text: 'Take delight in the Lord, and He will give you the desires of your heart.' },
    { ref: 'Matthew 11:28', text: 'Come to me, all you who are weary and burdened, and I will give you rest.' },
    { ref: 'Romans 12:2', text: 'Do not conform to the pattern of this world, but be transformed by the renewing of your mind.' },
    { ref: 'Galatians 5:22-23', text: 'The fruit of the Spirit is love, joy, peace, patience, kindness, goodness, faithfulness, gentleness and self-control.' },
    { ref: '2 Timothy 1:7', text: 'For the Spirit God gave us does not make us timid, but gives us power, love and self-discipline.' },
    { ref: 'Hebrews 13:5', text: 'Never will I leave you; never will I forsake you.' },
    { ref: 'Psalm 121:1-2', text: 'I lift up my eyes to the mountains — where does my help come from? My help comes from the Lord.' },
    { ref: 'John 14:27', text: 'Peace I leave with you; My peace I give you. I do not give to you as the world gives.' },
    { ref: 'James 1:5', text: 'If any of you lacks wisdom, you should ask God, who gives generously to all without finding fault.' },
    { ref: '1 Corinthians 16:14', text: 'Do everything in love.' },
  ];
  function pickVerse() {
    var b = ST.get('victor-bible');
    var v = VERSES[b.verseIndex % VERSES.length];
    b.verseIndex = (b.verseIndex + 1) % VERSES.length;
    b.lastVerse = v;
    b.nextAt = Date.now() + INTERVAL;
    ST.set('victor-bible', b);
    return v;
  }
  function render() {
    var b = ST.get('victor-bible');
    var due = b.nextAt && Date.now() >= b.nextAt;
    return '<div class="section"><div class="card" style="text-align:center;background:#fdf7ec;border-color:#ffe5b4;">' +
      '<div style="font-size:13px;font-weight:700;color:#9a6200;text-transform:uppercase;letter-spacing:0.05em;margin-bottom:10px;">Verse of the moment</div>' +
      '<div style="font-size:19px;font-weight:600;color:#4d3400;line-height:1.5;margin-bottom:10px;">' + (b.lastVerse ? b.lastVerse.text : '"Draw near to God, and He will draw near to you." — James 4:8') + '</div>' +
      '<div style="font-size:15px;color:#9a6200;">' + (b.lastVerse ? b.lastVerse.ref : 'James 4:8') + '</div>' +
      '</div></div>' +
      '<div class="section"><div class="row"><div style="flex:1;"><h2 class="section-title">Daily reminders</h2>' +
      '<p style="color:var(--text-secondary);font-size:14px;">Receive a random Bible verse as a notification every 10 minutes, non-stop.</p>' +
      '</div><label class="switch" style="margin-left:10px;"><input type="checkbox" id="bi-toggle" ' + (b.enabled ? 'checked' : '') + '><span class="slider"></span></label></div>' +
      '<div class="timer-controls" style="margin-top:14px;justify-content:center;"><button class="btn" id="bi-now">Get a verse now</button></div>' +
      '<p id="bi-next" style="margin:10px 0 0 0;text-align:center;font-size:14px;color:var(--text-secondary);">' + (due ? 'A new verse is ready now.' : 'Next verse in ' + Math.ceil((b.nextAt - Date.now()) / 60000) + ' minutes') + '</p>' +
      '</div>' +
      '<div class="section"><h2 class="section-title">Your verses</h2>' +
      '<div class="empty"><span class="emoji">❤️</span><h3>Your verses appear here</h3><p>Each notification saves the verse so you can reflect on it later.</p></div>' +
      '</div>';
  }
  function onShow() {
    var el = document.getElementById(PAGE_ID);
    el.innerHTML = render();
    var toggle = $('#bi-toggle');
    var b = ST.get('victor-bible');
    toggle.checked = b.enabled;
    toggle.onchange = async function (e) {
      b.enabled = e.target.checked;
      ST.set('victor-bible', b);
      if (b.enabled) {
        var ok = await VictorNotify.request();
        if (!ok) { toggle.checked = false; b.enabled = false; ST.set('victor-bible', b); Victor.toast('Notifications not allowed'); return; }
        b.nextAt = Date.now() + INTERVAL;
        ST.set('victor-bible', b);
        Victor.toast('Verse reminders on — every 10 minutes');
      } else {
        Victor.toast('Verse reminders off');
      }
      document.getElementById(PAGE_ID).innerHTML = render();
      onShow();
    };
    $('#bi-now').onclick = function () {
      var v = pickVerse();
      VictorNotify.show(v.ref, { body: v.text, tag: 'bible' });
      Victor.toast('Verse shared');
      document.getElementById(PAGE_ID).innerHTML = render();
      onShow();
    };
  }
  function tick() {
    var b = ST.get('victor-bible');
    if (!b.enabled) return;
    var due = b.nextAt && Date.now() >= b.nextAt;
    var p = document.getElementById('bi-next');
    if (p) p.textContent = due ? 'A new verse is ready now.' : 'Next verse in ' + Math.ceil(Math.max(0, b.nextAt - Date.now()) / 60000) + ' minutes';
    var el = document.getElementById(PAGE_ID);
    if (el && !el.classList.contains('active') && due) {
      var v = pickVerse();
      VictorNotify.show(v.ref, { body: v.text, tag: 'bible' });
    }
  }
  Victor.register(PAGE_ID, { render: render, onShow: onShow, tick: tick, pickVerse: pickVerse, label: 'Bible Verses' }, { icon: '📖', label: 'Bible' });
})();
