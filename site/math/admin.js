
const PROGRESS_API = "https://l2m5cxuri2eojykndfbabmuthi0xfjya.lambda-url.us-east-1.on.aws/";

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
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(payload),
    cache: 'no-store'
  });

  const data = await response
    .json()
    .catch(() => ({}));

  if (!response.ok) {
    throw new ApiError(
      data.message ||
      data.error ||
      `Request failed (${response.status})`,
      response.status,
      data.code
    );
  }

  return data;
}

function getAdminPassword() {
  return document
    .getElementById('admin-password')
    ?.value || '';
}

function setStatus(message, type = '') {
  const status =
    document.getElementById('admin-status');

  if (!status) return;

  status.className =
    `admin-status ${type}`.trim();

  status.textContent = message;
}

function escapeHtml(value) {
  return String(value ?? '').replace(
    /[&<>'"]/g,
    character => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      "'": '&#39;',
      '"': '&quot;'
    })[character]
  );
}

function studentLink(studentId) {
  const url =
    new URL('/index.html', location.origin);

  /*
   * Backward compatibility only. The student query parameter is
   * removed by the authenticated site after login.
   */
  url.searchParams.set(
    'student',
    studentId
  );

  return url.href;
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const input =
      document.createElement('textarea');

    input.value = text;
    document.body.appendChild(input);
    input.select();
    document.execCommand('copy');
    input.remove();
  }
}

const VOLUME_DEFINITIONS = [
  {
    key: 'rw',
    setNumber: 1,
    volumeNumber: 4,
    label: 'English · Pilot',
    title: 'Reading & Writing — 40 Questions',
    href: '/english/reading-writing/index.html'
  },

  {
    key: 's1v1',
    setNumber: 1,
    volumeNumber: 1,
    label: 'Set 1 · Volume 1',
    title: 'Algebra Foundations',
    href: '/math/volume-1-algebra-foundations.html'
  },
  {
    key: 's1v2',
    setNumber: 1,
    volumeNumber: 2,
    label: 'Set 1 · Volume 2',
    title: 'Advanced Math',
    href: '/math/volume-2-advanced-math.html'
  },
  {
    key: 's1v3',
    setNumber: 1,
    volumeNumber: 3,
    label: 'Set 1 · Volume 3',
    title: 'Data, Geometry, and Trigonometry',
    href: '/math/volume-3-data-geometry-trigonometry.html'
  },
  {
    key: 's2v1',
    setNumber: 2,
    volumeNumber: 1,
    label: 'Set 2 · Volume 1',
    title: 'Higher-Difficulty Algebra',
    href: '/math/set-2-volume-1-algebra.html'
  },
  {
    key: 's2v2',
    setNumber: 2,
    volumeNumber: 2,
    label: 'Set 2 · Volume 2',
    title: 'Advanced Math',
    href: '/math/set-2-volume-2-advanced-math.html'
  },
  {
    key: 's2v3',
    setNumber: 2,
    volumeNumber: 3,
    label: 'Set 2 · Volume 3',
    title: 'Data, Geometry, and Trigonometry',
    href: '/math/set-2-volume-3-data-geometry-trigonometry.html'
  }
];

function volumeDefinition(groupKey) {
  return VOLUME_DEFINITIONS.find(
    volume => volume.key === groupKey
  ) || {
    key: groupKey,
    setNumber: 99,
    volumeNumber: 99,
    label: 'Other questions',
    title: 'Other questions',
    href: '/math/index.html'
  };
}

function questionPosition(questionId) {
  const id =
    String(questionId || '').trim();

  let match =
    id.match(/^s(\d+)v(\d+)q(\d+)$/i);

  if (match) {
    return {
      recognized: true,
      setNumber: Number(match[1]),
      volumeNumber: Number(match[2]),
      questionNumber: Number(match[3]),
      groupKey:
        `s${Number(match[1])}v${Number(match[2])}`,
      groupLabel:
        `Set ${Number(match[1])} · Volume ${Number(match[2])}`
    };
  }

  match =
    id.match(/^v(\d+)q(\d+)$/i);

  if (match) {
    return {
      recognized: true,
      setNumber: 1,
      volumeNumber: Number(match[1]),
      questionNumber: Number(match[2]),
      groupKey:
        `s1v${Number(match[1])}`,
      groupLabel:
        `Set 1 · Volume ${Number(match[1])}`
    };
  }

  match =
    id.match(/^rwq(\d{3})$/i);

  if (match) {
    return {
      recognized: true,
      setNumber: 1,
      volumeNumber: 4,
      questionNumber: Number(match[1]),
      groupKey: 'rw',
      groupLabel: 'English · Reading & Writing Pilot'
    };
  }

  return {
    recognized: false,
    setNumber: 99,
    volumeNumber: 99,
    questionNumber: 999999,
    groupKey: 'other',
    groupLabel: 'Other questions'
  };
}

function compareQuestions(left, right) {
  const a =
    questionPosition(left.questionId);

  const b =
    questionPosition(right.questionId);

  return (
    a.setNumber - b.setNumber ||
    a.volumeNumber - b.volumeNumber ||
    a.questionNumber - b.questionNumber ||
    String(left.questionId).localeCompare(
      String(right.questionId),
      undefined,
      { numeric: true }
    )
  );
}

function groupQuestionsByVolume(items) {
  const groups = new Map();

  [...items]
    .sort(compareQuestions)
    .forEach(item => {
      const position =
        questionPosition(item.questionId);

      if (!groups.has(position.groupKey)) {
        groups.set(
          position.groupKey,
          {
            key: position.groupKey,
            label: position.groupLabel,
            setNumber: position.setNumber,
            volumeNumber: position.volumeNumber,
            items: []
          }
        );
      }

      groups
        .get(position.groupKey)
        .items
        .push({
          ...item,
          position
        });
    });

  return [...groups.values()];
}

function progressQuestionLink(
  groupKey,
  questionId
) {
  const definition =
    volumeDefinition(groupKey);

  const url =
    new URL(
      definition.href,
      location.origin
    );

  url.hash = questionId;

  return (
    `${url.pathname}` +
    `${url.search}` +
    `${url.hash}`
  );
}

async function loadStudents() {
  const password =
    getAdminPassword();

  if (!password) {
    setStatus(
      'Enter the administrator password.',
      'error'
    );
    return;
  }

  sessionStorage.setItem(
    'sat_admin_password',
    password
  );

  setStatus('Loading students…');

  try {
    const data = await apiRequest({
      action: 'listStudents',
      adminPassword: password
    });

    renderStudents(
      data.students || []
    );

    setStatus(
      `${(data.students || []).length} student(s) loaded.`,
      'success'
    );
  } catch (error) {
    setStatus(
      error.message,
      'error'
    );
  }
}

async function createStudent(event) {
  event.preventDefault();

  const password =
    getAdminPassword();

  const displayName =
    document
      .getElementById('display-name')
      ?.value
      .trim() || '';

  const requestedStudentId =
    document
      .getElementById('existing-id')
      ?.value
      .trim() || '';

  if (!password || !displayName) {
    setStatus(
      'Administrator password and student name are required.',
      'error'
    );
    return;
  }

  setStatus('Creating student…');

  try {
    const data = await apiRequest({
      action: 'createStudent',
      adminPassword: password,
      displayName,
      requestedStudentId:
        requestedStudentId || undefined
    });

    document
      .getElementById('display-name')
      .value = '';

    document
      .getElementById('existing-id')
      .value = '';

    await copyText(
      studentLink(
        data.student.studentId
      )
    );

    setStatus(
      `Created ${data.student.displayName}. The direct link was copied.`,
      'success'
    );

    await loadStudents();
  } catch (error) {
    setStatus(
      error.message,
      'error'
    );
  }
}

function renderStudents(students) {
  const container =
    document.getElementById('student-list');

  if (!container) return;

  if (!students.length) {
    container.innerHTML =
      '<div class="panel empty">No students have been created yet.</div>';
    return;
  }

  container.innerHTML =
    students.map(student => {
      const link =
        studentLink(student.studentId);

      return `
        <article
          class="panel admin-student"
          data-student-id="${escapeHtml(student.studentId)}"
        >
          <div class="admin-student-header">
            <div class="admin-student-identity">
              <h3>${escapeHtml(student.displayName)}</h3>

              <p class="muted">
                ID:
                <code>${escapeHtml(student.studentId)}</code>
              </p>
            </div>

            <div class="admin-actions">
              <button
                class="btn copy-link"
                data-link="${escapeHtml(link)}"
              >
                Copy direct link
              </button>

              <a
                class="btn secondary"
                href="${escapeHtml(link)}"
                target="_blank"
                rel="noopener"
              >
                Open student page
              </a>

              <button
                class="btn ghost view-progress"
                aria-expanded="false"
              >
                <span class="view-progress-label">
                  View progress
                </span>

                <span
                  class="view-progress-chevron"
                  aria-hidden="true"
                >
                  ⌄
                </span>
              </button>
            </div>
          </div>

          <div
            class="student-progress"
            hidden
          ></div>
        </article>
      `;
    }).join('');

  container
    .querySelectorAll('.copy-link')
    .forEach(button => {
      button.addEventListener(
        'click',
        async () => {
          await copyText(
            button.dataset.link
          );

          setStatus(
            'Direct student link copied.',
            'success'
          );
        }
      );
    });

  container
    .querySelectorAll('.view-progress')
    .forEach(button => {
      button.addEventListener(
        'click',
        async () => {
          const article =
            button.closest('.admin-student');

          const target =
            article.querySelector(
              '.student-progress'
            );

          const label =
            button.querySelector(
              '.view-progress-label'
            );

          const opening =
            target.hidden;

          if (!opening) {
            target.hidden = true;

            button.setAttribute(
              'aria-expanded',
              'false'
            );

            label.textContent =
              'View progress';

            return;
          }

          target.hidden = false;

          button.setAttribute(
            'aria-expanded',
            'true'
          );

          label.textContent =
            'Hide progress';

          await loadStudentProgress(
            article.dataset.studentId,
            target
          );
        }
      );
    });
}

async function allowSingleCorrection({
  studentId,
  questionId,
  target,
  button
}) {
  button.disabled = true;
  button.textContent = 'Unlocking…';

  const selectedSet =
    questionPosition(
      questionId
    ).setNumber;

  try {
    await apiRequest({
      action: 'unlockQuestion',
      adminPassword: getAdminPassword(),
      studentId,
      questionId
    });

    setStatus(
      `${questionId} is now available for one correction attempt.`,
      'success'
    );

    await loadStudentProgress(
      studentId,
      target,
      selectedSet
    );
  } catch (error) {
    button.disabled = false;
    button.textContent =
      'Allow correction';

    setStatus(
      error.message,
      'error'
    );
  }
}

async function allowVolumeCorrections({
  studentId,
  group,
  target,
  button
}) {
  const questionIds =
    group.items.map(
      item => item.questionId
    );

  if (!questionIds.length) return;

  const confirmed =
    window.confirm(
      `Allow one correction attempt for all ` +
      `${questionIds.length} locked question(s) ` +
      `in ${group.label}?`
    );

  if (!confirmed) return;

  button.disabled = true;

  let completed = 0;

  try {
    for (
      const questionId of questionIds
    ) {
      button.textContent =
        `Unlocking ${completed + 1} ` +
        `of ${questionIds.length}…`;

      await apiRequest({
        action: 'unlockQuestion',
        adminPassword: getAdminPassword(),
        studentId,
        questionId
      });

      completed += 1;
    }

    setStatus(
      `${completed} question(s) in ` +
      `${group.label} are now available for correction.`,
      'success'
    );

    await loadStudentProgress(
      studentId,
      target,
      group.setNumber
    );
  } catch (error) {
    button.disabled = false;

    button.textContent =
      `Allow all ${group.items.length}`;

    setStatus(
      `${completed} of ${questionIds.length} ` +
      `questions were unlocked. ${error.message}`,
      'error'
    );

    await loadStudentProgress(
      studentId,
      target,
      group.setNumber
    );
  }
}

function setProgressTab(
  target,
  setNumber
) {
  target
    .querySelectorAll(
      '.admin-progress-tab'
    )
    .forEach(button => {
      const active =
        Number(button.dataset.setNumber) ===
        Number(setNumber);

      button.classList.toggle(
        'active',
        active
      );

      button.setAttribute(
        'aria-selected',
        active ? 'true' : 'false'
      );
    });

  target
    .querySelectorAll(
      '.admin-progress-set'
    )
    .forEach(panel => {
      panel.hidden =
        Number(panel.dataset.setNumber) !==
        Number(setNumber);
    });
}

function renderVolumeCard(
  group,
  definition
) {
  const itemCount =
    group.items.length;

  const questionMarkup =
    itemCount
      ? group.items.map(item => `
          <div class="admin-question-card">
            <div class="admin-question-details">
              <strong>
                Question ${
                  item.position.recognized
                    ? item.position.questionNumber
                    : escapeHtml(item.questionId)
                }
              </strong>

              <span class="question-id">
                ${escapeHtml(item.questionId)}
              </span>

              <span>
                ${escapeHtml(
                  item.category ||
                  'Unknown category'
                )}
              </span>

              <span>
                Last answer:
                ${escapeHtml(item.lastChoice ?? '')}
              </span>
            </div>

            <div class="admin-question-actions">
              <a
                class="btn ghost"
                href="${escapeHtml(
                  progressQuestionLink(
                    group.key,
                    item.questionId
                  )
                )}"
                target="_blank"
                rel="noopener"
              >
                Open question
              </a>

              <button
                class="btn unlock-question"
                data-question-id="${escapeHtml(item.questionId)}"
              >
                Allow correction
              </button>
            </div>
          </div>
        `).join('')
      : `
        <div class="admin-volume-empty">
          No questions currently await correction approval.
        </div>
      `;

  return `
    <article
      class="admin-volume-card"
      data-volume-key="${escapeHtml(group.key)}"
    >
      <div class="admin-volume-header">
        <div>
          <div class="eyebrow">
            ${escapeHtml(definition.label)}
          </div>

          <h5>
            ${escapeHtml(definition.title)}
          </h5>

          <span class="muted">
            ${itemCount}
            correction${itemCount === 1 ? '' : 's'}
            waiting
          </span>
        </div>

        <span class="admin-volume-count">
          ${itemCount}
        </span>
      </div>

      <div class="admin-volume-actions">
        <a
          class="btn ghost"
          href="${escapeHtml(definition.href)}"
          target="_blank"
          rel="noopener"
        >
          Open volume page
        </a>

        ${
          itemCount
            ? `
              <button
                class="btn secondary unlock-volume"
                data-volume-key="${escapeHtml(group.key)}"
              >
                Allow all ${itemCount}
              </button>
            `
            : `
              <button
                class="btn secondary"
                disabled
              >
                Nothing to allow
              </button>
            `
        }
      </div>

      <div class="admin-volume-questions">
        ${questionMarkup}
      </div>
    </article>
  `;
}

async function loadStudentProgress(
  studentId,
  target,
  preferredSetNumber
) {
  target.hidden = false;

  target.innerHTML =
    '<p>Loading progress…</p>';

  try {
    const data = await apiRequest({
      action: 'adminProgress',
      adminPassword: getAdminPassword(),
      studentId
    });

    const items =
      data.items || [];

    const locked =
      items
        .filter(
          item =>
            item.lastResult === 'incorrect' &&
            item.locked
        )
        .sort(compareQuestions);

    const lockedGroups =
      groupQuestionsByVolume(locked);

    const groupMap =
      new Map(
        lockedGroups.map(
          group => [
            group.key,
            group
          ]
        )
      );

    const completeGroups =
      VOLUME_DEFINITIONS.map(
        definition => {
          const existing =
            groupMap.get(definition.key);

          return existing || {
            key: definition.key,
            label: definition.label,
            setNumber:
              definition.setNumber,
            volumeNumber:
              definition.volumeNumber,
            items: []
          };
        }
      );

    const otherGroup =
      lockedGroups.find(
        group => group.key === 'other'
      );

    const summary =
      data.summary || {};

    const defaultSet =
      preferredSetNumber ||
      lockedGroups.find(
        group =>
          group.setNumber === 1 ||
          group.setNumber === 2
      )?.setNumber ||
      1;

    const setMarkup =
      [1, 2].map(setNumber => {
        const volumes =
          completeGroups
            .filter(
              group =>
                group.setNumber ===
                setNumber
            )
            .map(group =>
              renderVolumeCard(
                group,
                volumeDefinition(group.key)
              )
            )
            .join('');

        return `
          <section
            class="admin-progress-set"
            data-set-number="${setNumber}"
            ${
              setNumber === defaultSet
                ? ''
                : 'hidden'
            }
          >
            <div class="admin-volume-grid">
              ${volumes}
            </div>
          </section>
        `;
      }).join('');

    target.innerHTML = `
      <div class="admin-summary">
        <span>
          <strong>
            ${summary.mastered || 0}
          </strong>
          mastered
        </span>

        <span>
          <strong>
            ${summary.attempted || 0}
          </strong>
          attempted
        </span>

        <span>
          <strong>
            ${locked.length}
          </strong>
          locked incorrect
        </span>
      </div>

      <div class="admin-progress-heading">
        <div>
          <h4>
            Questions awaiting correction approval
          </h4>

          <p class="muted">
            Approve one question or every waiting
            question in a volume.
          </p>
        </div>
      </div>

      <div
        class="admin-progress-tabs"
        role="tablist"
        aria-label="Math sets"
      >
        <button
          class="admin-progress-tab ${
            defaultSet === 1
              ? 'active'
              : ''
          }"
          data-set-number="1"
          role="tab"
          aria-selected="${
            defaultSet === 1
              ? 'true'
              : 'false'
          }"
        >
          Set 1
        </button>

        <button
          class="admin-progress-tab ${
            defaultSet === 2
              ? 'active'
              : ''
          }"
          data-set-number="2"
          role="tab"
          aria-selected="${
            defaultSet === 2
              ? 'true'
              : 'false'
          }"
        >
          Set 2
        </button>
      </div>

      ${setMarkup}

      ${
        otherGroup
          ? `
            <section class="admin-other-questions">
              ${renderVolumeCard(
                otherGroup,
                volumeDefinition('other')
              )}
            </section>
          `
          : ''
      }
    `;

    target
      .querySelectorAll(
        '.admin-progress-tab'
      )
      .forEach(button => {
        button.addEventListener(
          'click',
          () => {
            setProgressTab(
              target,
              Number(
                button.dataset.setNumber
              )
            );
          }
        );
      });

    target
      .querySelectorAll(
        '.unlock-question'
      )
      .forEach(button => {
        button.addEventListener(
          'click',
          () => {
            allowSingleCorrection({
              studentId,
              questionId:
                button.dataset.questionId,
              target,
              button
            });
          }
        );
      });

    target
      .querySelectorAll(
        '.unlock-volume'
      )
      .forEach(button => {
        button.addEventListener(
          'click',
          () => {
            const group =
              completeGroups.find(
                candidate =>
                  candidate.key ===
                  button.dataset.volumeKey
              );

            if (group) {
              allowVolumeCorrections({
                studentId,
                group,
                target,
                button
              });
            }
          }
        );
      });
  } catch (error) {
    target.innerHTML = `
      <p class="error-text">
        ${escapeHtml(error.message)}
      </p>
    `;
  }
}

document
  .getElementById('student-form')
  ?.addEventListener(
    'submit',
    createStudent
  );

document
  .getElementById('load-students')
  ?.addEventListener(
    'click',
    loadStudents
  );

const savedPassword =
  sessionStorage.getItem(
    'sat_admin_password'
  );

if (savedPassword) {
  const passwordInput =
    document.getElementById(
      'admin-password'
    );

  if (passwordInput) {
    passwordInput.value =
      savedPassword;
  }

  loadStudents();
}
