/* SAT_DEV_MATH_DISPLAY_SYNC_V7 */
(() => {
  'use strict';
  if (window.__SAT_MATH_DISPLAY_SYNC_V7__) return;
  window.__SAT_MATH_DISPLAY_SYNC_V7__ = true;

  // Visible-name mapping only. Keys are internal IDs; values are display names.
  const DISPLAY_NAMES = Object.freeze({
    kanni: 'Velangini'
  });

  const TARGETS = [
    '#student-display-name',
    '[data-student-display-name]',
    '[data-sat-display-name]'
  ];
  let applying = false;

  function clean(value) {
    return String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
  }

  function internalId() {
    try {
      const stored = clean(localStorage.getItem('sat_user'));
      if (stored) return stored.toLowerCase();
    } catch (_) {}

    try {
      if (typeof window.getUser === 'function') {
        const value = clean(window.getUser());
        if (value) return value.toLowerCase();
      }
    } catch (_) {}

    try {
      return clean(new URLSearchParams(location.search).get('student')).toLowerCase();
    } catch (_) {
      return '';
    }
  }

  function apply() {
    if (applying) return;
    const id = internalId();
    const name = DISPLAY_NAMES[id];
    if (!name) {
      document.documentElement.dataset.mathDisplayNameSync = 'unmapped-' + (id || 'empty');
      return;
    }

    applying = true;
    try {
      let count = 0;
      for (const selector of TARGETS) {
        document.querySelectorAll(selector).forEach(element => {
          count += 1;
          if (clean(element.textContent) !== name) element.textContent = name;
          element.hidden = false;
          element.removeAttribute('aria-hidden');
        });
      }
      document.documentElement.dataset.mathDisplayNameSync = count ? 'resolved-v7' : 'target-not-found';
    } finally {
      applying = false;
    }
  }

  function start() {
    console.info('[Math display V7] loaded; internal progress ID is unchanged.');
    apply();
    new MutationObserver(apply).observe(document.documentElement, {
      childList: true,
      subtree: true,
      characterData: true
    });
    setInterval(apply, 500);
    window.addEventListener('pageshow', apply);
    window.addEventListener('focus', apply);
    window.addEventListener('storage', apply);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }
})();
