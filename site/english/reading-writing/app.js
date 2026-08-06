(() => {
  'use strict';

  const PROGRESS_API = "https://l2m5cxuri2eojykndfbabmuthi0xfjya.lambda-url.us-east-1.on.aws/";
  const questions = window.SAT_RW_QUESTIONS || [];
  const letters = ['A', 'B', 'C', 'D'];
  const state = {
    studentId: '',
    profile: null,
    progress: new Map(),
    view: [...questions],
    currentIndex: 0,
    mode: 'all',
    timedAnswers: new Map(),
    timerId: null,
    secondsRemaining: 32 * 60,
    busy: false,
    localPreview: PROGRESS_API.includes('__PROGRESS_API__')
  };

  const byId = id => document.getElementById(id);
  const els = {
    shell: byId('app-shell'), student: byId('student-name'), status: byId('status-panel'),
    mastered: byId('mastered-count'), attempted: byId('attempted-label'), bar: byId('overall-bar'),
    workspace: byId('practice-workspace'), nav: byId('question-nav'), setTitle: byId('set-title'),
    filters: byId('filters'), domainFilter: byId('domain-filter'), skillFilter: byId('skill-filter'),
    difficultyFilter: byId('difficulty-filter'), statusFilter: byId('status-filter'),
    exitMode: byId('exit-mode'), timer: byId('timer'), timerValue: byId('timer-value'),
    finishTimed: byId('finish-timed'), card: byId('question-card'), empty: byId('empty-state'),
    content: byId('question-content'), number: byId('question-number'), domain: byId('question-domain'),
    skill: byId('question-skill'), difficulty: byId('question-difficulty'), passage: byId('passage-area'),
    prompt: byId('question-prompt'), form: byId('answer-form'), options: byId('answer-options'),
    submit: byId('submit-answer'), previous: byId('previous-question'), next: byId('next-question'),
    feedback: byId('answer-feedback'), notes: byId('question-notes'), saveNote: byId('save-note'),
    noteStatus: byId('note-status'), summary: byId('timed-summary'), timedScore: byId('timed-score'),
    timedDetail: byId('timed-detail'), returnPractice: byId('return-to-practice')
  };

  function normalizeStudent(value) {
    const id = String(value || '').trim().toLowerCase();
    return /^[a-z0-9_-]{1,80}$/.test(id) ? id : '';
  }

  function tokenUsername() {
    try {
      const token = sessionStorage.getItem('sat_id_token');
      if (!token) return '';
      const raw = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      const claims = JSON.parse(decodeURIComponent(atob(raw.padEnd(Math.ceil(raw.length / 4) * 4, '='))
        .split('').map(char => `%${char.charCodeAt(0).toString(16).padStart(2, '0')}`).join('')));
      return normalizeStudent(claims['cognito:username'] || claims.username);
    } catch (error) {
      console.warn('Unable to read the signed-in student identity.', error);
      return '';
    }
  }

  function getStudentId() {
    const params = new URLSearchParams(location.search);
    return normalizeStudent(params.get('student')) ||
      normalizeStudent(localStorage.getItem('sat_user')) || tokenUsername();
  }

  function showStatus(message, type = 'error') {
    els.status.hidden = false;
    els.status.className = `status-panel ${type}`;
    els.status.textContent = message;
  }

  function clearStatus() {
    els.status.hidden = true;
    els.status.textContent = '';
  }

  async function apiRequest(payload) {
    if (state.localPreview) return previewApi(payload);
    const token = sessionStorage.getItem('sat_access_token') || sessionStorage.getItem('sat_id_token');
    const response = await fetch(PROGRESS_API, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {})
      },
      body: JSON.stringify(payload)
    });
    let data = {};
    try { data = await response.json(); } catch (error) { data = {}; }
    if (!response.ok) {
      const problem = new Error(data.message || data.error || `Request failed (${response.status})`);
      problem.status = response.status;
      problem.code = data.code;
      throw problem;
    }
    return data;
  }

  function previewApi(payload) {
    const key = `sat-rw-preview:${state.studentId}`;
    const stored = JSON.parse(localStorage.getItem(key) || '[]');
    if (payload.action === 'getStudent') return { student: { displayName: state.studentId || 'Preview Student', active: true } };
    if (payload.action === 'progress') return { items: stored };
    if (payload.action === 'record') {
      const existingIndex = stored.findIndex(item => item.questionId === payload.questionId);
      const existing = existingIndex >= 0 ? stored[existingIndex] : null;
      if (existing && existing.lastResult === 'correct') return Promise.reject(Object.assign(new Error('This question has already been completed'), { status: 409 }));
      if (existing && existing.lastResult === 'incorrect' && existing.locked !== false && existing.correctionAllowed !== true) return Promise.reject(Object.assign(new Error('This question is locked'), { status: 409 }));
      const item = {
        userId: state.studentId, questionId: payload.questionId, lastChoice: payload.choice,
        lastResult: payload.correct ? 'correct' : 'incorrect', category: payload.category,
        attempts: Number(existing?.attempts || 0) + 1, correctCount: Number(existing?.correctCount || 0) + (payload.correct ? 1 : 0),
        locked: true, correctionAllowed: false, firstAt: existing?.firstAt || new Date().toISOString(), lastAt: new Date().toISOString()
      };
      if (existingIndex >= 0) stored[existingIndex] = item; else stored.push(item);
      localStorage.setItem(key, JSON.stringify(stored));
      return item;
    }
    return {};
  }

  function progressFor(question) { return state.progress.get(question.id) || null; }
  function statusFor(question) {
    const item = progressFor(question);
    if (!item?.lastResult) return 'unanswered';
    if (item.lastResult === 'correct') return 'correct';
    if (item.locked === false || item.correctionAllowed === true) return 'available';
    return 'incorrect';
  }

  function updateProgressSummary() {
    const pilot = questions.map(progressFor).filter(Boolean);
    const mastered = pilot.filter(item => item.lastResult === 'correct').length;
    const attempted = pilot.filter(item => item.lastResult).length;
    els.mastered.textContent = mastered;
    els.attempted.textContent = `${attempted} attempted · ${attempted - mastered} currently incorrect`;
    els.bar.style.width = `${(mastered / questions.length) * 100}%`;
    document.querySelectorAll('[data-domain-progress]').forEach(element => {
      const domain = element.dataset.domainProgress;
      const domainQuestions = questions.filter(question => question.domain === domain);
      const domainMastered = domainQuestions.filter(question => statusFor(question) === 'correct').length;
      element.textContent = `${domainMastered}/${domainQuestions.length} mastered`;
    });
  }

  function buildFilterOptions() {
    [...new Set(questions.map(question => question.domain))].forEach(value => els.domainFilter.add(new Option(value, value)));
    updateSkillOptions();
  }

  function updateSkillOptions() {
    const selected = els.skillFilter.value;
    const domain = els.domainFilter.value;
    const skills = [...new Set(questions.filter(question => !domain || question.domain === domain).map(question => question.skill))];
    els.skillFilter.innerHTML = '<option value="">All skills</option>';
    skills.forEach(value => els.skillFilter.add(new Option(value, value)));
    if (skills.includes(selected)) els.skillFilter.value = selected;
  }

  function filteredQuestions() {
    return questions.filter(question =>
      (!els.domainFilter.value || question.domain === els.domainFilter.value) &&
      (!els.skillFilter.value || question.skill === els.skillFilter.value) &&
      (!els.difficultyFilter.value || question.difficulty === els.difficultyFilter.value) &&
      (!els.statusFilter.value || statusFor(question) === els.statusFilter.value)
    );
  }

  function applyFilters() {
    if (state.mode !== 'all') return;
    state.view = filteredQuestions();
    state.currentIndex = 0;
    const parts = [els.domainFilter.value, els.skillFilter.value, els.difficultyFilter.value, els.statusFilter.options[els.statusFilter.selectedIndex].text]
      .filter(value => value && !value.startsWith('All '));
    els.setTitle.textContent = parts.length ? parts.join(' · ') : 'All 40';
    renderNavigator();
    renderCurrent();
  }

  function shuffle(values) {
    const copy = [...values];
    for (let index = copy.length - 1; index > 0; index -= 1) {
      const target = Math.floor(Math.random() * (index + 1));
      [copy[index], copy[target]] = [copy[target], copy[index]];
    }
    return copy;
  }

  function startMode(mode) {
    stopTimer();
    clearStatus();
    els.summary.hidden = true;
    state.mode = mode;
    state.currentIndex = 0;
    state.timedAnswers.clear();
    els.exitMode.hidden = mode === 'all';
    els.filters.hidden = mode !== 'all';
    els.timer.hidden = mode !== 'timed';

    if (mode === 'all') {
      state.view = filteredQuestions();
      els.setTitle.textContent = 'All 40';
    } else if (mode === 'mixed') {
      const eligible = questions.filter(question => ['unanswered', 'available'].includes(statusFor(question)));
      state.view = shuffle(eligible).slice(0, 10);
      els.setTitle.textContent = 'Mixed 10';
      if (!state.view.length) showStatus('There are no unanswered or correction-available questions for a mixed set.');
    } else if (mode === 'incorrect') {
      state.view = questions.filter(question => ['incorrect', 'available'].includes(statusFor(question)));
      els.setTitle.textContent = 'Incorrect questions';
      if (!state.view.length) showStatus('No incorrect pilot questions are currently recorded.', 'success');
    } else if (mode === 'timed') {
      const unanswered = questions.filter(question => statusFor(question) === 'unanswered');
      if (unanswered.length < 27) {
        state.mode = 'all';
        els.exitMode.hidden = true;
        els.filters.hidden = false;
        els.timer.hidden = true;
        state.view = filteredQuestions();
        showStatus(`A timed module needs 27 unanswered questions. ${unanswered.length} remain. Use regular practice for the rest.`);
      } else {
        state.view = shuffle(unanswered).slice(0, 27);
        els.setTitle.textContent = 'Timed module · 27';
        state.secondsRemaining = 32 * 60;
        updateTimer();
        state.timerId = window.setInterval(() => {
          state.secondsRemaining -= 1;
          updateTimer();
          if (state.secondsRemaining <= 0) finishTimedModule();
        }, 1000);
      }
    }
    renderNavigator();
    renderCurrent();
    els.workspace.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function stopTimer() {
    if (state.timerId) window.clearInterval(state.timerId);
    state.timerId = null;
  }

  function updateTimer() {
    const minutes = Math.floor(Math.max(0, state.secondsRemaining) / 60);
    const seconds = Math.max(0, state.secondsRemaining) % 60;
    els.timerValue.textContent = `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
  }

  function renderNavigator() {
    els.nav.innerHTML = '';
    state.view.forEach((question, index) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = `nav-question ${statusFor(question)}${index === state.currentIndex ? ' current' : ''}${state.timedAnswers.has(question.id) ? ' session-answered' : ''}`;
      button.textContent = question.number;
      button.title = `Question ${question.number}: ${question.skill}`;
      button.setAttribute('aria-label', `Question ${question.number}, ${statusFor(question)}`);
      button.addEventListener('click', () => { state.currentIndex = index; renderNavigator(); renderCurrent(); });
      els.nav.appendChild(button);
    });
  }

  function passageMarkup(question) {
    const pieces = [];
    if (question.text1) pieces.push(`<p><span class="text-label">Text 1</span>${escapeHtml(question.text1.replace(/^Text 1:\s*/, ''))}</p>`);
    if (question.text2) pieces.push(`<p><span class="text-label">Text 2</span>${escapeHtml(question.text2.replace(/^Text 2:\s*/, ''))}</p>`);
    if (question.passage) pieces.push(`<p>${escapeHtml(question.passage)}</p>`);
    if (question.notes) pieces.push(`<span class="text-label">Student notes</span><ul class="notes-list">${question.notes.map(note => `<li>${escapeHtml(note)}</li>`).join('')}</ul>`);
    if (question.table) pieces.push(`<table class="data-table"><caption>${escapeHtml(question.table.caption)}</caption><thead><tr>${question.table.headers.map(value => `<th scope="col">${escapeHtml(value)}</th>`).join('')}</tr></thead><tbody>${question.table.rows.map(row => `<tr>${row.map(value => `<td>${escapeHtml(value)}</td>`).join('')}</tr>`).join('')}</tbody></table>`);
    return pieces.join('');
  }

  function escapeHtml(value) {
    const element = document.createElement('span');
    element.textContent = String(value ?? '');
    return element.innerHTML;
  }

  function renderCurrent() {
    if (!state.view.length) {
      els.empty.hidden = false;
      els.content.hidden = true;
      return;
    }
    const question = state.view[state.currentIndex];
    const item = progressFor(question);
    const status = statusFor(question);
    const timedChoice = state.timedAnswers.get(question.id);
    els.empty.hidden = true;
    els.content.hidden = false;
    els.number.textContent = `Question ${question.number} · ${state.currentIndex + 1} of ${state.view.length}`;
    els.domain.textContent = question.domain;
    els.skill.textContent = question.skill;
    els.difficulty.textContent = question.difficulty;
    els.passage.innerHTML = passageMarkup(question);
    els.prompt.textContent = question.prompt;
    els.options.innerHTML = '';
    const locked = state.mode !== 'timed' && ['correct', 'incorrect'].includes(status);
    question.choices.forEach((choice, index) => {
      const label = document.createElement('label');
      label.className = `choice${locked ? ' locked' : ''}`;
      if (status === 'correct' && index === question.answerIndex) label.classList.add('correct-choice');
      if (status === 'incorrect' && Number(item?.lastChoice) === index) label.classList.add('wrong-choice');
      const input = document.createElement('input');
      input.type = 'radio'; input.name = 'answer'; input.value = index; input.disabled = locked || state.busy;
      if (state.mode === 'timed' && timedChoice === index) input.checked = true;
      if (state.mode !== 'timed' && status === 'correct' && index === question.answerIndex) input.checked = true;
      label.append(input);
      label.insertAdjacentHTML('beforeend', `<span class="choice-letter">${letters[index]}</span><span>${escapeHtml(choice)}</span>`);
      els.options.appendChild(label);
    });
    els.submit.disabled = locked || state.busy;
    els.submit.textContent = state.mode === 'timed' ? (state.timedAnswers.has(question.id) ? 'Update answer' : 'Save answer') : status === 'available' ? 'Submit correction' : 'Submit answer';
    els.previous.disabled = state.currentIndex === 0;
    els.next.disabled = state.currentIndex === state.view.length - 1;
    renderFeedback(question, status, item);
    els.notes.value = localStorage.getItem(noteKey(question.id)) || '';
    els.noteStatus.textContent = '';
    if (state.mode === 'timed') {
      history.replaceState(null, '', `${location.pathname}${location.search}`);
    } else {
      history.replaceState(null, '', `${location.pathname}${location.search}#${question.id}`);
    }
    els.card.focus({ preventScroll: true });
  }

  function renderFeedback(question, status, item) {
    els.feedback.hidden = true;
    els.feedback.className = 'feedback';
    els.feedback.innerHTML = '';
    if (state.mode === 'timed' || status === 'unanswered') return;
    els.feedback.hidden = false;
    if (status === 'correct') {
      els.feedback.classList.add('correct');
      els.feedback.innerHTML = `<h3>Correct — ${letters[question.answerIndex]}</h3><p>${escapeHtml(question.explanation)}</p><div class="answer-breakdown">${question.choices.map((choice, index) => `<p><strong>${letters[index]}.</strong> ${index === question.answerIndex ? 'Correct.' : escapeHtml(question.distractors[index])}</p>`).join('')}</div><p class="strategy"><strong>Strategy:</strong> ${escapeHtml(question.strategy)}</p>`;
    } else if (status === 'available') {
      els.feedback.classList.add('available');
      els.feedback.innerHTML = '<h3>Correction available</h3><p>Your previous answer was incorrect. You may make one approved correction attempt. The answer remains hidden until you answer correctly.</p>';
    } else {
      els.feedback.classList.add('incorrect');
      els.feedback.innerHTML = `<h3>Incorrect — correction locked</h3><p>Your selected answer was ${Number.isInteger(Number(item?.lastChoice)) ? letters[Number(item.lastChoice)] : 'recorded'}. The correct answer and explanation remain hidden. An administrator can allow a correction from the admin page.</p>`;
    }
  }

  async function submitCurrent(event) {
    event.preventDefault();
    const question = state.view[state.currentIndex];
    const selected = els.form.querySelector('input[name="answer"]:checked');
    if (!selected) { showStatus('Select an answer before submitting.'); return; }
    const choice = Number(selected.value);
    if (state.mode === 'timed') {
      state.timedAnswers.set(question.id, choice);
      renderNavigator();
      const nextUnanswered = state.view.findIndex((candidate, index) => index > state.currentIndex && !state.timedAnswers.has(candidate.id));
      if (nextUnanswered >= 0) state.currentIndex = nextUnanswered;
      else if (state.currentIndex < state.view.length - 1) state.currentIndex += 1;
      renderNavigator(); renderCurrent();
      return;
    }
    if (state.busy) return;
    state.busy = true; clearStatus(); renderCurrent();
    try {
      const saved = await apiRequest({
        action: 'record', userId: state.studentId, questionId: question.id,
        correct: choice === question.answerIndex, choice, category: question.domain
      });
      state.progress.set(question.id, saved.item || saved);
      updateProgressSummary(); renderNavigator(); renderCurrent();
      if (choice !== question.answerIndex) showStatus('Answer recorded as incorrect. The question is locked until a correction is allowed.');
    } catch (error) {
      if (error.status === 409) await loadProgress();
      showStatus(error.message || 'The answer could not be saved.');
    } finally {
      state.busy = false; renderCurrent();
    }
  }

  async function finishTimedModule() {
    if (state.mode !== 'timed' || state.busy) return;
    stopTimer();
    state.busy = true;
    els.finishTimed.disabled = true;
    clearStatus();
    const attempted = state.view.filter(question => state.timedAnswers.has(question.id));
    let savedCount = 0;
    let correctCount = 0;
    for (const question of attempted) {
      const choice = state.timedAnswers.get(question.id);
      const correct = choice === question.answerIndex;
      try {
        const saved = await apiRequest({ action: 'record', userId: state.studentId, questionId: question.id, correct, choice, category: question.domain });
        state.progress.set(question.id, saved.item || saved);
        savedCount += 1;
        if (correct) correctCount += 1;
      } catch (error) {
        console.warn(`Unable to save ${question.id}`, error);
      }
    }
    state.busy = false;
    els.finishTimed.disabled = false;
    updateProgressSummary();
    els.workspace.hidden = true;
    els.summary.hidden = false;
    els.timedScore.textContent = `${correctCount} of ${attempted.length} answered questions correct`;
    els.timedDetail.textContent = `${savedCount} answers were saved. Incorrect answers are now locked and do not reveal the correct choice. Unanswered questions were not recorded.`;
    els.summary.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function noteKey(questionId) { return `satRwNote:${state.studentId}:${questionId}`; }
  function saveNote() {
    const question = state.view[state.currentIndex];
    if (!question) return;
    localStorage.setItem(noteKey(question.id), els.notes.value);
    els.noteStatus.textContent = 'Saved';
    window.setTimeout(() => { els.noteStatus.textContent = ''; }, 1500);
  }

  async function loadProgress() {
    const data = await apiRequest({ action: 'progress', userId: state.studentId });
    state.progress = new Map((data.items || []).filter(item => /^rwq\d{3}$/i.test(item.questionId || '')).map(item => [item.questionId, item]));
    updateProgressSummary(); renderNavigator(); renderCurrent();
  }

  async function initialize() {
    if (questions.length !== 40) {
      showStatus(`The pilot question bank is incomplete (${questions.length}/40).`);
      return;
    }
    state.studentId = getStudentId();
    if (!state.studentId) {
      const returnTo = `${location.pathname}${location.search}${location.hash}`;
      location.assign(`/login.html?returnTo=${encodeURIComponent(returnTo)}`);
      return;
    }
    localStorage.setItem('sat_user', state.studentId);
    buildFilterOptions();
    try {
      const profile = await apiRequest({ action: 'getStudent', userId: state.studentId });
      if (profile.student && profile.student.active === false) throw Object.assign(new Error('This student account is inactive.'), { status: 403 });
      state.profile = profile.student || { displayName: state.studentId };
      els.student.textContent = state.profile.displayName || state.studentId;
      await loadProgress();
      clearStatus();
    } catch (error) {
      els.student.textContent = state.studentId;
      showStatus(error.status === 404 ? 'This student account was not created by the administrator.' : `Progress could not be loaded: ${error.message}`);
      els.submit.disabled = true;
    }
    state.view = [...questions];
    const requested = location.hash.slice(1);
    const requestedIndex = state.view.findIndex(question => question.id === requested);
    state.currentIndex = requestedIndex >= 0 ? requestedIndex : 0;
    renderNavigator(); renderCurrent();
    els.shell.setAttribute('aria-busy', 'false');
  }

  els.form.addEventListener('submit', submitCurrent);
  els.previous.addEventListener('click', () => { if (state.currentIndex > 0) { state.currentIndex -= 1; renderNavigator(); renderCurrent(); } });
  els.next.addEventListener('click', () => { if (state.currentIndex < state.view.length - 1) { state.currentIndex += 1; renderNavigator(); renderCurrent(); } });
  els.saveNote.addEventListener('click', saveNote);
  els.domainFilter.addEventListener('change', () => { updateSkillOptions(); applyFilters(); });
  [els.skillFilter, els.difficultyFilter, els.statusFilter].forEach(element => element.addEventListener('change', applyFilters));
  byId('all-mode').addEventListener('click', () => startMode('all'));
  byId('mixed-mode').addEventListener('click', () => startMode('mixed'));
  byId('timed-mode').addEventListener('click', () => startMode('timed'));
  byId('incorrect-mode').addEventListener('click', () => startMode('incorrect'));
  els.exitMode.addEventListener('click', () => startMode('all'));
  els.finishTimed.addEventListener('click', finishTimedModule);
  els.returnPractice.addEventListener('click', () => { els.workspace.hidden = false; els.summary.hidden = true; startMode('all'); });
  document.querySelectorAll('.domain-card').forEach(button => button.addEventListener('click', () => {
    startMode('all'); els.domainFilter.value = button.dataset.domain; updateSkillOptions(); applyFilters();
  }));
  window.addEventListener('beforeunload', event => {
    if (state.mode === 'timed' && state.timedAnswers.size) { event.preventDefault(); event.returnValue = ''; }
  });

  initialize();
})();
