const PROGRESS_API = 'https://l2m5cxuri2eojykndfbabmuthi0xfjya.lambda-url.us-east-1.on.aws/';

class ApiError extends Error {
  constructor(message, status, code) {
    super(message);
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
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new ApiError(data.message || data.error || `Request failed (${response.status})`, response.status, data.code);
  }
  return data;
}

function getAdminPassword() {
  return document.getElementById('admin-password').value;
}

function setStatus(message, type = '') {
  const status = document.getElementById('admin-status');
  status.className = `admin-status ${type}`;
  status.textContent = message;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
  })[character]);
}

function studentLink(studentId) {
  const url = new URL('index.html', location.href);
  url.searchParams.set('student', studentId);
  return url.href;
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const input = document.createElement('textarea');
    input.value = text;
    document.body.appendChild(input);
    input.select();
    document.execCommand('copy');
    input.remove();
  }
}

async function loadStudents() {
  const password = getAdminPassword();
  if (!password) {
    setStatus('Enter the administrator password.', 'error');
    return;
  }

  sessionStorage.setItem('sat_admin_password', password);
  setStatus('Loading students…');
  try {
    const data = await apiRequest({ action: 'listStudents', adminPassword: password });
    renderStudents(data.students || []);
    setStatus(`${(data.students || []).length} student(s) loaded.`, 'success');
  } catch (error) {
    setStatus(error.message, 'error');
  }
}

async function createStudent(event) {
  event.preventDefault();
  const password = getAdminPassword();
  const displayName = document.getElementById('display-name').value.trim();
  const requestedStudentId = document.getElementById('existing-id').value.trim();

  if (!password || !displayName) {
    setStatus('Administrator password and student name are required.', 'error');
    return;
  }

  setStatus('Creating student…');
  try {
    const data = await apiRequest({
      action: 'createStudent',
      adminPassword: password,
      displayName,
      requestedStudentId: requestedStudentId || undefined
    });
    document.getElementById('display-name').value = '';
    document.getElementById('existing-id').value = '';
    await copyText(studentLink(data.student.studentId));
    setStatus(`Created ${data.student.displayName}. The direct link was copied.`, 'success');
    await loadStudents();
  } catch (error) {
    setStatus(error.message, 'error');
  }
}

function renderStudents(students) {
  const container = document.getElementById('student-list');
  if (!students.length) {
    container.innerHTML = '<div class="panel empty">No students have been created yet.</div>';
    return;
  }

  container.innerHTML = students.map(student => {
    const link = studentLink(student.studentId);
    return `
      <article class="panel admin-student" data-student-id="${escapeHtml(student.studentId)}">
        <div>
          <h3>${escapeHtml(student.displayName)}</h3>
          <p class="muted">ID: <code>${escapeHtml(student.studentId)}</code></p>
        </div>
        <div class="admin-actions">
          <button class="btn copy-link" data-link="${escapeHtml(link)}">Copy direct link</button>
          <a class="btn secondary" href="${escapeHtml(link)}" target="_blank" rel="noopener">Open student page</a>
          <button class="btn ghost view-progress">View progress</button>
        </div>
        <div class="student-progress" hidden></div>
      </article>`;
  }).join('');

  container.querySelectorAll('.copy-link').forEach(button => button.addEventListener('click', async () => {
    await copyText(button.dataset.link);
    setStatus('Direct student link copied.', 'success');
  }));

  container.querySelectorAll('.view-progress').forEach(button => button.addEventListener('click', () => {
    const article = button.closest('.admin-student');
    loadStudentProgress(article.dataset.studentId, article.querySelector('.student-progress'));
  }));
}

function questionPosition(questionId) {
  const id = String(questionId || '').trim();
  let match = id.match(/^s(\d+)v(\d+)q(\d+)$/i);
  if (match) {
    return {
      recognized: true,
      setNumber: Number(match[1]),
      volumeNumber: Number(match[2]),
      questionNumber: Number(match[3]),
      groupKey: `s${Number(match[1])}v${Number(match[2])}`,
      groupLabel: `Set ${Number(match[1])} · Volume ${Number(match[2])}`
    };
  }

  match = id.match(/^v(\d+)q(\d+)$/i);
  if (match) {
    return {
      recognized: true,
      setNumber: 1,
      volumeNumber: Number(match[1]),
      questionNumber: Number(match[2]),
      groupKey: `s1v${Number(match[1])}`,
      groupLabel: `Set 1 · Volume ${Number(match[1])}`
    };
  }

  return {
    recognized: false,
    setNumber: Number.MAX_SAFE_INTEGER,
    volumeNumber: Number.MAX_SAFE_INTEGER,
    questionNumber: Number.MAX_SAFE_INTEGER,
    groupKey: 'other',
    groupLabel: 'Other questions'
  };
}

function compareQuestions(left, right) {
  const a = questionPosition(left.questionId);
  const b = questionPosition(right.questionId);
  return a.setNumber - b.setNumber ||
    a.volumeNumber - b.volumeNumber ||
    a.questionNumber - b.questionNumber ||
    String(left.questionId).localeCompare(String(right.questionId), undefined, { numeric: true });
}

function groupQuestionsByVolume(items) {
  const groups = new Map();
  [...items].sort(compareQuestions).forEach(item => {
    const position = questionPosition(item.questionId);
    if (!groups.has(position.groupKey)) {
      groups.set(position.groupKey, {
        key: position.groupKey,
        label: position.groupLabel,
        setNumber: position.setNumber,
        volumeNumber: position.volumeNumber,
        items: []
      });
    }
    groups.get(position.groupKey).items.push({ ...item, position });
  });
  return [...groups.values()];
}

async function allowSingleCorrection({ studentId, questionId, target, button }) {
  button.disabled = true;
  button.textContent = 'Unlocking…';
  try {
    await apiRequest({
      action: 'unlockQuestion',
      adminPassword: getAdminPassword(),
      studentId,
      questionId
    });
    setStatus(`${questionId} is now available for one correction attempt.`, 'success');
    await loadStudentProgress(studentId, target);
  } catch (error) {
    button.disabled = false;
    button.textContent = 'Allow correction';
    setStatus(error.message, 'error');
  }
}

async function allowVolumeCorrections({ studentId, group, target, button }) {
  const questionIds = group.items.map(item => item.questionId);
  if (!questionIds.length) return;

  const confirmed = window.confirm(
    `Allow one correction attempt for all ${questionIds.length} locked question(s) in ${group.label}?`
  );
  if (!confirmed) return;

  button.disabled = true;
  let completed = 0;
  try {
    for (const questionId of questionIds) {
      button.textContent = `Unlocking ${completed + 1} of ${questionIds.length}…`;
      await apiRequest({
        action: 'unlockQuestion',
        adminPassword: getAdminPassword(),
        studentId,
        questionId
      });
      completed += 1;
    }
    setStatus(`${completed} question(s) in ${group.label} are now available for correction.`, 'success');
    await loadStudentProgress(studentId, target);
  } catch (error) {
    button.disabled = false;
    button.textContent = `Allow all ${group.items.length} corrections`;
    setStatus(
      `${completed} of ${questionIds.length} questions were unlocked. ${error.message}`,
      'error'
    );
    await loadStudentProgress(studentId, target);
  }
}

async function loadStudentProgress(studentId, target) {
  target.hidden = false;
  target.innerHTML = '<p>Loading progress…</p>';

  try {
    const data = await apiRequest({
      action: 'adminProgress',
      adminPassword: getAdminPassword(),
      studentId
    });

    const items = data.items || [];
    const locked = items
      .filter(item => item.lastResult === 'incorrect' && item.locked)
      .sort(compareQuestions);
    const groups = groupQuestionsByVolume(locked);
    const summary = data.summary || {};

    const groupedMarkup = groups.map(group => `
      <section class="volume-group" data-volume-key="${escapeHtml(group.key)}">
        <div class="volume-heading">
          <div>
            <h5>${escapeHtml(group.label)}</h5>
            <span class="muted">${group.items.length} question(s), ordered by question number</span>
          </div>
          <button class="btn secondary unlock-volume" data-volume-key="${escapeHtml(group.key)}">
            Allow all ${group.items.length} corrections
          </button>
        </div>
        <div class="volume-questions">
          ${group.items.map(item => `
            <div class="locked-row">
              <div>
                <strong>Question ${item.position.recognized ? item.position.questionNumber : escapeHtml(item.questionId)}</strong>
                <span class="question-id">${escapeHtml(item.questionId)}</span>
                <span>${escapeHtml(item.category || 'Unknown category')}</span>
                <span>Last answer: ${escapeHtml(item.lastChoice ?? '')}</span>
              </div>
              <button class="btn unlock-question" data-question-id="${escapeHtml(item.questionId)}">Allow correction</button>
            </div>`).join('')}
        </div>
      </section>`).join('');

    target.innerHTML = `
      <div class="admin-summary">
        <span><strong>${summary.mastered || 0}</strong> mastered</span>
        <span><strong>${summary.attempted || 0}</strong> attempted</span>
        <span><strong>${locked.length}</strong> locked incorrect</span>
      </div>
      <h4>Questions awaiting correction approval</h4>
      ${locked.length ? groupedMarkup : '<p class="muted">No locked incorrect questions.</p>'}`;

    target.querySelectorAll('.unlock-question').forEach(button => button.addEventListener('click', () => {
      allowSingleCorrection({
        studentId,
        questionId: button.dataset.questionId,
        target,
        button
      });
    }));

    target.querySelectorAll('.unlock-volume').forEach(button => button.addEventListener('click', () => {
      const group = groups.find(candidate => candidate.key === button.dataset.volumeKey);
      if (group) allowVolumeCorrections({ studentId, group, target, button });
    }));
  } catch (error) {
    target.innerHTML = `<p class="error-text">${escapeHtml(error.message)}</p>`;
  }
}

document.getElementById('student-form').addEventListener('submit', createStudent);
document.getElementById('load-students').addEventListener('click', loadStudents);

const savedPassword = sessionStorage.getItem('sat_admin_password');
if (savedPassword) {
  document.getElementById('admin-password').value = savedPassword;
  loadStudents();
}
