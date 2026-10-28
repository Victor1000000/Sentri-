const VictorNotify = (() => {
  let granted = Notification.permission === 'granted';
  async function request() {
    if (!('Notification' in window)) return false;
    if (granted) return true;
    const r = await Notification.requestPermission();
    granted = r === 'granted';
    return granted;
  }
  function show(title, options = {}) {
    if (!granted) return null;
    const n = new Notification(title, {
      icon: 'data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 32 32%22%3E%3Crect width=%2232%22 height=%2232%22 rx=%228%22 fill=%22%23007aff%22/%3E%3Ctext x=%2216%22 y=%2223%22 font-family=%22system-ui%22 font-weight=%22700%22 font-size=%2220%22 text-anchor=%22middle%22 fill=%22%23fff%22/%3EV%3C/text%3E%3C/svg%3E',
      badge: 'data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 32 32%22%3E%3Crect width=%2232%22 height=%2232%22 rx=%228%22 fill=%22%23007aff%22/%3E%3Ctext x=%2216%22 y=%2223%22 font-family=%22system-ui%22 font-weight=%22700%22 font-size=%2220%22 text-anchor=%22middle%22 fill=%22%23fff%22/%3EV%3C/text%3E%3C/svg%3E',
      ...options,
    });
    setTimeout(() => { try { n.close(); } catch (e) {} }, 7000);
    return n;
  }
  return { request, show, granted: () => granted, setGranted: (v) => { granted = v; } };
})();