(() => {
  'use strict';

  function normalizeStudentId(value) {
    const normalized = String(value || '').trim().toLowerCase();
    return /^[a-z0-9_-]{1,80}$/.test(normalized)
      ? normalized
      : '';
  }

  /*
   * Backward compatibility:
   * If an old administrator-created link contains ?student=..., remember
   * the student locally before removing the parameter.
   */
  const currentUrl = new URL(window.location.href);

  const studentFromUrl = normalizeStudentId(
    currentUrl.searchParams.get('student')
  );

  if (studentFromUrl) {
    window.localStorage.setItem('sat_user', studentFromUrl);
  }

  /*
   * Cognito login already stores sat_user. The student query parameter is
   * no longer needed and should not remain visible in the address bar.
   */
  if (currentUrl.searchParams.has('student')) {
    currentUrl.searchParams.delete('student');

    window.history.replaceState(
      null,
      '',
      `${currentUrl.pathname}${currentUrl.search}${currentUrl.hash}`
    );
  }

  function cleanStudentParametersFromLinks(root = document) {
    root.querySelectorAll('a[href]').forEach((anchor) => {
      const rawHref = anchor.getAttribute('href');

      if (
        !rawHref ||
        rawHref.startsWith('#') ||
        rawHref.startsWith('mailto:') ||
        rawHref.startsWith('tel:') ||
        rawHref.startsWith('javascript:')
      ) {
        return;
      }

      try {
        const url = new URL(rawHref, window.location.href);

        // Do not modify external links.
        if (url.origin !== window.location.origin) {
          return;
        }

        if (!url.searchParams.has('student')) {
          return;
        }

        url.searchParams.delete('student');

        anchor.href =
          `${url.pathname}${url.search}${url.hash}`;
      } catch (error) {
        console.warn('Unable to clean SAT navigation link', rawHref, error);
      }
    });
  }

  function initializeCleanNavigation() {
    cleanStudentParametersFromLinks();

    /*
     * Some Math and English pages construct navigation dynamically.
     * Clean those links whenever new elements are added.
     */
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        for (const node of mutation.addedNodes) {
          if (!(node instanceof Element)) {
            continue;
          }

          if (node.matches?.('a[href]')) {
            cleanStudentParametersFromLinks(node.parentElement || document);
          } else {
            cleanStudentParametersFromLinks(node);
          }
        }
      }
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener(
      'DOMContentLoaded',
      initializeCleanNavigation,
      { once: true }
    );
  } else {
    initializeCleanNavigation();
  }
})();
