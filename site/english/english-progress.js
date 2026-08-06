/* BEGIN SAT ENGLISH IDENTITY V7 */
(() => {
  'use strict';

  if (window.SATEnglishIdentity?.build === '20260804-english-identity-v7-20260804T182532Z') return;

  const normalize = value => {
    const id = String(value || '').trim().toLowerCase();
    return /^[a-z0-9_-]{1,80}$/.test(id) ? id : '';
  };

  const decodeToken = token => {
    try {
      const part = String(token || '').split('.')[1];
      if (!part) return null;
      const base64 = part.replace(/-/g, '+').replace(/_/g, '/');
      const padded = base64 + '='.repeat((4 - base64.length % 4) % 4);
      const binary = atob(padded);
      const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
      return JSON.parse(new TextDecoder().decode(bytes));
    } catch (error) {
      console.warn('Unable to decode the SAT Cognito identity.', error);
      return null;
    }
  };

  const nativeGet = URLSearchParams.prototype.get;
  const tokenClaims = decodeToken(
    sessionStorage.getItem('sat_id_token') ||
    localStorage.getItem('sat_id_token')
  );
  const tokenStudent = normalize(
    window.SATAuth?.studentId ||
    window.SATAuth?.username ||
    tokenClaims?.['cognito:username'] ||
    tokenClaims?.username ||
    tokenClaims?.preferred_username
  );
  const storedStudent = normalize(localStorage.getItem('sat_user'));
  const pageParams = new URLSearchParams(location.search);
  const urlStudent = normalize(nativeGet.call(pageParams, 'student'));
  let studentId = tokenStudent || storedStudent || urlStudent;

  function resolveStudentId() {
    const claims = decodeToken(
      sessionStorage.getItem('sat_id_token') ||
      localStorage.getItem('sat_id_token')
    );
    const authenticated = normalize(
      window.SATAuth?.studentId ||
      window.SATAuth?.username ||
      claims?.['cognito:username'] ||
      claims?.username ||
      claims?.preferred_username
    );
    const stored = normalize(localStorage.getItem('sat_user'));
    studentId = authenticated || stored || studentId || urlStudent;
    if (studentId) localStorage.setItem('sat_user', studentId);
    return studentId;
  }

  if (!URLSearchParams.prototype.__satEnglishIdentityV7) {
    URLSearchParams.prototype.get = function(name) {
      const value = nativeGet.call(this, name);
      if (String(name) === 'student' && !normalize(value)) {
        return resolveStudentId() || value;
      }
      return value;
    };
    Object.defineProperty(URLSearchParams.prototype, '__satEnglishIdentityV7', {
      value: true,
      configurable: true
    });
  }

  function cleanStudentParameter(urlValue) {
    try {
      const url = new URL(urlValue, location.href);
      if (url.origin !== location.origin) return urlValue;
      url.searchParams.delete('student');
      return `${url.pathname}${url.search}${url.hash}`;
    } catch (_) {
      return urlValue;
    }
  }

  function cleanAddressBar() {
    const url = new URL(location.href);
    if (!url.searchParams.has('student')) return;
    url.searchParams.delete('student');
    history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
  }

  function cleanStudentLinks(root = document) {
    root.querySelectorAll?.('a[href]').forEach(anchor => {
      const href = anchor.getAttribute('href');
      if (!href || href.startsWith('#') || href.startsWith('mailto:') || href.startsWith('javascript:')) return;
      const cleaned = cleanStudentParameter(href);
      if (cleaned !== href) anchor.setAttribute('href', cleaned);
    });
  }

  resolveStudentId();
  cleanAddressBar();

  window.SATResolveStudentId = resolveStudentId;
  window.SATEnglishIdentity = {
    build: '20260804-english-identity-v7-20260804T182532Z',
    get studentId() { return resolveStudentId(); },
    source: tokenStudent ? 'cognito' : storedStudent ? 'storage' : urlStudent ? 'url' : 'missing',
    normalize,
    resolveStudentId,
    cleanStudentLinks
  };

  const ready = () => {
    cleanStudentLinks();
    setTimeout(cleanStudentLinks, 0);
    setTimeout(cleanStudentLinks, 150);
    setTimeout(cleanStudentLinks, 600);

    if (document.body && window.MutationObserver) {
      const observer = new MutationObserver(records => {
        for (const record of records) {
          record.addedNodes.forEach(node => {
            if (node.nodeType === 1) cleanStudentLinks(node);
          });
        }
      });
      observer.observe(document.body, {childList: true, subtree: true});
      setTimeout(() => observer.disconnect(), 5000);
    }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', ready, {once: true});
  } else {
    ready();
  }
})();
/* END SAT ENGLISH IDENTITY V7 */

(() => {
  'use strict';

  const PROGRESS_API = 'https://hvvnxnlzdt7h4w53prvjavlgom0twjbu.lambda-url.us-east-1.on.aws/';
  const LEGACY_PROGRESS_KEY = 'sat300-nireekshan-progress-v1';
  const TOTAL_WORDS = 375;
  const params = new URLSearchParams(location.search);

  function normalizeStudentId(value) {
    const normalized = String(value || '').trim().toLowerCase();
    return /^[a-z0-9_-]{1,80}$/.test(normalized) ? normalized : '';
  }

  const studentId = normalizeStudentId(params.get('student'));
  const storageKey = `satEnglish300Progress:${studentId || '__missing_student__'}`;
  const activity = new Map();
  let pendingLearned = null;
  let saveTimer = null;

  document.documentElement.style.visibility = 'hidden';

  class ApiError extends Error {
    constructor(message, status, code) {
      super(message);
      this.name = 'ApiError';
      this.status = status;
      this.code = code;
    }
  }

  async function apiRequest(payload) {
    const response = await fetch(PROGRESS_API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
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
        data.message || data.error || `Request failed (${response.status})`,
        response.status,
        data.code
      );
    }
    return data;
  }

  function cleanLearned(values) {
    return [...new Set((Array.isArray(values) ? values : [])
      .map(Number)
      .filter(number => Number.isInteger(number) && number >= 1 && number <= TOTAL_WORDS))]
      .sort((a, b) => a - b);
  }

  function readLearned(key) {
    try {
      const value = JSON.parse(localStorage.getItem(key) || '{}');
      return cleanLearned(value.learned);
    } catch {
      return [];
    }
  }

  function writeLearned(values) {
    const learned = cleanLearned(values);
    localStorage.setItem(storageKey, JSON.stringify({ learned }));
    window.dispatchEvent(new Event('storage'));
    return learned;
  }

  function sameNumbers(left, right) {
    const a = cleanLearned(left);
    const b = cleanLearned(right);
    return a.length === b.length && a.every((value, index) => value === b[index]);
  }

  function activityId(mode, number) {
    return `eng-${mode}-${String(number).padStart(3, '0')}`;
  }

  function isLocked(mode, number) {
    const item = activity.get(activityId(mode, number));
    return Boolean(item && item.locked);
  }

  function rememberActivity(item) {
    if (item?.questionId) activity.set(item.questionId, item);
  }

  async function recordActivity(mode, number, correct, choice, category) {
    try {
      const item = await apiRequest({
        action: 'record',
        userId: studentId,
        questionId: activityId(mode, number),
        correct: Boolean(correct),
        choice,
        category
      });
      rememberActivity(item);
      return { ok: true, item };
    } catch (error) {
      return {
        ok: false,
        code: error.code,
        status: error.status,
        message: error.message || 'The answer could not be saved.'
      };
    }
  }

  function queueLearnedSync(values) {
    pendingLearned = cleanLearned(values);
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      const snapshot = pendingLearned;
      pendingLearned = null;
      ready.then(() => apiRequest({
        action: 'saveEnglishProgress',
        userId: studentId,
        learned: snapshot
      })).catch(error => console.warn('English progress save failed', error));
    }, 250);
  }

  function rewriteLinks() {
    document.querySelectorAll('a[href]').forEach(anchor => {
      const href = anchor.getAttribute('href');
      if (!href || href.startsWith('#') || href.startsWith('mailto:') || href.startsWith('javascript:')) return;
      try {
        const url = new URL(href, location.href);
        if (url.origin !== location.origin) return;
        if (!url.pathname.endsWith('.html') && !url.pathname.endsWith('/')) return;
        url.searchParams.set('student', studentId);
        anchor.href = `${url.pathname}${url.search}${url.hash}`;
      } catch (error) {
        console.warn('Could not preserve student link', href, error);
      }
    });
  }


  function addSubjectNavigation(student) {
    const existingUnified = document.getElementById('sat-unified-global-navigation');
    if (existingUnified) return;

    document.querySelectorAll('#sat-subject-navigation, .sat-global-nav').forEach(node => node.remove());

    const makeLink = (label, path, active) => {
      const url = new URL(path, location.origin);
      url.searchParams.set('student', studentId);
      const anchor = document.createElement('a');
      anchor.href = `${url.pathname}${url.search}`;
      anchor.textContent = label;
      anchor.style.cssText = [
        'display:inline-flex','align-items:center','justify-content:center','min-height:46px',
        'padding:10px 18px','border-radius:14px','text-decoration:none',
        'font:850 16px/1 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
        active ? 'background:linear-gradient(135deg,#e4c15f,#d2a93f);color:#18191b;border:1px solid #e7c96f' : 'background:#282b30;color:#f4f1e8;border:1px solid #555960'
      ].join(';');
      return anchor;
    };

    const header = document.createElement('header');
    header.id = 'sat-subject-navigation';
    header.style.cssText = 'position:relative;z-index:10000;width:100%;background:linear-gradient(180deg,#202226,#1b1d21);border-bottom:1px solid #45484f;color:#f4f1e8;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif';
    const inner = document.createElement('div');
    inner.style.cssText = 'width:min(1500px,calc(100% - 36px));min-height:70px;margin:auto;display:flex;align-items:center;gap:18px;flex-wrap:wrap';
    const brand = document.createElement('a');
    brand.href = `/index.html?student=${encodeURIComponent(studentId)}`;
    brand.textContent = 'SAT Prep';
    brand.style.cssText = 'margin-right:2px;color:#f4f1e8;text-decoration:none;font-size:18px;font-weight:950;white-space:nowrap';
    const nav = document.createElement('nav');
    nav.setAttribute('aria-label','SAT subject navigation');
    nav.style.cssText = 'display:flex;align-items:center;gap:10px;flex-wrap:wrap';
    nav.append(makeLink('SAT Home','/index.html',false),makeLink('English','/english/index.html',true),makeLink('Math','/math/index.html',false));
    const badge = document.createElement('span');
    badge.textContent = `Student: ${student?.displayName || studentId}`;
    badge.style.cssText = 'margin-left:auto;color:#c8c1b5;font-size:15px;font-weight:650;white-space:nowrap';
    inner.append(brand,nav,badge);header.appendChild(inner);document.body.prepend(header);
  }

  function finishPage(student) {
    addSubjectNavigation(student);
    rewriteLinks();
    document.documentElement.style.visibility = 'visible';
  }

  function showAccessError(title, message) {
    const render = () => {
      document.body.innerHTML = `<main style="max-width:720px;margin:80px auto;padding:24px;font-family:system-ui"><section style="padding:28px;border:1px solid #d1d5db;border-radius:16px;background:#fff"><h1>${title}</h1><p>${message}</p></section></main>`;
      document.documentElement.style.visibility = 'visible';
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', render, { once: true });
    else render();
  }

  const ready = (async () => {
    if (!studentId) {
      showAccessError('Student link required', 'Open this page using the direct student link created by the administrator.');
      throw new ApiError('Student link required', 400, 'INVALID_STUDENT_ID');
    }

    try {
      const [studentData, englishData, allProgress] = await Promise.all([
        apiRequest({ action: 'getStudent', userId: studentId }),
        apiRequest({ action: 'englishProgress', userId: studentId }),
        apiRequest({ action: 'progress', userId: studentId })
      ]);

      const student = studentData.student;
      if (!student || student.active === false) {
        throw new ApiError('This student link is inactive.', 403, 'STUDENT_INACTIVE');
      }

      (allProgress.items || [])
        .filter(item => /^eng-(quiz|spelling)-\d{3}$/.test(item.questionId || ''))
        .forEach(rememberActivity);

      const cloudLearned = cleanLearned(englishData.learned);
      const currentLocal = readLearned(storageKey);
      const legacyLocal = studentId === 'josh' ? readLearned(LEGACY_PROGRESS_KEY) : [];
      const merged = cleanLearned([...cloudLearned, ...currentLocal, ...legacyLocal]);

      writeLearned(merged);
      localStorage.setItem('sat_user', studentId);

      if (!sameNumbers(merged, cloudLearned)) {
        await apiRequest({
          action: 'saveEnglishProgress',
          userId: studentId,
          learned: merged
        });
      }

      const finish = () => finishPage(student);
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', finish, { once: true });
      else finish();

      return { student, learned: merged };
    } catch (error) {
      if (error.code === 'STUDENT_NOT_FOUND' || error.code === 'STUDENT_INACTIVE' || error.status === 403 || error.status === 404) {
        showAccessError('Invalid student link', 'This student was not created by the administrator, or the link is no longer active.');
      } else {
        showAccessError('Unable to load progress', 'The student and progress service could not be reached. Please try again.');
      }
      throw error;
    }
  })();

  window.SATEnglishCloud = {
    studentId,
    storageKey,
    ready,
    queueLearnedSync,
    recordActivity,
    isLocked,
    activityId
  };
})();

/* BEGIN SAT ENGLISH CLOUD V7 */
(() => {
  'use strict';

  const API = "https://hvvnxnlzdt7h4w53prvjavlgom0twjbu.lambda-url.us-east-1.on.aws/";
  const TOTAL = 375;
  const previous = window.SATEnglishCloud || {};
  const normalizeStudent = value => {
    const id = String(value || '').trim().toLowerCase();
    return /^[a-z0-9_-]{1,80}$/.test(id) ? id : '';
  };
  const studentId = normalizeStudent(
    window.SATResolveStudentId?.() ||
    window.SATEnglishIdentity?.studentId ||
    localStorage.getItem('sat_user') ||
    new URLSearchParams(location.search).get('student')
  );

  if (studentId) localStorage.setItem('sat_user', studentId);

  const storageKey = studentId
    ? `satEnglish300Progress:${studentId}`
    : 'sat300-nireekshan-progress-v1';

  const normalizeLearned = values => [...new Set(
    (Array.isArray(values) ? values : [])
      .map(Number)
      .filter(number => Number.isInteger(number) && number >= 1 && number <= TOTAL)
  )].sort((left, right) => left - right);

  function readLocal() {
    try {
      return normalizeLearned(
        JSON.parse(localStorage.getItem(storageKey) || '{}').learned
      );
    } catch (_) {
      return [];
    }
  }

  function writeLocal(learned) {
    localStorage.setItem(
      storageKey,
      JSON.stringify({learned: normalizeLearned(learned)})
    );
  }

  async function post(action, extra = {}) {
    if (!studentId) throw new Error('Student identity is missing. Please sign in once.');
    const response = await fetch(API, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      cache: 'no-store',
      body: JSON.stringify({
        action,
        userId: studentId,
        studentId,
        student: studentId,
        ...extra
      })
    });
    const text = await response.text();
    let payload = {};
    try { payload = text ? JSON.parse(text) : {}; } catch (_) { payload = {raw: text}; }
    if (!response.ok) {
      throw new Error(`English progress API ${response.status}: ${text}`);
    }
    return payload;
  }

  let timer = null;
  let pending = null;
  let saveChain = Promise.resolve();
  let lastError = null;

  async function saveNow(values) {
    const learned = normalizeLearned(values);
    const response = await post('saveEnglishProgress', {learned});
    const confirmed = normalizeLearned(response.learned);
    if (confirmed.length !== learned.length || confirmed.some((value, index) => value !== learned[index])) {
      throw new Error('The server did not confirm the learned-word list.');
    }
    lastError = null;
    window.dispatchEvent(new CustomEvent('sat-english-progress-synced', {
      detail: {studentId, learned}
    }));
    return learned;
  }

  function queueLearnedSync(values) {
    pending = normalizeLearned(values);
    clearTimeout(timer);
    timer = setTimeout(() => {
      const learned = pending;
      pending = null;
      saveChain = saveChain
        .catch(() => {})
        .then(() => saveNow(learned))
        .catch(error => {
          lastError = error;
          console.error('SAT English progress did not save.', error);
          window.dispatchEvent(new CustomEvent('sat-english-progress-sync-error', {
            detail: {studentId, error: String(error)}
          }));
        });
    }, 120);
    return saveChain;
  }

  const ready = Promise.resolve(previous.ready)
    .catch(error => console.warn('Older English initialization failed.', error))
    .then(async () => {
      if (!studentId) return;
      const local = readLocal();
      const remotePayload = await post('englishProgress');
      const remote = normalizeLearned(remotePayload.learned);
      const merged = normalizeLearned([...remote, ...local]);
      writeLocal(merged);
      if (merged.length !== remote.length || merged.some((value, index) => value !== remote[index])) {
        await saveNow(merged);
      }
    })
    .catch(error => {
      lastError = error;
      console.error('SAT English cloud initialization failed; local progress remains available.', error);
    });

  window.SATEnglishCloud = {
    ...previous,
    studentId,
    storageKey,
    ready,
    queueLearnedSync,
    flush() {
      clearTimeout(timer);
      if (pending) {
        const learned = pending;
        pending = null;
        saveChain = saveChain.catch(() => {}).then(() => saveNow(learned));
      }
      return saveChain;
    },
    getLastSyncError: () => lastError
  };
})();
/* END SAT ENGLISH CLOUD V7 */
