const VictorStorage = (() => {
  const DEFAULTS = {
    'victor-screentime': { limitMinutes: 30, sessions: [], daily: {}, active: null },
    'victor-workouts': [],
    'victor-martialarts': [],
    'victor-bible': { enabled: false, lastVerse: null, verseIndex: 0, nextAt: 0 },
    'victor-scheduler': [],
    'victor-water': { goal: 8, intake: [], daily: {}, lastReminder: 0 },
    'victor-sleep': { logs: [] },
    'victor-heartrate': { readings: [] },
    'victor-habits': [],
    'victor-focus': { sessions: 0 },
    'victor-journal': [],
  };
  function clone(def) { return JSON.parse(JSON.stringify(def)); }
  function get(key) {
    try {
      const raw = localStorage.getItem(key);
      if (raw === null || raw === undefined) return clone(DEFAULTS[key] || null);
      const parsed = JSON.parse(raw);
      return parsed === null || parsed === undefined ? clone(DEFAULTS[key] || null) : parsed;
    } catch (e) { return clone(DEFAULTS[key] || null); }
  }
  function set(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) {}
    return value;
  }
  function update(key, patch) {
    const cur = get(key);
    const next = { ...cur, ...patch };
    return set(key, next);
  }
  function push(key, item) {
    const arr = get(key);
    arr.push(item);
    return set(key, arr);
  }
  return { get, set, update, push };
})();