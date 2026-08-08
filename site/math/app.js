
// BEGIN HIDE_DUPLICATE_TOPIC_FILTER_AND_PRINT
const SAT_HIDE_TOPIC_PRINT_BUILD = '20260802-hide-topic-print-20260802T003943Z';

(function hideDuplicateTopicFilterAndPrint() {
  const STYLE_ID = 'sat-hide-topic-print-style';

  function normalizeText(element) {
    return String(element?.textContent || '')
      .replace(/\s+/g, ' ')
      .trim()
      .toLowerCase();
  }

  function installStyle() {
    if (document.getElementById(STYLE_ID)) return;

    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = `
      #print-page {
        display: none !important;
      }
    `;

    document.head.appendChild(style);
  }

  function hidePrintButton() {
    const printButton =
      document.getElementById('print-page');

    if (printButton) {
      printButton.hidden = true;
      printButton.style.display = 'none';
    }
  }

  function findTopicChipStrip() {
    const allTopicsButton = [
      ...document.querySelectorAll(
        'button, a, [role="button"]'
      )
    ].find(
      element =>
        normalizeText(element) === 'all topics'
    );

    if (!allTopicsButton) return null;

    let candidate = allTopicsButton.parentElement;

    for (
      let depth = 0;
      candidate && depth < 4;
      depth += 1
    ) {
      const controls = [
        ...candidate.querySelectorAll(
          'button, a, [role="button"]'
        )
      ];

      const labels = controls.map(normalizeText);

      const topicLabels = labels.filter(label =>
        label === 'all topics' ||
        label.includes('equation') ||
        label.includes('function') ||
        label.includes('system') ||
        label.includes('geometry') ||
        label.includes('data') ||
        label.includes('algebra') ||
        label.includes('trigonometry')
      );

      if (
        labels.includes('all topics') &&
        controls.length >= 3 &&
        topicLabels.length >= 3
      ) {
        return candidate;
      }

      candidate = candidate.parentElement;
    }

    return null;
  }

  function apply() {
    installStyle();
    hidePrintButton();

    const strip = findTopicChipStrip();

    if (strip) {
      strip.hidden = true;
      strip.style.display = 'none';
      strip.setAttribute(
        'data-sat-hidden-duplicate-topic-strip',
        'true'
      );
    }
  }

  function start() {
    apply();

    const observer = new MutationObserver(apply);

    observer.observe(document.documentElement, {
      childList: true,
      subtree: true
    });

    window.setTimeout(() => {
      apply();
      observer.disconnect();
    }, 12000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener(
      'DOMContentLoaded',
      start,
      { once: true }
    );
  } else {
    start();
  }
})();
// END HIDE_DUPLICATE_TOPIC_FILTER_AND_PRINT

const SAT_RETRY_UI_BUILD = '20260801-retry-v8-20260801T224750Z';
const SAT_CORRECTION_BUILD = '20260801-20260801T222712Z';
const STORAGE_KEY = 'satMath300Progress';
const QUIZ_LENGTH = 10;
const PROGRESS_API = "https://qi7mrsjuu5jj4nsmiukcprtvya0scnrg.lambda-url.us-east-1.on.aws/";

let currentStudentId = '';

class ApiError extends Error {
  constructor(message, status, code) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
  }
}

function normalizeStudentId(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return /^[a-z0-9_-]{1,80}$/.test(normalized) ? normalized : '';
}

/* BEGIN SAT MATH IDENTITY V13 */
const SAT_MATH_IDENTITY_BUILD = '20260805-math-progress-v13-20260806T013611Z';

function decodeSatMathTokenV12(token) {
  try {
    const part = String(token || '').split('.')[1];
    if (!part) return null;
    const base64 = part.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64 + '='.repeat((4 - base64.length % 4) % 4);
    const binary = atob(padded);
    const bytes = Uint8Array.from(
      binary,
      character => character.charCodeAt(0)
    );
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch (error) {
    console.warn('Unable to decode SAT Math identity.', error);
    return null;
  }
}

function resolveMathStudentId(primaryStudentId = '') {
  const params = new URLSearchParams(location.search);
  const tokenClaims = decodeSatMathTokenV12(
    sessionStorage.getItem('sat_id_token') ||
    localStorage.getItem('sat_id_token')
  );

  const primary = normalizeStudentId(primaryStudentId);
  const authenticated = normalizeStudentId(
    window.SATAuth?.studentId ||
    window.SATAuth?.username ||
    tokenClaims?.['cognito:username'] ||
    tokenClaims?.username ||
    tokenClaims?.preferred_username
  );
  const fromUrl = normalizeStudentId(params.get('student'));
  const stored = normalizeStudentId(localStorage.getItem('sat_user'));
  const studentId = primary || authenticated || fromUrl || stored;

  if (studentId) localStorage.setItem('sat_user', studentId);
  return studentId;
}
/* END SAT MATH IDENTITY V13 */

function getUser() {
  return currentStudentId || normalizeStudentId(localStorage.getItem('sat_user'));
}

function loadAuthScript(src, readyCheck) {
  if (readyCheck()) return Promise.resolve();

  return new Promise((resolve, reject) => {
    const existing = document.querySelector(`script[src="${src}"]`);

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

async function ensureSatAuth() {
  await loadAuthScript(
    '/js/auth-config.js',
    () => Boolean(window.SAT_AUTH_CONFIG)
  );

  await loadAuthScript(
    '/js/auth.js',
    () => Boolean(window.SATAuth)
  );

  if (!window.SATAuth) {
    throw new Error('SAT authentication could not be initialized.');
  }
}

function authenticatedStudentFromClaims(claims) {
  return normalizeStudentId(
    claims?.['cognito:username'] ||
    claims?.username ||
    ''
  );
}

async function apiRequest(payload) {
  const session = window.SATAuth
    ? await window.SATAuth.getSession()
    : null;

  const headers = {
    'Content-Type': 'application/json'
  };

  if (session?.accessToken) {
    headers.Authorization = `Bearer ${session.accessToken}`;
  }

  const response = await fetch(PROGRESS_API, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload),
    cache: 'no-store'
  });

  const raw = await response.text();
  let data = {};
  try {
    data = raw ? JSON.parse(raw) : {};
  } catch {
    data = { error: raw || 'Invalid response from progress service' };
  }

  if (!response.ok) {
    throw new ApiError(
      data.message || data.error || `Request failed with status ${response.status}`,
      response.status,
      data.code
    );
  }

  return data;
}

async function recordAttempt(questionId, correct, choice, category) {
  return apiRequest({
    action: 'record',
    userId: getUser(),
    questionId,
    correct,
    choice,
    category
  });
}

function latestIso(...values) {
  const valid = values
    .filter(Boolean)
    .map(value => new Date(value))
    .filter(date => !Number.isNaN(date.getTime()));
  if (!valid.length) return new Date(0).toISOString();
  return new Date(Math.max(...valid.map(date => date.getTime()))).toISOString();
}

function cloudItemToLocal(item) {
  const attempted = Boolean(item.lastResult);
  const locked =
    typeof item.locked === 'boolean'
      ? item.locked
      : attempted;

  return {
    correct: item.lastResult === 'correct',
    attemptedAt:
      item.lastAt ||
      item.firstAt ||
      new Date(0).toISOString(),
    firstAt:
      item.firstAt ||
      item.lastAt ||
      new Date(0).toISOString(),
    syncedAt: latestIso(
      item.lastAt,
      item.firstAt,
      item.unlockedAt
    ),
    locked,
    correctionAllowed:
      item.correctionAllowed === true ||
      (
        attempted &&
        item.lastResult === 'incorrect' &&
        !locked
      ),
    correctionSource:
      item.correctionSource || null,
    autoCorrectionAvailable:
      item.autoCorrectionAvailable === true,
    attempts: Number(
      item.attempts || (attempted ? 1 : 0)
    ),
    attemptRank: Number(item.attemptRank || 0),
    milestoneUnlocked: Number(
      item.milestoneUnlocked || 0
    ),
    nextMilestone: Number(
      item.nextMilestone || 20
    ),
    attemptsToNext: Number(
      item.attemptsToNext || 0
    ),
    choice: item.lastChoice,
    category: item.category || 'unknown'
  };
}

async function syncFromCloud() {
  const userId = getUser();
  if (!userId) return;

  try {
    const data = await apiRequest({ action: 'progress', userId });
    const remoteItems = Array.isArray(data.items) ? data.items : [];
    const local = loadProgress();
    let changed = false;

    remoteItems.forEach(item => {
      const remote = cloudItemToLocal(item);
      const existing = local[item.questionId];
      const existingTime = existing?.syncedAt || existing?.attemptedAt;

      if (!existing || !existingTime || new Date(remote.syncedAt) >= new Date(existingTime)) {
        local[item.questionId] = remote;
        changed = true;
      }
    });

    if (changed) saveProgress(local);
    resetOldSet2VisualReplacementProgressForJosh(); // post-cloud-prune
    resetOldVisualReplacementProgressForJosh(); // post-cloud-prune
  } catch (error) {
    console.warn('cloud sync failed', error);
    window.dispatchEvent(new CustomEvent('sat-math-progress-sync-error', {
      detail: {
        studentId: getUser(),
        error: String(error?.message || error)
      }
    }));
  }
}

function replaceStudentTextBox(displayName) {
  const input = document.getElementById('student-name');
  if (input) {
    const label = input.closest('label');
    if (label) {
      label.innerHTML = 'Student: <strong id="student-display-name"></strong>';
    } else {
      input.replaceWith(Object.assign(document.createElement('strong'), {
        id: 'student-display-name'
      }));
    }
  } else {
    const nav = document.querySelector('.nav');
    if (nav && !document.getElementById('student-display-name')) {
      const badge = document.createElement('span');
      badge.style.cssText = 'font-size:.85rem;color:#6b6f76;margin-left:12px;';
      badge.innerHTML = 'Student: <strong id="student-display-name"></strong>';
      nav.appendChild(badge);
    }
  }

  const display = document.getElementById('student-display-name');
  if (display) display.textContent = displayName;
}


function addStudentSignOutButton() {
  if (document.getElementById('sat-student-signout')) return;

  const studentDisplay = document.getElementById('student-display-name');
  if (!studentDisplay) return;

  const button = document.createElement('button');
  button.id = 'sat-student-signout';
  button.type = 'button';
  button.textContent = 'Sign out';
  button.setAttribute('aria-label', 'Sign out of the SAT student account');

  button.style.cssText = [
    'margin-left:12px',
    'padding:7px 12px',
    'border:1px solid rgba(255,255,255,.28)',
    'border-radius:9px',
    'background:transparent',
    'color:inherit',
    'font:700 13px/1 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
    'cursor:pointer',
    'white-space:nowrap'
  ].join(';');

  button.addEventListener('mouseenter', () => {
    button.style.background = 'rgba(255,255,255,.12)';
  });

  button.addEventListener('mouseleave', () => {
    button.style.background = 'transparent';
  });

  button.addEventListener('click', () => {
    button.disabled = true;
    button.textContent = 'Signing out…';

    // Remove only the active-user pointer.
    // Do not erase saved question progress.
    localStorage.removeItem('sat_user');
    currentStudentId = '';

    if (window.SATAuth?.logout) {
      window.SATAuth.logout();
    } else {
      window.location.assign('/login.html');
    }
  });

  const container =
    studentDisplay.closest('label') ||
    studentDisplay.parentElement;

  if (container) {
    container.style.display = 'inline-flex';
    container.style.alignItems = 'center';
    container.style.gap = '4px';
    container.appendChild(button);
  }
}

function rewriteStudentLinks() {
  document.querySelectorAll('a[href]').forEach(anchor => {
    const rawHref = anchor.getAttribute('href');
    if (!rawHref || rawHref.startsWith('#') || rawHref.startsWith('mailto:') || rawHref.startsWith('javascript:')) return;

    try {
      const url = new URL(rawHref, location.href);
      if (url.origin !== location.origin) return;
      if (!url.pathname.endsWith('.html') && !url.pathname.endsWith('/')) return;
      if (url.pathname.endsWith('/admin.html')) return;
      url.searchParams.delete('student');
      anchor.href = `${url.pathname}${url.search}${url.hash}`;
    } catch (error) {
      console.warn('Could not preserve student link', rawHref, error);
    }
  });
}


function addSubjectNavigation() {
  const staticNavigation =
    document.getElementById('sat-global-navigation');

  const injectedNavigation =
    document.getElementById('sat-subject-navigation');

  /*
   * Most Math pages already contain the shared SAT navigation.
   * Do not inject a second copy above it.
   */
  if (staticNavigation) {
    if (injectedNavigation) {
      injectedNavigation.remove();
    }
    return;
  }

  if (injectedNavigation) return;

  const makeLink = (label, path, active) => {
    const url = new URL(path, location.origin);
    url.searchParams.delete('student');

    const anchor = document.createElement('a');
    anchor.href = `${url.pathname}${url.search}`;
    anchor.textContent = label;
    anchor.style.cssText = [
      'display:inline-flex',
      'align-items:center',
      'justify-content:center',
      'padding:8px 12px',
      'border-radius:9px',
      'text-decoration:none',
      'font:700 13px/1 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
      active ? 'background:#ffffff;color:#111827' : 'background:transparent;color:#e5e7eb',
      'border:1px solid rgba(255,255,255,.24)'
    ].join(';');
    return anchor;
  };

  const nav = document.createElement('nav');
  nav.id = 'sat-subject-navigation';
  nav.setAttribute('aria-label', 'SAT subject navigation');
  nav.style.cssText = [
    'position:sticky',
    'top:0',
    'z-index:10000',
    'display:flex',
    'align-items:center',
    'gap:7px',
    'width:100%',
    'padding:9px 12px',
    'background:#111827',
    'box-shadow:0 2px 10px rgba(0,0,0,.18)'
  ].join(';');

  nav.append(
    makeLink('SAT Home', '/index.html', false),
    makeLink('English', '/english/index.html', false),
    makeLink('Math', '/math/index.html', true)
  );

  document.body.prepend(nav);
}

function hideStudentResetControls() {
  ['reset-volume', 'reset-all'].forEach(id => {
    const element = document.getElementById(id);
    if (element) element.style.display = 'none';
  });
}

function showStudentAccessPage(title, message) {
  document.documentElement.style.visibility = 'visible';
  document.body.innerHTML = `
    <main style="max-width:760px;margin:80px auto;padding:24px;">
      <section class="panel">
        <h1>${escapeHtml(title)}</h1>
        <p>${escapeHtml(message)}</p>
      </section>
    </main>`;
}

function showMissingStudentPage() {
  showStudentAccessPage(
    'Student link required',
    'This study page must be opened using the direct link provided by the administrator.'
  );
}

function showInvalidStudentPage() {
  showStudentAccessPage(
    'Invalid student link',
    'This student was not created by the administrator, or the link is no longer active. Ask the administrator for a valid direct link.'
  );
}

function showStudentVerificationError() {
  showStudentAccessPage(
    'Unable to verify student',
    'The student link could not be verified right now. Check the connection and try again.'
  );
}

async function prepareStudentPage() {
  document.documentElement.style.visibility = 'hidden';

  try {
    await ensureSatAuth();

    const session = await window.SATAuth.requireAuth();
    if (!session) {
      return false;
    }

    const claims = session.claims || {};
    const groups = Array.isArray(claims['cognito:groups'])
      ? claims['cognito:groups']
      : [];

    if (!groups.includes('students') && !groups.includes('admins')) {
      showStudentAccessPage(
        'Student access required',
        'This account is not assigned to the SAT students group.'
      );
      return false;
    }

    const studentId = resolveMathStudentId(authenticatedStudentFromClaims(claims));

    if (!studentId) {
      showStudentAccessPage(
        'Unable to identify student',
        'The authenticated account does not contain a valid student username.'
      );
      return false;
    }

    currentStudentId = studentId;
    localStorage.setItem('sat_user', studentId);

    // Remove the obsolete student query parameter from the address bar.
    const cleanUrl = new URL(window.location.href);
    if (cleanUrl.searchParams.has('student')) {
      cleanUrl.searchParams.delete('student');
      history.replaceState(
        null,
        '',
        `${cleanUrl.pathname}${cleanUrl.search}${cleanUrl.hash}`
      );
    }

    replaceStudentTextBox(
      claims.name ||
      claims.given_name ||
      studentId
    );

    addStudentSignOutButton();
    addSubjectNavigation();
    rewriteStudentLinks();
    hideStudentResetControls();

    document.documentElement.style.visibility = 'visible';
    return true;
  } catch (error) {
    console.error('Cognito student authentication failed', error);

    showStudentAccessPage(
      'Unable to verify login',
      'Your login could not be verified. Return to the login page and sign in again.'
    );

    return false;
  }
}

function storageKey() {
  return `${STORAGE_KEY}:${getUser() || '__missing_student__'}`;
}

function loadProgress() {
  try {
    return JSON.parse(localStorage.getItem(storageKey()) || '{}');
  } catch {
    return {};
  }
}

function saveProgress(progress) {
  localStorage.setItem(storageKey(), JSON.stringify(progress));
  window.dispatchEvent(new Event('sat-progress'));
}


// BEGIN SAT_VISUAL_REPLACEMENT_LOCAL_RESET_V1
const SAT_VISUAL_REPLACEMENT_RESET_CUTOFF = "2026-08-07T21:59:34Z";
const SAT_VISUAL_REPLACEMENT_RESET_IDS = new Set(["v1q021", "v1q024", "v1q028", "v1q031", "v1q034", "v1q036", "v1q062", "v1q067", "v1q069", "v1q077", "v1q095", "v1q100", "v2q022", "v2q027", "v2q033", "v2q038", "v2q039", "v2q042", "v2q043", "v2q046", "v2q052", "v2q056", "v2q065", "v2q070", "v2q075", "v2q090", "v2q096", "v2q100", "v3q017", "v3q025", "v3q030", "v3q033", "v3q036", "v3q038", "v3q043", "v3q045", "v3q055", "v3q057", "v3q065", "v3q066", "v3q070", "v3q084", "v3q098", "v3q100"]);
function resetOldVisualReplacementProgressForJosh() {
  if (getUser() !== 'josh') return;
  const progress = loadProgress();
  const cutoffMs = Date.parse(SAT_VISUAL_REPLACEMENT_RESET_CUTOFF);
  let changed = false;
  SAT_VISUAL_REPLACEMENT_RESET_IDS.forEach(questionId => {
    const item = progress[questionId];
    if (!item) return;
    const itemTime = item.syncedAt || item.attemptedAt || '';
    const itemMs = Date.parse(itemTime);
    if (!itemTime || Number.isNaN(itemMs) || itemMs < cutoffMs) {
      delete progress[questionId];
      changed = true;
    }
  });
  if (changed) localStorage.setItem(storageKey(), JSON.stringify(progress));
}
// END SAT_VISUAL_REPLACEMENT_LOCAL_RESET_V1

// BEGIN SAT_SET2_VISUAL_REPLACEMENT_LOCAL_RESET_V2
const SAT_SET2_VISUAL_REPLACEMENT_RESET_CUTOFF = "2026-08-07T22:41:07Z";
const SAT_SET2_VISUAL_REPLACEMENT_RESET_IDS = new Set(["s2v1q001", "s2v1q015", "s2v1q017", "s2v1q019", "s2v1q025", "s2v1q027", "s2v1q028", "s2v1q031", "s2v1q035", "s2v1q036", "s2v1q037", "s2v1q038", "s2v2q015", "s2v2q016", "s2v2q017", "s2v2q018", "s2v2q021", "s2v2q025", "s2v2q026", "s2v2q035", "s2v2q045", "s2v2q051", "s2v2q052", "s2v2q061", "s2v2q067", "s2v2q071", "s2v2q075", "s2v2q076", "s2v3q021", "s2v3q023", "s2v3q031", "s2v3q035", "s2v3q036", "s2v3q041", "s2v3q042", "s2v3q043", "s2v3q055", "s2v3q065", "s2v3q075", "s2v3q079", "s2v3q088", "s2v3q091", "s2v3q095", "s2v3q096"]);
function resetOldSet2VisualReplacementProgressForJosh() {
  if (getUser() !== 'josh') return;
  const progress = loadProgress();
  const cutoffMs = Date.parse(SAT_SET2_VISUAL_REPLACEMENT_RESET_CUTOFF);
  let changed = false;
  SAT_SET2_VISUAL_REPLACEMENT_RESET_IDS.forEach(questionId => {
    const item = progress[questionId]; if (!item) return;
    const itemTime = item.syncedAt || item.attemptedAt || ''; const itemMs = Date.parse(itemTime);
    if (!itemTime || Number.isNaN(itemMs) || itemMs < cutoffMs) { delete progress[questionId]; changed = true; }
  });
  if (changed) localStorage.setItem(storageKey(), JSON.stringify(progress));
}
// END SAT_SET2_VISUAL_REPLACEMENT_LOCAL_RESET_V2

function parseMathValue(raw) {
  if (raw === null || raw === undefined) return NaN;
  const value = String(raw).trim().replace(/,/g, '');
  if (/^[-+]?\d+(\.\d+)?\s*\/\s*[-+]?\d+(\.\d+)?$/.test(value)) {
    const [numerator, denominator] = value.split('/').map(Number);
    return denominator === 0 ? NaN : numerator / denominator;
  }
  return Number(value);
}

function progressFor(ids) {
  const progress = loadProgress();
  let attempted = 0;
  let correct = 0;
  ids.forEach(id => {
    if (progress[id]) {
      attempted += 1;
      if (progress[id].correct) correct += 1;
    }
  });
  return { attempted, correct, total: ids.length };
}

function setRing(element, correct, total) {
  const percent = total ? Math.round((correct / total) * 100) : 0;
  element.style.setProperty('--progress', `${percent}%`);
  element.querySelector('strong').textContent = `${percent}%`;
  element.querySelector('span').textContent = `${correct} of ${total} mastered`;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, character => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    "'": '&#39;',
    '"': '&quot;'
  })[character]);
}


// SAT_MILESTONE_RETRY_UI_V1
const CORRECTION_MILESTONE_SIZE = 20;

function correctionSummaryFor(questions) {
  const progress = loadProgress();
  const items = questions.map(question => progress[question.id]).filter(Boolean);
  const attempted = items.length;
  const correct = items.filter(item => item.correct).length;
  const retryAvailable = items.filter(item =>
    !item.correct && !item.locked && item.correctionAllowed
  ).length;
  const lockedIncorrect = items.filter(item =>
    !item.correct && item.locked
  ).length;
  const total = questions.length;
  const milestoneUnlocked = Math.min(
    total,
    Math.floor(attempted / CORRECTION_MILESTONE_SIZE) * CORRECTION_MILESTONE_SIZE
  );
  const nextMilestone = attempted >= total
    ? total
    : Math.min(total, milestoneUnlocked + CORRECTION_MILESTONE_SIZE);

  return {
    attempted,
    correct,
    retryAvailable,
    lockedIncorrect,
    total,
    milestoneUnlocked,
    nextMilestone,
    attemptsToNext: Math.max(0, nextMilestone - attempted)
  };
}

function addCorrectionExperienceStyles() {
  if (document.getElementById('sat-correction-experience-styles')) return;

  const style = document.createElement('style');
  style.id = 'sat-correction-experience-styles';
  style.textContent = `
    .sat-correction-panel{display:grid;grid-template-columns:minmax(0,1.45fr) minmax(260px,.75fr);gap:18px;margin:22px 0 28px;padding:20px;border:1px solid #4a4d53;border-radius:17px;background:linear-gradient(180deg,#202226,#1b1d21);box-shadow:0 8px 24px rgba(0,0,0,.18)}
    .sat-correction-head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px}
    .sat-correction-head h2{margin:0;font-size:1.25rem}.sat-correction-copy{margin:5px 0 0;color:#bdb7aa}.sat-correction-count{color:#e7c96f;font-weight:950;white-space:nowrap}
    .sat-correction-track{height:12px;margin:17px 0 12px;overflow:hidden;border:1px solid #303339;border-radius:999px;background:#0e0f11}.sat-correction-fill{height:100%;width:0;border-radius:inherit;background:linear-gradient(90deg,#e4c15f,#c9982d);transition:width .2s ease}
    .sat-correction-milestones{display:grid;grid-template-columns:repeat(5,minmax(54px,1fr));gap:8px}.sat-correction-milestone{padding:8px 6px;border:1px solid #484b50;border-radius:10px;background:#17191d;color:#99968e;text-align:center;font-size:.78rem;font-weight:850}.sat-correction-milestone.reached{border-color:#8a7440;background:#2d2a21;color:#e7c96f}
    .sat-correction-action{display:flex;flex-direction:column;justify-content:center;padding:17px;border:1px solid #4f6655;border-radius:14px;background:linear-gradient(180deg,#202720,#1a211b)}.sat-correction-action.locked{border-color:#595d63;background:linear-gradient(180deg,#24262a,#1d1f23)}.sat-correction-action strong{display:block;margin-bottom:6px;font-size:1.08rem}.sat-correction-action p{margin:0 0 13px;color:#c4c8c3}.sat-correction-action.locked p{color:#b9b6ae}.sat-correction-review[hidden]{display:none}
    .sat-navigator-toolbar{display:flex;align-items:center;justify-content:space-between;gap:13px;margin:22px 0 12px}.sat-navigator-toggle{display:inline-flex;align-items:center;gap:9px;min-height:43px;padding:0 15px;border:1px solid #75622f;border-radius:11px;background:#282b30;color:#e7c96f;font:inherit;font-weight:900;cursor:pointer}.sat-navigator-toggle:hover{background:#34312a}.sat-navigator-chevron{transition:transform .2s ease}.sat-navigator-toggle[aria-expanded="true"] .sat-navigator-chevron{transform:rotate(180deg)}
    .sat-navigator-region[hidden]{display:none}.sat-navigator-region{margin:0 0 22px;padding:17px;border:1px solid #4a4d53;border-radius:15px;background:#181a1e}.sat-navigator-legend{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:13px;color:#aaa69d;font-size:.82rem}.sat-navigator-legend span{display:inline-flex;align-items:center;gap:6px}.sat-nav-dot{width:9px;height:9px;border-radius:50%;background:#555960}.sat-nav-dot.correct{background:#5fa96c}.sat-nav-dot.retry{background:#d68646}.sat-nav-dot.incorrect{background:#b8665e}
    .sat-question-grid{display:grid;grid-template-columns:repeat(10,minmax(38px,1fr));gap:8px}.sat-question-jump{position:relative;aspect-ratio:1;min-height:38px;border:1px solid #50545a;border-radius:10px;background:#22252a;color:#d9d6ce;font:inherit;font-weight:900;cursor:pointer}.sat-question-jump:hover{transform:translateY(-1px)}.sat-question-jump.correct{border-color:#52735a;background:#1d2a20;color:#b9e8bf}.sat-question-jump.retry{border-color:#8e623e;background:#30251d;color:#ffc68f}.sat-question-jump.incorrect{border-color:#704b47;background:#291f1f;color:#e7a59d}.sat-question-jump.retry::after{content:"↻";position:absolute;top:-6px;right:-5px;display:grid;place-items:center;width:18px;height:18px;border:2px solid #111214;border-radius:50%;background:#d68646;color:#fff;font-size:.68rem}
    .choice.previous-wrong{opacity:.48;text-decoration:line-through}
    @media(max-width:850px){.sat-correction-panel{grid-template-columns:1fr}.sat-question-grid{grid-template-columns:repeat(5,minmax(38px,1fr))}}
    @media(max-width:520px){.sat-correction-head,.sat-navigator-toolbar{align-items:stretch;flex-direction:column}.sat-correction-milestones{overflow-x:auto}.sat-question-grid{grid-template-columns:repeat(4,minmax(38px,1fr))}}
    @media print{.sat-correction-panel,.sat-navigator-toolbar,.sat-navigator-region{display:none!important}}
  `;
  document.head.appendChild(style);
}

function installCorrectionExperience({ questions, state, render, topicSelect, topicNav }) {
  addCorrectionExperienceStyles();

  const stats = document.querySelector('main > .stats') || document.querySelector('main .stats');
  const questionList = document.getElementById('question-list');
  const statusSelect = document.getElementById('status-filter');

  if (statusSelect && ![...statusSelect.options].some(option => option.value === 'Corrections available')) {
    const option = document.createElement('option');
    option.value = 'Corrections available';
    option.textContent = 'Corrections available';
    statusSelect.appendChild(option);
  }

  const panel = document.createElement('section');
  panel.id = 'sat-correction-panel';
  panel.className = 'sat-correction-panel';
  panel.innerHTML = `
    <div>
      <div class="sat-correction-head"><div><h2>Correction progress</h2><p class="sat-correction-copy" id="sat-correction-copy"></p></div><div class="sat-correction-count" id="sat-correction-count"></div></div>
      <div class="sat-correction-track" aria-hidden="true"><div class="sat-correction-fill" id="sat-correction-fill"></div></div>
      <div class="sat-correction-milestones" id="sat-correction-milestones"></div>
    </div>
    <div class="sat-correction-action locked" id="sat-correction-action"><strong id="sat-correction-title">Correction locked</strong><p id="sat-correction-message"></p><button class="btn sat-correction-review" id="sat-correction-review" hidden>Review corrections</button></div>`;
  if (stats) stats.insertAdjacentElement('afterend', panel);

  const navigatorToolbar = document.createElement('div');
  navigatorToolbar.className = 'sat-navigator-toolbar';
  navigatorToolbar.innerHTML = `<button class="sat-navigator-toggle" id="sat-navigator-toggle" type="button" aria-expanded="false" aria-controls="sat-navigator-region"><span class="sat-navigator-chevron">▼</span><span id="sat-navigator-toggle-text">Show question navigator</span></button><span class="sat-correction-copy">Jump to any question; attempted question order does not matter.</span>`;

  const navigatorRegion = document.createElement('section');
  navigatorRegion.className = 'sat-navigator-region';
  navigatorRegion.id = 'sat-navigator-region';
  navigatorRegion.hidden = true;
  navigatorRegion.innerHTML = `<div class="sat-navigator-legend"><span><i class="sat-nav-dot correct"></i>Correct</span><span><i class="sat-nav-dot retry"></i>Correction available</span><span><i class="sat-nav-dot incorrect"></i>Incorrect and locked</span><span><i class="sat-nav-dot"></i>Not attempted</span></div><div class="sat-question-grid" id="sat-question-grid"></div>`;
  if (questionList) {
    questionList.insertAdjacentElement('beforebegin', navigatorRegion);
    navigatorRegion.insertAdjacentElement('beforebegin', navigatorToolbar);
  }

  const toggle = navigatorToolbar.querySelector('#sat-navigator-toggle');
  const toggleText = navigatorToolbar.querySelector('#sat-navigator-toggle-text');
  toggle.addEventListener('click', () => {
    const opening = toggle.getAttribute('aria-expanded') !== 'true';
    toggle.setAttribute('aria-expanded', String(opening));
    navigatorRegion.hidden = !opening;
    toggleText.textContent = opening ? 'Hide question navigator' : 'Show question navigator';
  });

  function resetFiltersForQuestion() {
    state.quizIds = null; state.topic = 'All topics'; state.difficulty = 'All levels'; state.status = 'All questions'; state.search = '';
    const search = document.getElementById('search');
    const difficulty = document.getElementById('difficulty-filter');
    const status = document.getElementById('status-filter');
    const quizBanner = document.getElementById('quiz-banner');
    if (search) search.value = '';
    if (topicSelect) topicSelect.value = 'All topics';
    if (difficulty) difficulty.value = 'All levels';
    if (status) status.value = 'All questions';
    if (quizBanner) quizBanner.classList.remove('show');
    if (topicNav) [...topicNav.children].forEach(item => item.classList.toggle('active', item.textContent === 'All topics'));
  }

  function jumpToQuestion(questionId) {
    resetFiltersForQuestion();
    render();
    requestAnimationFrame(() => document.getElementById(questionId)?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
  }

  panel.querySelector('#sat-correction-review').addEventListener('click', () => {
    state.quizIds = null;
    state.status = 'Corrections available';
    if (statusSelect) statusSelect.value = 'Corrections available';
    document.getElementById('quiz-banner')?.classList.remove('show');
    render();
    requestAnimationFrame(() => document.getElementById('practice')?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
  });

  function renderNavigator() {
    const grid = navigatorRegion.querySelector('#sat-question-grid');
    const progress = loadProgress();
    grid.innerHTML = '';
    questions.forEach(question => {
      const item = progress[question.id];
      const button = document.createElement('button');
      button.type = 'button'; button.className = 'sat-question-jump'; button.textContent = question.number;
      button.setAttribute('aria-label', `Open question ${question.number}`);
      if (item?.correct) { button.classList.add('correct'); button.title = 'Correct'; }
      else if (item && !item.locked && item.correctionAllowed) { button.classList.add('retry'); button.title = 'Correction available'; }
      else if (item) { button.classList.add('incorrect'); button.title = 'Incorrect and locked'; }
      else button.title = 'Not attempted';
      button.addEventListener('click', () => jumpToQuestion(question.id));
      grid.appendChild(button);
    });
  }

  function update() {
    const summary = correctionSummaryFor(questions);
    const attemptedPercent = summary.total ? Math.round(summary.attempted / summary.total * 100) : 0;
    const milestones = Array.from({ length: Math.ceil(summary.total / CORRECTION_MILESTONE_SIZE) }, (_, index) => Math.min(summary.total, (index + 1) * CORRECTION_MILESTONE_SIZE));
    panel.querySelector('#sat-correction-copy').textContent = `${summary.attempted} of ${summary.total} unique questions attempted`;
    panel.querySelector('#sat-correction-count').textContent = `${attemptedPercent}% attempted`;
    panel.querySelector('#sat-correction-fill').style.width = `${attemptedPercent}%`;
    panel.querySelector('#sat-correction-milestones').innerHTML = milestones.map(milestone => `<div class="sat-correction-milestone ${milestone <= summary.milestoneUnlocked ? 'reached' : ''}">${milestone}<br>${milestone <= summary.milestoneUnlocked ? 'Unlocked' : 'Locked'}</div>`).join('');

    const action = panel.querySelector('#sat-correction-action');
    const title = panel.querySelector('#sat-correction-title');
    const message = panel.querySelector('#sat-correction-message');
    const review = panel.querySelector('#sat-correction-review');
    if (summary.retryAvailable > 0) {
      action.classList.remove('locked'); title.textContent = 'Correction unlocked';
      message.textContent = `${summary.retryAvailable} incorrect question${summary.retryAvailable === 1 ? ' is' : 's are'} ready for one correction attempt.`;
      review.hidden = false; review.textContent = `Review ${summary.retryAvailable} correction${summary.retryAvailable === 1 ? '' : 's'}`;
    } else if (summary.attempted >= summary.total) {
      action.classList.toggle('locked', summary.lockedIncorrect > 0);
      title.textContent = summary.lockedIncorrect > 0 ? 'All automatic corrections used' : 'Volume first attempts complete';
      message.textContent = summary.lockedIncorrect > 0 ? `${summary.lockedIncorrect} question${summary.lockedIncorrect === 1 ? ' remains' : 's remain'} incorrect and require administrator approval for another attempt.` : 'There are no corrections waiting right now.';
      review.hidden = true;
    } else {
      action.classList.add('locked'); title.textContent = summary.milestoneUnlocked ? `${summary.milestoneUnlocked}-question milestone reached` : 'Correction locked';
      message.textContent = `Attempt ${summary.attemptsToNext} more different question${summary.attemptsToNext === 1 ? '' : 's'} to reach the ${summary.nextMilestone}-question correction milestone.`;
      review.hidden = true;
    }
    renderNavigator();
  }

  return { update, renderNavigator };
}


const SAT_FORMULA_GROUPS = {
  1: [
    {
      title: 'Linear equations and models',
      formulas: [
        'ax + b = c  →  x = (c − b)/a,  a ≠ 0',
        'y = mx + b',
        'm = (y₂ − y₁)/(x₂ − x₁)',
        'y − y₁ = m(x − x₁)',
        'Ax + By = C',
        'Direct variation: y = kx',
        'Average rate of change = [f(b) − f(a)]/(b − a)'
      ]
    },
    {
      title: 'Lines and coordinate formulas',
      formulas: [
        'Parallel lines: m₁ = m₂',
        'Perpendicular nonvertical lines: m₁m₂ = −1',
        'x-intercept: set y = 0',
        'y-intercept: set x = 0',
        'Midpoint = ((x₁ + x₂)/2, (y₁ + y₂)/2)',
        'Distance = √[(x₂ − x₁)² + (y₂ − y₁)²]'
      ]
    },
    {
      title: 'Functions, sequences, and inverses',
      formulas: [
        '(f ∘ g)(x) = f(g(x))',
        'Inverse check: f(f⁻¹(x)) = x',
        'Arithmetic sequence: aₙ = a₁ + (n − 1)d',
        'Arithmetic sum: Sₙ = n(a₁ + aₙ)/2',
        'Linear sequence common difference = slope'
      ]
    },
    {
      title: 'Systems, inequalities, and absolute value',
      formulas: [
        'Different slopes → one solution',
        'Same slope, different intercepts → no solution',
        'Same equation → infinitely many solutions',
        'Multiply or divide an inequality by a negative → reverse the sign',
        '|x| = a → x = ±a, for a ≥ 0',
        '|x| < a → −a < x < a',
        '|x| > a → x < −a or x > a'
      ]
    },
    {
      title: 'Piecewise and parameter reminders',
      formulas: [
        'For a piecewise function, use the rule whose condition contains x',
        'Exactly one solution in a linear equation occurs when the x-coefficient is nonzero',
        'No solution: variable terms cancel but constants disagree',
        'Infinitely many solutions: both sides simplify to the same expression'
      ]
    }
  ],
  2: [
    {
      title: 'Quadratic equations and roots',
      formulas: [
        'ax² + bx + c = 0,  a ≠ 0',
        'x = [−b ± √(b² − 4ac)]/(2a)',
        'Discriminant: D = b² − 4ac',
        'D > 0: two real roots; D = 0: one real root; D < 0: no real roots',
        'Sum of roots = −b/a',
        'Product of roots = c/a',
        'Axis of symmetry: x = −b/(2a)'
      ]
    },
    {
      title: 'Quadratic forms and transformations',
      formulas: [
        'Standard form: f(x) = ax² + bx + c',
        'Vertex form: f(x) = a(x − h)² + k',
        'Vertex = (h, k)',
        'Factored form: f(x) = a(x − r₁)(x − r₂)',
        'Completing square: x² + bx = (x + b/2)² − (b/2)²',
        'Tangency / exactly one intersection: discriminant = 0'
      ]
    },
    {
      title: 'Factoring identities',
      formulas: [
        'A² − B² = (A − B)(A + B)',
        'A² + 2AB + B² = (A + B)²',
        'A² − 2AB + B² = (A − B)²',
        'A³ + B³ = (A + B)(A² − AB + B²)',
        'A³ − B³ = (A − B)(A² + AB + B²)'
      ]
    },
    {
      title: 'Exponent and radical rules',
      formulas: [
        'xᵐxⁿ = xᵐ⁺ⁿ',
        'xᵐ/xⁿ = xᵐ⁻ⁿ,  x ≠ 0',
        '(xᵐ)ⁿ = xᵐⁿ',
        '(xy)ⁿ = xⁿyⁿ',
        'x⁰ = 1,  x ≠ 0',
        'x⁻ⁿ = 1/xⁿ',
        'xᵐ⁄ⁿ = ⁿ√(xᵐ)',
        '√(ab) = √a · √b when defined'
      ]
    },
    {
      title: 'Exponential growth and decay',
      formulas: [
        'Growth: A = A₀(1 + r)ᵗ',
        'Decay: A = A₀(1 − r)ᵗ',
        'Doubling: A = A₀ · 2ᵗ⁄ᵈ',
        'Half-life: A = A₀(1/2)ᵗ⁄ʰ',
        'Compound interest: A = P(1 + r/n)ⁿᵗ',
        'Continuous growth: A = Peʳᵗ'
      ]
    },
    {
      title: 'Polynomials, factors, and remainders',
      formulas: [
        'Remainder after division by x − c is P(c)',
        'x − c is a factor exactly when P(c) = 0',
        'Odd multiplicity: graph crosses the x-axis',
        'Even multiplicity: graph touches and turns',
        'End behavior is controlled by the leading term'
      ]
    },
    {
      title: 'Rational expressions and nonlinear functions',
      formulas: [
        'Denominators cannot equal 0',
        'Inverse variation: y = k/x or xy = k',
        '(f ∘ g)(x) = f(g(x))',
        'Inverse relation: swap x and y, then solve for y',
        'For radical equations: isolate the radical, square, and check for extraneous solutions'
      ]
    }
  ],
  3: [
    {
      title: 'Ratios, rates, and percent',
      formulas: [
        'Unit rate = quantity/time',
        'Proportion: a/b = c/d  →  ad = bc',
        'Density = mass/volume',
        'Percent = part/whole × 100%',
        'Percent change = (new − original)/original × 100%',
        'Increase: new = original(1 + r)',
        'Decrease: new = original(1 − r)',
        'Original = new/(1 ± r)'
      ]
    },
    {
      title: 'Statistics and models',
      formulas: [
        'Mean = sum of values/number of values',
        'Weighted mean = Σ(value × weight)/Σ(weights)',
        'Range = maximum − minimum',
        'Residual = observed value − predicted value',
        'Adding c to every value adds c to the mean and median but does not change standard deviation',
        'Multiplying every value by k multiplies standard deviation by |k|'
      ]
    },
    {
      title: 'Probability and counting',
      formulas: [
        'P(event) = favorable outcomes/total outcomes',
        'P(not A) = 1 − P(A)',
        'P(A or B) = P(A) + P(B) − P(A and B)',
        'Independent events: P(A and B) = P(A)P(B)',
        'P(A | B) = P(A and B)/P(B)',
        'Permutations: ⁿPᵣ = n!/(n − r)!',
        'Combinations: ⁿCᵣ = n!/[r!(n − r)!]'
      ]
    },
    {
      title: 'Angles and polygons',
      formulas: [
        'Triangle angle sum = 180°',
        'Exterior angle of a triangle = sum of the two remote interior angles',
        'Interior-angle sum of an n-gon = (n − 2)180°',
        'Each interior angle of a regular n-gon = (n − 2)180°/n',
        'Exterior-angle sum of any polygon = 360°',
        'Parallel lines: corresponding and alternate interior angles are equal'
      ]
    },
    {
      title: 'Area and similarity',
      formulas: [
        'Rectangle: A = lw',
        'Triangle: A = ½bh',
        'Parallelogram: A = bh',
        'Trapezoid: A = ½(b₁ + b₂)h',
        'Regular polygon: A = ½(apothem)(perimeter)',
        'Length scale factor = k; area factor = k²; volume factor = k³'
      ]
    },
    {
      title: 'Circles',
      formulas: [
        'Circumference: C = 2πr = πd',
        'Area: A = πr²',
        'Arc length = (θ/360°)(2πr)',
        'Sector area = (θ/360°)(πr²)',
        'Radians: arc length s = rθ',
        'Radians: sector area = ½r²θ',
        'Circle equation: (x − h)² + (y − k)² = r²'
      ]
    },
    {
      title: 'Coordinate geometry',
      formulas: [
        'Slope: m = (y₂ − y₁)/(x₂ − x₁)',
        'Midpoint = ((x₁ + x₂)/2, (y₁ + y₂)/2)',
        'Distance = √[(x₂ − x₁)² + (y₂ − y₁)²]',
        'Parallel: equal slopes',
        'Perpendicular nonvertical lines: m₁m₂ = −1'
      ]
    },
    {
      title: 'Right triangles and trigonometry',
      formulas: [
        'Pythagorean theorem: a² + b² = c²',
        'sin θ = opposite/hypotenuse',
        'cos θ = adjacent/hypotenuse',
        'tan θ = opposite/adjacent',
        '45°-45°-90° sides: x, x, x√2',
        '30°-60°-90° sides: x, x√3, 2x',
        'Radians = degrees × π/180',
        'Degrees = radians × 180/π'
      ]
    },
    {
      title: 'Surface area and volume',
      formulas: [
        'Rectangular prism: V = lwh',
        'Cylinder: V = πr²h',
        'Cone: V = ⅓πr²h',
        'Pyramid: V = ⅓Bh',
        'Sphere: V = ⁴⁄₃πr³',
        'Cylinder surface area: SA = 2πr² + 2πrh',
        'Sphere surface area: SA = 4πr²'
      ]
    }
  ]
};

function inferSatVolume(page) {
  const direct = Number(page?.volume);
  if ([1, 2, 3].includes(direct)) return direct;
  const firstId = page?.questions?.[0]?.id || '';
  const match = String(firstId).match(/(?:^s\d+)?v(\d+)q\d+$/i);
  return match ? Number(match[1]) : 0;
}

function addFormulaReferenceStyles() {
  if (document.getElementById('sat-formula-reference-styles')) return;
  const style = document.createElement('style');
  style.id = 'sat-formula-reference-styles';
  style.textContent = `
    .sat-formula-reference{margin-top:38px;padding-top:10px;scroll-margin-top:90px}
    .sat-formula-reference-heading{margin:34px 0 18px}
    .sat-formula-reference-heading h3{margin:.35rem 0 .5rem;font-size:clamp(1.55rem,3vw,2.15rem)}
    .sat-formula-reference-heading p{margin:0;color:#a7a9ae}
    .sat-formula-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px}
    .sat-formula-card{border:1px solid #4a4d53;border-radius:16px;padding:18px;background:rgba(255,255,255,.025)}
    .sat-formula-card h4{margin:0 0 12px;color:#f4f1e8;font-size:1.05rem}
    .sat-formula-list{display:grid;gap:9px}
    .sat-formula-item{display:block;padding:10px 12px;border-radius:10px;background:rgba(0,0,0,.18);border:1px solid rgba(231,201,111,.23);color:#f4e5ae;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono",monospace;font-size:.91rem;line-height:1.45;overflow-wrap:anywhere}
    .sat-formula-note{margin:18px 0 0;padding:13px 15px;border-left:4px solid #d6ae4e;border-radius:8px;background:rgba(214,174,78,.08);color:#d4d0c7}
    @media(max-width:640px){.sat-formula-grid{grid-template-columns:1fr}.sat-formula-card{padding:15px}}
    @media print{.sat-formula-card{break-inside:avoid}.sat-formula-reference{page-break-before:always}}
  `;
  document.head.appendChild(style);
}

function buildCompleteFormulaSheet(volume) {
  const groups = SAT_FORMULA_GROUPS[volume] || [];
  if (!groups.length) return null;

  const wrapper = document.createElement('div');
  wrapper.className = 'sat-formula-reference';
  wrapper.id = 'complete-formula-sheet';
  wrapper.innerHTML = `
    <div class="sat-formula-reference-heading">
      <div class="eyebrow">Complete SAT reference</div>
      <h3>Formulas and rules for this volume</h3>
      <p>Use this sheet after the practice bank to review missed concepts and fast methods.</p>
    </div>
    <div class="sat-formula-grid">
      ${groups.map(group => `
        <article class="sat-formula-card">
          <h4>${escapeHtml(group.title)}</h4>
          <div class="sat-formula-list">
            ${group.formulas.map(formula => `<span class="sat-formula-item">${escapeHtml(formula)}</span>`).join('')}
          </div>
        </article>`).join('')}
    </div>
    <p class="sat-formula-note"><strong>Test reminder:</strong> Check units, restrictions, signs, and whether the question asks for a value, coordinate, length, area, volume, or percent.</p>`;
  return wrapper;
}

function moveGuidesAndFormulasToPageEnd(page) {
  const main = document.querySelector('main');
  if (!main || document.getElementById('complete-formula-sheet')) return;

  addFormulaReferenceStyles();
  const volume = inferSatVolume(page);
  const formulaSheet = buildCompleteFormulaSheet(volume);
  const lessonGrid = document.querySelector('.lesson-grid');
  let guideSection = lessonGrid?.closest('section');

  if (!guideSection) {
    guideSection = document.createElement('section');
    guideSection.innerHTML = `
      <div class="section-heading">
        <div><div class="eyebrow">Reference after practice</div><h2>Topic guides and formulas</h2></div>
        <p>Review the reference after completing the questions.</p>
      </div>`;
  } else {
    const eyebrow = guideSection.querySelector('.section-heading .eyebrow');
    const description = guideSection.querySelector('.section-heading > p');
    if (eyebrow) eyebrow.textContent = 'Reference after practice';
    if (description) description.textContent = 'Review the concept guides and complete formula sheet after the practice bank.';
  }

  if (formulaSheet) guideSection.appendChild(formulaSheet);
  main.appendChild(guideSection);
}

async function initVolumePage() {
  if (!(await prepareStudentPage())) return;
  resetOldSet2VisualReplacementProgressForJosh();
  resetOldVisualReplacementProgressForJosh();


  const page = window.SAT_PAGE;
  moveGuidesAndFormulasToPageEnd(page);
  const questions = page.questions;
  const state = {
    topic: 'All topics',
    difficulty: 'All levels',
    status: 'All questions',
    search: '',
    quizIds: null,
    quizStart: null,
    selected: {}
  };

  const list = document.getElementById('question-list');
  let correctionUi = null;
  const topics = ['All topics', ...new Set(questions.map(question => question.topic))];
  const topicSelect = document.getElementById('topic-filter');

  topics.forEach(topic => {
    const option = document.createElement('option');
    option.value = topic;
    option.textContent = topic;
    topicSelect.appendChild(option);
  });

  const topicNav = document.getElementById('topic-nav');
  topics.forEach((topic, index) => {
    const button = document.createElement('button');
    button.textContent = topic;
    button.className = index === 0 ? 'active' : '';
    button.onclick = () => {
      state.topic = topic;
      topicSelect.value = topic;
      [...topicNav.children].forEach(item => item.classList.toggle('active', item === button));
      render();
    };
    topicNav.appendChild(button);
  });

  function filtered() {
    return questions.filter(question => {
      if (state.quizIds && !state.quizIds.includes(question.id)) return false;
      if (state.topic !== 'All topics' && question.topic !== state.topic) return false;
      if (state.difficulty !== 'All levels' && question.difficulty !== state.difficulty) return false;

      const progress = loadProgress()[question.id];
      if (state.status === 'Not attempted' && progress) return false;
      if (state.status === 'Correct' && (!progress || !progress.correct)) return false;
      if (state.status === 'Needs review' && (!progress || progress.correct)) return false;

      if (state.status === 'Corrections available' && (!progress || progress.correct || progress.locked || !progress.correctionAllowed)) return false;

      const searchable = `${question.prompt} ${question.topic} ${question.skill}`.toLowerCase();
      return !state.search || searchable.includes(state.search.toLowerCase());
    });
  }

  function render() {
    const rows = filtered();
    list.innerHTML = '';
    if (!rows.length) {
      list.innerHTML = '<div class="panel empty">No questions match these filters.</div>';
      updateStats();
      return;
    }
    rows.forEach(question => list.appendChild(renderQuestion(question)));
    updateStats();
  }

  function disableAnswerControls(card) {
    card.querySelectorAll('.choice').forEach(button => {
      button.disabled = true;
      button.setAttribute('aria-disabled', 'true');
    });
    const numeric = card.querySelector('.numeric-answer');
    if (numeric) numeric.disabled = true;
    const checkButton = card.querySelector('.check');
    if (checkButton) checkButton.disabled = true;
  }

  function applySavedState(question, card, progress) {
    if (!progress) return;

    const previousChoice =
      question.kind === 'mcq' &&
      Number.isInteger(Number(progress.choice))
        ? card.querySelector(
            `.choice[data-index="${Number(progress.choice)}"]`
          )
        : null;

    if (progress.correct) {
      if (previousChoice) {
        previousChoice.classList.add('selected');
      }

      if (
        question.kind === 'numeric' &&
        progress.choice !== undefined &&
        progress.choice !== null
      ) {
        card.querySelector(
          '.numeric-answer'
        ).value = progress.choice;
      }

      card.classList.add('correct');
      disableAnswerControls(card);
      showFeedback(
        card,
        true,
        progress.attempts > 1
          ? 'Correct after correction. This question is complete.'
          : 'Correct! This question is complete.'
      );
      return;
    }

    if (progress.locked) {
      if (previousChoice) {
        previousChoice.classList.add('selected');
      }

      if (
        question.kind === 'numeric' &&
        progress.choice !== undefined &&
        progress.choice !== null
      ) {
        card.querySelector(
          '.numeric-answer'
        ).value = progress.choice;
      }

      card.classList.add('incorrect');
      disableAnswerControls(card);

      showFeedback(
        card,
        false,
        progress.attempts > 1
          ? 'Incorrect after correction. The administrator can allow another attempt.'
          : `Incorrect. Attempt ${progress.attemptsToNext || 0} more different question${
              Number(progress.attemptsToNext || 0) === 1 ? '' : 's'
            } to unlock correction.`
      );
      return;
    }

    if (progress.correctionAllowed) {
      card.classList.add('incorrect');

      if (previousChoice) {
        previousChoice.classList.remove('selected');
        previousChoice.classList.add('previous-wrong');
        previousChoice.disabled = true;
        previousChoice.setAttribute(
          'aria-disabled',
          'true'
        );
      }

      if (question.kind === 'numeric') {
        const input =
          card.querySelector('.numeric-answer');
        input.value = '';
        input.placeholder =
          progress.choice !== undefined &&
          progress.choice !== null
            ? `Previous answer: ${progress.choice}. Enter a new answer`
            : 'Enter a new answer';
      }

      showFeedback(
        card,
        false,
        progress.correctionSource === 'administrator'
          ? 'The administrator allowed a correction. Enter a new answer.'
          : 'Correction unlocked by your 20-question milestone. Enter a new answer.'
      );
    }
  }

  function renderQuestion(question) {
    const card = document.createElement('article');
    card.className = 'question panel';
    card.id = question.id;
    const progress = loadProgress()[question.id];

    let answerHtml = '';
    if (question.kind === 'mcq') {
      answerHtml = '<div class="choices">' + question.choices.map((choice, index) => `
        <button class="choice" data-index="${index}">
          <span class="choice-letter">${String.fromCharCode(65 + index)}</span>
          <span>${escapeHtml(choice)}</span>
        </button>`).join('') + '</div>';
    } else {
      answerHtml = `
        <div class="numeric-wrap">
          <input class="numeric-answer" inputmode="decimal" aria-label="Numerical answer" placeholder="Enter answer (fractions allowed)">
          <span class="tag">Student-produced response</span>
        </div>`;
    }

    card.innerHTML = `
      <div class="q-top">
        <div class="q-number">Question ${question.number}</div>
        <div class="tags">
          <span class="tag topic">${escapeHtml(question.topic)}</span>
          <span class="tag">${escapeHtml(question.skill)}</span>
          <span class="tag">${question.difficulty}</span>
        </div>
      </div>
      <div class="prompt">${question.prompt}</div>
      ${answerHtml}
      <div class="q-actions">
        <button class="btn check">Check answer</button>
        <button class="btn ghost hint-btn">Hint</button>
        <button class="btn ghost fast-btn">Fast method</button>
      </div>
      <div class="feedback"></div>
      <div class="detail hint"><strong>Hint:</strong> ${question.hint}</div>
      <div class="detail fast"><strong>Fast method:</strong> ${question.fast_method}</div>`;

    if (question.kind === 'mcq') {
      card.querySelectorAll('.choice').forEach(button => button.addEventListener('click', () => {
        if (button.disabled) return;
        card.querySelectorAll('.choice').forEach(item => item.classList.remove('selected'));
        button.classList.add('selected');
        state.selected[question.id] = Number(button.dataset.index);
      }));
    }

    card.querySelector('.hint-btn').onclick = () => card.querySelector('.hint').classList.toggle('show');
    card.querySelector('.fast-btn').onclick = () => card.querySelector('.fast').classList.toggle('show');
    card.querySelector('.check').onclick = () => check(question, card);
    applySavedState(question, card, progress);
    return card;
  }

  function isCorrect(question, card) {
    if (question.kind === 'mcq') return state.selected[question.id] === question.answer_index;
    const value = parseMathValue(card.querySelector('.numeric-answer').value);
    const answer = parseMathValue(question.answer);
    return Number.isFinite(value) && Math.abs(value - answer) <= Math.max(question.tolerance || 1e-6, Math.abs(answer) * 1e-7);
  }

  async function check(question, card) {
    const existing =
      loadProgress()[question.id];

    if (existing?.locked || existing?.correct) {
      showFeedback(
        card,
        Boolean(existing.correct),
        existing.correct
          ? 'This question has already been completed.'
          : existing.attempts > 1
            ? 'This correction attempt is complete. Ask the administrator for another attempt.'
            : 'This question is locked until its correction milestone.'
      );
      disableAnswerControls(card);
      return;
    }

    if (
      question.kind === 'mcq' &&
      state.selected[question.id] === undefined
    ) {
      showFeedback(
        card,
        false,
        'Select an answer first.'
      );
      return;
    }

    const numericInput =
      card.querySelector('.numeric-answer');

    if (
      question.kind === 'numeric' &&
      !numericInput.value.trim()
    ) {
      showFeedback(
        card,
        false,
        'Enter an answer first.'
      );
      return;
    }

    const correct = isCorrect(question, card);
    const choice =
      question.kind === 'mcq'
        ? state.selected[question.id]
        : numericInput.value.trim();
    const checkButton =
      card.querySelector('.check');

    checkButton.disabled = true;
    checkButton.textContent = 'Saving...';

    try {
      const saved = await recordAttempt(
        question.id,
        correct,
        choice,
        question.topic
      );

      /*
       * The UpdateCommand response is authoritative. Do not immediately
       * query progress again, because that was restoring the old answer.
       */
      const progress = loadProgress();
      progress[question.id] =
        cloudItemToLocal(saved);

      localStorage.setItem(
        storageKey(),
        JSON.stringify(progress)
      );

      delete state.selected[question.id];
      render();

      requestAnimationFrame(() => {
        const updatedCard =
          document.getElementById(question.id);

        if (!updatedCard) return;

        updatedCard.scrollIntoView({
          behavior: 'smooth',
          block: 'center'
        });
      });
    } catch (error) {
      if (
        error.status === 409 ||
        error.code === 'QUESTION_LOCKED'
      ) {
        await syncFromCloud();
        showFeedback(
          card,
          false,
          error.message ||
            'This question is not available for another attempt.'
        );
        disableAnswerControls(card);
      } else {
        console.warn(
          'progress save failed',
          error
        );
        showFeedback(
          card,
          false,
          `The answer could not be saved: ${
            error.message || 'unknown error'
          }`
        );
        checkButton.disabled = false;
        checkButton.textContent =
          'Check answer';
      }
    }
  }

  function showFeedback(card, correct, message) {
    const feedback = card.querySelector('.feedback');
    feedback.className = `feedback show ${correct ? 'good' : 'bad'}`;
    feedback.textContent = message;
  }

  function updateStats() {
    const ids = questions.map(question => question.id);
    const summary = progressFor(ids);
    document.getElementById('stat-mastered').textContent = summary.correct;
    document.getElementById('stat-attempted').textContent = summary.attempted;
    document.getElementById('stat-remaining').textContent = summary.total - summary.correct;
    document.getElementById('stat-visible').textContent = filtered().length;
    setRing(document.querySelector('.progress-ring'), summary.correct, summary.total);
    correctionUi?.update();
  }

  correctionUi = installCorrectionExperience({ questions, state, render, topicSelect, topicNav });

  document.getElementById('search').oninput = event => {
    state.search = event.target.value;
    render();
  };
  topicSelect.onchange = event => {
    state.topic = event.target.value;
    [...topicNav.children].forEach(item => item.classList.toggle('active', item.textContent === state.topic));
    render();
  };
  document.getElementById('difficulty-filter').onchange = event => {
    state.difficulty = event.target.value;
    render();
  };
  document.getElementById('status-filter').onchange = event => {
    state.status = event.target.value;
    render();
  };
  document.getElementById('print-page').onclick = () => window.print();
  document.getElementById('start-quiz').onclick = () => {
    const available = questions.filter(question => {
      const progress = loadProgress()[question.id];
      return !progress?.correct && !progress?.locked;
    });

    if (!available.length) {
      alert('No unlocked questions are currently available for a quiz.');
      return;
    }

    state.quizIds = [...available]
      .sort(() => Math.random() - 0.5)
      .slice(0, Math.min(QUIZ_LENGTH, available.length))
      .map(question => question.id);
    state.quizStart = Date.now();
    state.topic = 'All topics';
    state.difficulty = 'All levels';
    state.status = 'All questions';
    state.search = '';
    document.getElementById('search').value = '';
    topicSelect.value = 'All topics';
    document.getElementById('difficulty-filter').value = 'All levels';
    document.getElementById('status-filter').value = 'All questions';
    document.getElementById('quiz-banner').classList.add('show');
    document.getElementById('quiz-count').textContent = state.quizIds.length;
    render();
    window.scrollTo({ top: document.getElementById('practice').offsetTop - 90, behavior: 'smooth' });
  };
  document.getElementById('exit-quiz').onclick = () => {
    state.quizIds = null;
    document.getElementById('quiz-banner').classList.remove('show');
    render();
  };

  window.addEventListener('sat-progress', render);
  render();
  syncFromCloud();
}


function questionIds(prefix, count = 100) {
  return Array.from(
    { length: count },
    (_, index) => `${prefix}${String(index + 1).padStart(3, '0')}`
  );
}

async function initHomePage() {
  if (!(await prepareStudentPage())) return;

  const legacyVolumes = Array.isArray(window.SAT_VOLUMES)
    ? window.SAT_VOLUMES.map(volume => ({
        ...volume,
        key: `v${volume.volume}`,
        prefix: `v${volume.volume}q`,
        count: 100
      }))
    : [];

  const config = window.SAT_HOME || { volumes: legacyVolumes };
  const cards = Array.isArray(config.volumes) ? config.volumes : [];
  const allIds = cards.flatMap(volume =>
    questionIds(volume.prefix, volume.count || 100)
  );

  function render() {
    const overall = progressFor(allIds);
    const percent = overall.total
      ? Math.round((overall.correct / overall.total) * 100)
      : 0;

    const mastered = document.getElementById('overall-mastered');
    const percentElement = document.getElementById('overall-percent');
    const bar = document.getElementById('overall-bar');

    if (mastered) mastered.textContent = `${overall.correct} / ${overall.total}`;
    if (percentElement) percentElement.textContent = `${percent}%`;
    if (bar) bar.style.width = `${percent}%`;

    cards.forEach(volume => {
      const count = volume.count || 100;
      const ids = questionIds(volume.prefix, count);
      const summary = progressFor(ids);
      const progressElement = document.getElementById(`${volume.key}-progress`);
      const volumeBar = document.getElementById(`${volume.key}-bar`);

      if (progressElement) {
        progressElement.textContent = `${summary.correct} of ${count} mastered`;
      }
      if (volumeBar) {
        volumeBar.style.width = `${Math.round((summary.correct / count) * 100)}%`;
      }
    });
  }

  render();
  window.addEventListener('storage', render);
  window.addEventListener('sat-progress', render);
  syncFromCloud();
}

async function initProgramSelector() {
  if (!(await prepareStudentPage())) return;

  const sets = Array.isArray(window.SAT_PROGRAM?.sets)
    ? window.SAT_PROGRAM.sets
    : [];

  const setIds = new Map();
  sets.forEach(set => {
    const ids = (set.prefixes || []).flatMap(prefix =>
      questionIds(prefix, set.countPerVolume || 100)
    );
    setIds.set(set.key, ids);
  });

  const allIds = [...setIds.values()].flat();

  function render() {
    const overall = progressFor(allIds);
    const percent = overall.total
      ? Math.round((overall.correct / overall.total) * 100)
      : 0;

    const mastered = document.getElementById('program-mastered');
    const percentElement = document.getElementById('program-percent');
    const bar = document.getElementById('program-bar');

    if (mastered) mastered.textContent = `${overall.correct} / ${overall.total}`;
    if (percentElement) percentElement.textContent = `${percent}%`;
    if (bar) bar.style.width = `${percent}%`;

    sets.forEach(set => {
      const ids = setIds.get(set.key) || [];
      const summary = progressFor(ids);
      const setPercent = summary.total
        ? Math.round((summary.correct / summary.total) * 100)
        : 0;

      const progressElement = document.getElementById(`${set.key}-progress`);
      const attemptedElement = document.getElementById(`${set.key}-attempted`);
      const setBar = document.getElementById(`${set.key}-bar`);

      if (progressElement) {
        progressElement.textContent =
          `${summary.correct} of ${summary.total} mastered`;
      }
      if (attemptedElement) {
        attemptedElement.textContent =
          `${summary.attempted} attempted`;
      }
      if (setBar) setBar.style.width = `${setPercent}%`;
    });
  }

  render();
  window.addEventListener('storage', render);
  window.addEventListener('sat-progress', render);
  syncFromCloud();
}

/* SAT_DEV_MATH_DISPLAY_NAME_ONLY_V2 BEGIN */
(() => {
  'use strict';

  let resolvedStudentId = '';
  let resolvedDisplayName = '';
  let observer = null;
  let queued = false;

  function normalizeStudentId(value) {
    const id = String(value || '').trim().toLowerCase();
    return /^[a-z0-9_-]{1,80}$/.test(id) ? id : '';
  }

  function decodeJwt(token) {
    try {
      const part = String(token || '').split('.')[1];
      if (!part) return null;
      const base64 = part.replace(/-/g, '+').replace(/_/g, '/');
      const padded = base64 + '='.repeat((4 - base64.length % 4) % 4);
      return JSON.parse(
        new TextDecoder().decode(
          Uint8Array.from(atob(padded), character => character.charCodeAt(0))
        )
      );
    } catch (_) {
      return null;
    }
  }

  function claimsStudentId(claims) {
    return normalizeStudentId(
      claims?.['cognito:username'] ||
      claims?.username ||
      claims?.preferred_username ||
      ''
    );
  }

  function claimsDisplayName(claims, fallback) {
    return String(
      claims?.name ||
      claims?.given_name ||
      claims?.preferred_username ||
      claims?.['cognito:username'] ||
      fallback ||
      ''
    ).trim();
  }

  function fallbackStudentId() {
    try {
      if (typeof getUser === 'function') {
        const value = normalizeStudentId(getUser());
        if (value) return value;
      }
    } catch (_) {}

    return normalizeStudentId(
      localStorage.getItem('sat_user') ||
      new URLSearchParams(location.search).get('student')
    );
  }

  async function resolveAuthenticatedIdentity() {
    let sessionClaims = null;

    try {
      if (window.SATAuth && typeof window.SATAuth.getSession === 'function') {
        const session = await window.SATAuth.getSession();
        sessionClaims = session?.claims || null;
      }
    } catch (error) {
      console.warn(
        'Math display-name fix: SATAuth session lookup failed; using token claims.',
        error
      );
    }

    const tokenClaims = decodeJwt(
      sessionStorage.getItem('sat_id_token') ||
      localStorage.getItem('sat_id_token')
    );

    const claims = sessionClaims || tokenClaims || {};
    const studentId = claimsStudentId(claims) || fallbackStudentId();
    const displayName = claimsDisplayName(claims, studentId) || studentId;

    return {studentId, displayName};
  }

  function replaceIdentityText(root) {
    if (!root || !resolvedStudentId || !resolvedDisplayName) return;

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const nodes = [];
    let node;
    while ((node = walker.nextNode())) nodes.push(node);

    for (const textNode of nodes) {
      const raw = String(textNode.nodeValue || '');
      const trimmed = raw.trim();
      const lower = trimmed.toLowerCase();

      if (lower === resolvedStudentId) {
        textNode.nodeValue = raw.replace(trimmed, resolvedDisplayName);
        continue;
      }

      if (lower === `student: ${resolvedStudentId}`) {
        textNode.nodeValue = raw.replace(trimmed, `Student: ${resolvedDisplayName}`);
        continue;
      }

      if (
        lower === `signed in as ${resolvedStudentId}.` ||
        lower === `signed in as ${resolvedStudentId}`
      ) {
        textNode.nodeValue = raw.replace(trimmed, `Signed in as ${resolvedDisplayName}.`);
      }
    }
  }

  function applyDisplayName() {
    if (!resolvedDisplayName) return;

    const display = document.getElementById('student-display-name');
    if (display && display.textContent.trim() !== resolvedDisplayName) {
      display.textContent = resolvedDisplayName;
    }

    replaceIdentityText(document.querySelector('.site-header .nav'));
    replaceIdentityText(document.getElementById('sat-unified-global-navigation'));
    replaceIdentityText(document.getElementById('sat-subject-navigation'));
  }

  function scheduleApply() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      applyDisplayName();
    });
  }

  async function startDisplayNameSync() {
    const identity = await resolveAuthenticatedIdentity();
    resolvedStudentId = identity.studentId;
    resolvedDisplayName = identity.displayName;

    if (!resolvedStudentId) {
      console.warn('Math display-name fix: authenticated student ID was not resolved.');
      return;
    }

    // Keep existing progress/user identity unchanged.
    localStorage.setItem('sat_user', resolvedStudentId);

    if (!resolvedDisplayName) resolvedDisplayName = resolvedStudentId;

    applyDisplayName();

    observer = new MutationObserver(scheduleApply);
    observer.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true
    });

    [100, 250, 500, 1000, 2000, 4000].forEach(delay => {
      setTimeout(applyDisplayName, delay);
    });

    setTimeout(() => observer?.disconnect(), 15000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startDisplayNameSync, {once: true});
  } else {
    startDisplayNameSync();
  }
})();
/* SAT_DEV_MATH_DISPLAY_NAME_ONLY_V2 END */
