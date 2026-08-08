/* SAT_DEV_ENGLISH_DISPLAY_NAME_V5 */
(() => {
  'use strict';
  if (window.__SAT_ENGLISH_DISPLAY_NAME_V5__) return;
  window.__SAT_ENGLISH_DISPLAY_NAME_V5__ = true;

  // Display-only mapping. This never changes localStorage, sessionStorage,
  // progress IDs, URLs, API payloads, or authentication tokens.
  const DISPLAY_NAMES = Object.freeze({
    kanni: 'Velangini'
  });

  let applying = false;

  function clean(value) {
    return String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
  }

  function internalId() {
    try {
      const value = clean(localStorage.getItem('sat_user'));
      if (value) return value.toLowerCase();
    } catch (_) {}

    try {
      if (typeof window.getUser === 'function') {
        const value = clean(window.getUser());
        if (value) return value.toLowerCase();
      }
    } catch (_) {}

    return '';
  }

  function replaceStudentText(root, id, name) {
    let changed = 0;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);

    const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const exact = new RegExp('^\\s*' + escaped + '\\s*$', 'i');
    const prefixed = new RegExp('(Student\\s*:\\s*)' + escaped + '\\b', 'i');

    for (const node of nodes) {
      const parent = node.parentElement;
      if (!parent || parent.closest('script, style, textarea, input, [contenteditable="true"]')) continue;
      const value = node.nodeValue || '';
      let next = value;

      // Replace an exact target value, or the visible "Student: kanni" label.
      if (exact.test(value)) next = value.replace(exact, name);
      else if (prefixed.test(value)) next = value.replace(prefixed, '$1' + name);

      if (next !== value) {
        node.nodeValue = next;
        changed += 1;
      }
    }
    return changed;
  }

  function apply() {
    if (applying || !document.body) return;
    const id = internalId();
    const name = DISPLAY_NAMES[id];
    if (!name) {
      document.documentElement.dataset.englishDisplayNameSync = 'unmapped-' + (id || 'empty');
      return;
    }

    applying = true;
    try {
      let changed = 0;
      const selectors = [
        '#student-display-name',
        '[data-student-display-name]',
        '[data-sat-display-name]',
        '[data-student-name]'
      ];

      for (const selector of selectors) {
        document.querySelectorAll(selector).forEach(element => {
          const value = clean(element.textContent);
          if (value.toLowerCase() === id || /^student\s*:/i.test(value)) {
            element.textContent = /^student\s*:/i.test(value) ? 'Student: ' + name : name;
            changed += 1;
          }
        });
      }

      changed += replaceStudentText(document.body, id, name);
      document.documentElement.dataset.englishDisplayNameSync =
        changed > 0 || document.body.textContent.includes(name) ? 'resolved-v5' : 'target-not-found';
    } finally {
      applying = false;
    }
  }

  function start() {
    console.info('[English display V5] loaded; internal progress ID remains unchanged.');
    apply();
    new MutationObserver(apply).observe(document.body, {
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
