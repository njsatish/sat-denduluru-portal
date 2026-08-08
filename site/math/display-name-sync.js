/* SAT_DEV_MATH_DISPLAY_SYNC_V6 */
(() => {
  'use strict';
  if (window.__SAT_MATH_DISPLAY_SYNC_V6__) return;
  window.__SAT_MATH_DISPLAY_SYNC_V6__ = true;

  const TAG = '[Math display V6]';
  const TARGET_SELECTORS = [
    '#student-display-name',
    '[data-student-display-name]',
    '[data-sat-display-name]'
  ];
  const SOURCE_SELECTORS = [
    '#sat-unified-global-navigation [data-sat-home-student]',
    '#sat-unified-global-navigation .student-name strong',
    '#sat-unified-global-navigation .sat-home-student strong',
    '#sat-unified-global-navigation [data-student-name]',
    'header [data-auth-display-name]',
    'header [data-display-name]'
  ];
  const PLACEHOLDERS = new Set([
    '', 'student', 'loading', 'loading...', 'undefined', 'null', 'guest', 'user'
  ]);
  let resolvedName = '';
  let applying = false;
  let lastDiagnostic = '';

  const clean = value => {
    const result = String(value ?? '').replace(/\s+/g, ' ').trim();
    return PLACEHOLDERS.has(result.toLowerCase()) ? '' : result;
  };

  function decodeJwt(value) {
    try {
      const token = clean(value);
      const part = token.split('.')[1];
      if (!part) return null;
      const normalized = part.replace(/-/g, '+').replace(/_/g, '/');
      const padded = normalized + '='.repeat((4 - normalized.length % 4) % 4);
      const bytes = Uint8Array.from(atob(padded), c => c.charCodeAt(0));
      return JSON.parse(new TextDecoder().decode(bytes));
    } catch (_) { return null; }
  }

  function directName(obj) {
    if (!obj || typeof obj !== 'object') return '';
    const full = clean(
      obj.name || obj.display_name || obj.displayName || obj.preferred_username ||
      obj['custom:display_name'] || obj['custom:displayName'] ||
      obj['custom:student_name'] || obj['custom:studentName']
    );
    if (full) return full;
    const given = clean(obj.given_name || obj.givenName || obj['custom:given_name']);
    const family = clean(obj.family_name || obj.familyName || obj['custom:family_name']);
    return clean([given, family].filter(Boolean).join(' '));
  }

  function deepName(value, seen = new Set(), depth = 0) {
    if (depth > 8 || value == null) return '';
    if (typeof value === 'string') {
      const fromJwt = directName(decodeJwt(value));
      if (fromJwt) return fromJwt;
      try { return deepName(JSON.parse(value), seen, depth + 1); } catch (_) { return ''; }
    }
    if (typeof value !== 'object' || seen.has(value)) return '';
    seen.add(value);
    const own = directName(value);
    if (own) return own;
    for (const key of Object.keys(value)) {
      const found = deepName(value[key], seen, depth + 1);
      if (found) return found;
    }
    return '';
  }

  function storageName(storage) {
    try {
      const prioritized = [];
      const remaining = [];
      for (let i = 0; i < storage.length; i += 1) {
        const key = storage.key(i);
        if (!key) continue;
        const item = [key, storage.getItem(key)];
        (/idtoken|id_token|claims|profile|attribute|session|cognito|amplify/i.test(key)
          ? prioritized : remaining).push(item);
      }
      for (const [, raw] of [...prioritized, ...remaining]) {
        const found = deepName(raw);
        if (found) return found;
      }
    } catch (_) {}
    return '';
  }

  function renderedName() {
    for (const selector of SOURCE_SELECTORS) {
      for (const element of document.querySelectorAll(selector)) {
        const found = clean(element.textContent);
        if (found && element.id !== 'student-display-name') return found;
      }
    }
    return '';
  }

  async function authName() {
    const calls = [
      [window.SATAuth, 'getSession'],
      [window.SATAuth, 'getCurrentUser'],
      [window.SATAuth, 'currentUser'],
      [window.Auth, 'currentAuthenticatedUser'],
      [window.Amplify?.Auth, 'currentAuthenticatedUser'],
      [window.Amplify?.Auth, 'currentSession']
    ];
    for (const [owner, method] of calls) {
      try {
        if (owner && typeof owner[method] === 'function') {
          const found = deepName(await owner[method]());
          if (found) return found;
        }
      } catch (_) {}
    }
    return '';
  }

  function targets() {
    const found = new Set();
    for (const selector of TARGET_SELECTORS) {
      document.querySelectorAll(selector).forEach(node => found.add(node));
    }
    return [...found];
  }

  function apply() {
    if (!resolvedName || applying) return;
    applying = true;
    try {
      const nodes = targets();
      for (const node of nodes) {
        if (clean(node.textContent) !== resolvedName) node.textContent = resolvedName;
        node.hidden = false;
        node.removeAttribute('aria-hidden');
      }
      if (nodes.length) {
        document.documentElement.dataset.mathDisplayNameSync = 'resolved';
      }
    } finally { applying = false; }
  }

  async function refresh() {
    const sources = {
      auth: await authName(),
      sessionStorage: storageName(sessionStorage),
      localStorage: storageName(localStorage),
      rendered: renderedName()
    };
    const found = sources.auth || sources.sessionStorage || sources.localStorage || sources.rendered;
    if (found) {
      if (found !== resolvedName) console.info(TAG, 'resolved authenticated display name');
      resolvedName = found;
      apply();
    } else {
      const diagnostic = JSON.stringify({
        SATAuth: Boolean(window.SATAuth),
        AmplifyAuth: Boolean(window.Amplify?.Auth),
        targets: targets().length,
        storageKeys: {
          session: sessionStorage.length,
          local: localStorage.length
        }
      });
      if (diagnostic !== lastDiagnostic) {
        lastDiagnostic = diagnostic;
        console.warn(TAG, 'no display-name claim found', JSON.parse(diagnostic));
      }
      document.documentElement.dataset.mathDisplayNameSync = 'name-not-found';
    }
  }

  function start() {
    console.info(TAG, 'loaded');
    new MutationObserver(() => {
      apply();
      if (!resolvedName) void refresh();
    }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });

    void refresh();
    let count = 0;
    const timer = setInterval(() => {
      count += 1;
      void refresh();
      if (count >= 240) clearInterval(timer);
    }, 500);
    for (const event of ['focus', 'pageshow', 'storage']) window.addEventListener(event, refresh);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) void refresh(); });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }
})();
