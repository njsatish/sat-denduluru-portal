(() => {
  'use strict';

  const returnTo =
    window.location.pathname +
    window.location.search +
    window.location.hash;

  function addEnglishAccountControls(claims, username) {
    const displayName = String(
      claims?.name ||
      claims?.given_name ||
      username
    ).trim();

    function attachControls() {
      if (
        document.getElementById(
          'sat-english-account-controls'
        )
      ) {
        return;
      }

      const navigation =
        document.getElementById(
          'sat-global-navigation'
        ) ||
        document.querySelector(
          'header nav'
        ) ||
        document.querySelector(
          'nav'
        );

      if (!navigation) {
        console.warn(
          'English navigation was not found.'
        );
        return;
      }

      navigation.style.alignItems = 'center';
      navigation.style.flexWrap = 'wrap';

      const controls =
        document.createElement('div');

      controls.id =
        'sat-english-account-controls';

      controls.style.cssText = [
        'display:inline-flex',
        'align-items:center',
        'gap:12px',
        'margin-left:auto',
        'padding:4px 0',
        'white-space:nowrap'
      ].join(';');

      const student =
        document.createElement('span');

      student.id =
        'sat-english-student-name';

      student.style.cssText = [
        'font:600 15px/1.2 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
        'color:inherit'
      ].join(';');

      student.append(
        document.createTextNode(
          'Student: '
        )
      );

      const strong =
        document.createElement('strong');

      strong.textContent =
        displayName || username;

      student.appendChild(strong);

      const signOut =
        document.createElement('button');

      signOut.id =
        'sat-english-signout';

      signOut.type = 'button';
      signOut.textContent = 'Sign out';

      signOut.setAttribute(
        'aria-label',
        'Sign out of the SAT student account'
      );

      signOut.style.cssText = [
        'min-height:42px',
        'padding:0 17px',
        'border:1px solid rgba(255,255,255,.25)',
        'border-radius:12px',
        'background:rgba(255,255,255,.07)',
        'color:inherit',
        'font:700 15px/1 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
        'cursor:pointer',
        'white-space:nowrap'
      ].join(';');

      signOut.addEventListener(
        'mouseenter',
        () => {
          signOut.style.background =
            'rgba(255,255,255,.14)';
        }
      );

      signOut.addEventListener(
        'mouseleave',
        () => {
          signOut.style.background =
            'rgba(255,255,255,.07)';
        }
      );

      signOut.addEventListener(
        'click',
        () => {
          signOut.disabled = true;
          signOut.textContent =
            'Signing out…';

          /*
           * Remove only the active account pointer.
           * Do not delete locally cached question progress.
           */
          window.localStorage.removeItem(
            'sat_user'
          );

          if (window.SATAuth?.logout) {
            window.SATAuth.logout();
          } else {
            window.location.replace(
              '/login.html'
            );
          }
        }
      );

      controls.append(
        student,
        signOut
      );

      navigation.appendChild(
        controls
      );
    }

    if (
      document.readyState === 'loading'
    ) {
      document.addEventListener(
        'DOMContentLoaded',
        attachControls,
        { once: true }
      );
    } else {
      attachControls();
    }
  }

  function showPage() {
    document.documentElement.style.visibility = 'visible';

    const hidingStyle =
      document.getElementById('sat-auth-visibility');

    if (hidingStyle) {
      hidingStyle.remove();
    }
  }

  function redirectToLogin() {
    const destination =
      `/login.html?returnTo=${encodeURIComponent(returnTo)}`;

    window.location.replace(destination);
  }

  function loadScript(src, readyCheck) {
    if (readyCheck()) {
      return Promise.resolve();
    }

    return new Promise((resolve, reject) => {
      const existing =
        document.querySelector(`script[src="${src}"]`);

      if (existing) {
        existing.addEventListener('load', resolve, {
          once: true
        });

        existing.addEventListener(
          'error',
          () => reject(new Error(`Unable to load ${src}`)),
          { once: true }
        );

        return;
      }

      const script = document.createElement('script');
      script.src = src;
      script.async = false;

      script.addEventListener('load', resolve, {
        once: true
      });

      script.addEventListener(
        'error',
        () => reject(new Error(`Unable to load ${src}`)),
        { once: true }
      );

      document.head.appendChild(script);
    });
  }

  async function ensureAuthenticationLibrary() {
    await loadScript(
      '/js/auth-config.js',
      () => Boolean(window.SAT_AUTH_CONFIG)
    );

    await loadScript(
      '/js/auth.js',
      () => Boolean(window.SATAuth)
    );

    if (!window.SATAuth) {
      throw new Error(
        'SAT authentication library was not initialized.'
      );
    }
  }

  function normalizeStudentId(value) {
    const normalized =
      String(value || '').trim().toLowerCase();

    return /^[a-z0-9_-]{1,80}$/.test(normalized)
      ? normalized
      : '';
  }

  function getGroups(claims) {
    const value = claims?.['cognito:groups'];

    if (Array.isArray(value)) {
      return value;
    }

    if (!value) {
      return [];
    }

    return String(value)
      .split(',')
      .map(group => group.trim())
      .filter(Boolean);
  }

  async function protectPage() {
    try {
      await ensureAuthenticationLibrary();

      const session =
        await window.SATAuth.requireAuth();

      /*
       * requireAuth may already be redirecting the browser.
       */
      if (!session) {
        return;
      }

      const claims = session.claims || {};
      const groups = getGroups(claims);

      const username = normalizeStudentId(
        claims['cognito:username'] ||
        claims.username
      );

      const authorized =
        groups.includes('students') ||
        groups.includes('admins');

      if (!authorized || !username) {
        redirectToLogin();
        return;
      }

      /*
       * Older English pages use sat_user when saving and loading
       * progress. Keep it synchronized with the Cognito account.
       */
      window.localStorage.setItem(
        'sat_user',
        username
      );

      /*
       * Remove obsolete ?student=josh or ?student=tim parameters.
       */
      const cleanUrl =
        new URL(window.location.href);

      if (cleanUrl.searchParams.has('student')) {
        cleanUrl.searchParams.delete('student');

        window.history.replaceState(
          null,
          '',
          `${cleanUrl.pathname}${cleanUrl.search}${cleanUrl.hash}`
        );
      }

      addEnglishAccountControls(
        claims,
        username
      );

      showPage();
    } catch (error) {
      console.error(
        'English authentication failed',
        error
      );

      redirectToLogin();
    }
  }

  protectPage();
})();
