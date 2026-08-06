(() => {
  'use strict';

  const IDLE_LIMIT_MS = 15 * 60 * 1000;
  const WARNING_START_MS = 13 * 60 * 1000;
  const CHECK_INTERVAL_MS = 1000;
  const ACTIVITY_THROTTLE_MS = 3000;

  const LAST_ACTIVITY_KEY = 'sat_last_activity_at';
  const LOGOUT_EVENT_KEY = 'sat_logout_event_at';

  let lastRecordedActivity = 0;
  let warningElement = null;
  let timerId = null;
  let logoutStarted = false;

  function loadScript(src, readyCheck) {
    if (readyCheck()) {
      return Promise.resolve();
    }

    return new Promise((resolve, reject) => {
      const existing = Array.from(
        document.querySelectorAll('script[src]')
      ).find(script => {
        try {
          return new URL(script.src, location.href).pathname === src;
        } catch {
          return false;
        }
      });

      if (existing) {
        existing.addEventListener('load', resolve, { once: true });
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
      script.addEventListener('load', resolve, { once: true });
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
  }

  function readLastActivity() {
    const stored = Number(
      window.localStorage.getItem(LAST_ACTIVITY_KEY)
    );

    return Number.isFinite(stored) && stored > 0
      ? stored
      : Date.now();
  }

  function recordActivity(force = false) {
    if (logoutStarted) {
      return;
    }

    const now = Date.now();

    if (
      !force &&
      now - lastRecordedActivity < ACTIVITY_THROTTLE_MS
    ) {
      return;
    }

    lastRecordedActivity = now;

    window.localStorage.setItem(
      LAST_ACTIVITY_KEY,
      String(now)
    );

    hideWarning();
  }

  function formatRemaining(milliseconds) {
    const totalSeconds = Math.max(
      0,
      Math.ceil(milliseconds / 1000)
    );

    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;

    return `${minutes}:${String(seconds).padStart(2, '0')}`;
  }

  function createWarning() {
    if (warningElement) {
      return warningElement;
    }

    const overlay = document.createElement('div');
    overlay.id = 'sat-inactivity-warning';

    overlay.style.cssText = [
      'position:fixed',
      'inset:0',
      'z-index:2147483647',
      'display:none',
      'align-items:center',
      'justify-content:center',
      'padding:24px',
      'background:rgba(0,0,0,.70)',
      'box-sizing:border-box'
    ].join(';');

    const dialog = document.createElement('section');

    dialog.setAttribute('role', 'dialog');
    dialog.setAttribute('aria-modal', 'true');
    dialog.setAttribute(
      'aria-labelledby',
      'sat-inactivity-title'
    );

    dialog.style.cssText = [
      'width:min(500px,100%)',
      'padding:30px',
      'border:1px solid rgba(255,255,255,.20)',
      'border-radius:20px',
      'background:#1d2026',
      'color:#f8f5ed',
      'box-shadow:0 24px 70px rgba(0,0,0,.45)',
      'font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
      'text-align:center'
    ].join(';');

    dialog.innerHTML = `
      <h2
        id="sat-inactivity-title"
        style="margin:0 0 14px;font-size:28px;"
      >
        Are you still studying?
      </h2>

      <p style="margin:0 0 12px;font-size:17px;line-height:1.5;">
        Your session will end because there has been no activity.
      </p>

      <p style="margin:0 0 24px;font-size:18px;">
        Signing out in
        <strong id="sat-inactivity-countdown">2:00</strong>
      </p>

      <button
        id="sat-continue-session"
        type="button"
        style="
          min-height:48px;
          padding:0 24px;
          border:0;
          border-radius:13px;
          background:#e3b93e;
          color:#17191d;
          font:800 16px/1 system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
          cursor:pointer;
        "
      >
        Continue session
      </button>
    `;

    overlay.appendChild(dialog);
    document.body.appendChild(overlay);

    overlay
      .querySelector('#sat-continue-session')
      .addEventListener('click', () => {
        recordActivity(true);
      });

    warningElement = overlay;
    return warningElement;
  }

  function showWarning(remainingMs) {
    const warning = createWarning();

    const countdown = warning.querySelector(
      '#sat-inactivity-countdown'
    );

    if (countdown) {
      countdown.textContent =
        formatRemaining(remainingMs);
    }

    warning.style.display = 'flex';
  }

  function hideWarning() {
    if (warningElement) {
      warningElement.style.display = 'none';
    }
  }

  async function logoutForInactivity() {
    if (logoutStarted) {
      return;
    }

    logoutStarted = true;

    if (timerId) {
      window.clearInterval(timerId);
    }

    hideWarning();

    window.localStorage.removeItem('sat_user');
    window.localStorage.removeItem(LAST_ACTIVITY_KEY);

    window.localStorage.setItem(
      LOGOUT_EVENT_KEY,
      String(Date.now())
    );

    try {
      if (window.SATAuth?.logout) {
        window.SATAuth.logout();
        return;
      }
    } catch (error) {
      console.error('Automatic logout failed', error);
    }

    window.location.replace(
      '/login.html?reason=inactive'
    );
  }

  function checkInactivity() {
    if (logoutStarted) {
      return;
    }

    const elapsed = Date.now() - readLastActivity();
    const remaining = IDLE_LIMIT_MS - elapsed;

    if (remaining <= 0) {
      logoutForInactivity();
      return;
    }

    if (elapsed >= WARNING_START_MS) {
      showWarning(remaining);
    } else {
      hideWarning();
    }
  }

  function registerActivityListeners() {
    const events = [
      'pointerdown',
      'keydown',
      'touchstart',
      'scroll',
      'wheel'
    ];

    events.forEach(eventName => {
      window.addEventListener(
        eventName,
        () => recordActivity(false),
        {
          capture: true,
          passive: true
        }
      );
    });

    document.addEventListener(
      'visibilitychange',
      () => {
        if (!document.hidden) {
          checkInactivity();
        }
      }
    );

    window.addEventListener(
      'storage',
      event => {
        if (event.key === LAST_ACTIVITY_KEY) {
          hideWarning();
          checkInactivity();
        }

        if (event.key === LOGOUT_EVENT_KEY) {
          logoutForInactivity();
        }
      }
    );
  }

  async function initialize() {
    try {
      await ensureAuthenticationLibrary();

      const session = await window.SATAuth?.getSession?.();

      // Logged-out pages should not run an inactivity timer.
      if (!session) {
        return;
      }

      const existingActivity = Number(
        window.localStorage.getItem(LAST_ACTIVITY_KEY)
      );

      if (
        !Number.isFinite(existingActivity) ||
        existingActivity <= 0
      ) {
        recordActivity(true);
      }

      registerActivityListeners();
      checkInactivity();

      timerId = window.setInterval(
        checkInactivity,
        CHECK_INTERVAL_MS
      );
    } catch (error) {
      console.warn(
        'SAT inactivity timer could not be initialized',
        error
      );
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener(
      'DOMContentLoaded',
      initialize,
      { once: true }
    );
  } else {
    initialize();
  }
})();
