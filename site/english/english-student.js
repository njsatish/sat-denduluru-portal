(() => {
  'use strict';
  const params = new URLSearchParams(location.search);
  const normalize = value => {
    const id = String(value || '').trim().toLowerCase();
    return /^[a-z0-9_-]{1,80}$/.test(id) ? id : '';
  };
  const studentId = normalize(params.get('student')) || normalize(localStorage.getItem('sat_user'));
  if (studentId && !params.get('student')) {
    params.set('student', studentId);
    history.replaceState(null, '', `${location.pathname}?${params}${location.hash}`);
  }
  if (studentId) localStorage.setItem('sat_user', studentId);
  const storageKey = studentId ? `satEnglish300Progress:${studentId}` : 'sat300-nireekshan-progress-v1';

  function studentizeLinks() {
    document.querySelectorAll('a[href]').forEach(anchor => {
      const raw = anchor.getAttribute('href');
      if (!raw || raw.startsWith('#') || raw.startsWith('mailto:') || raw.startsWith('javascript:')) return;
      try {
        const url = new URL(raw, location.href);
        if (url.origin !== location.origin) return;
        const isHtml = url.pathname.endsWith('.html') || url.pathname.endsWith('/');
        if (!isHtml || !studentId) return;
        url.searchParams.set('student', studentId);
        anchor.href = `${url.pathname}${url.search}${url.hash}`;
      } catch (error) {
        console.warn('Unable to preserve student link:', raw, error);
      }
    });
  }

  function setStudentName(name) {
    document.querySelectorAll('[data-student-name]').forEach(node => {
      node.textContent = name || studentId || 'Student';
    });
  }

  async function loadStudentName() {
    setStudentName(studentId);
    if (!studentId) return;
    try {
      const response = await fetch('https://hvvnxnlzdt7h4w53prvjavlgom0twjbu.lambda-url.us-east-1.on.aws/', {
        method: 'POST', headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'getStudent', userId:studentId}), cache:'no-store'
      });
      if (!response.ok) return;
      const data = await response.json();
      setStudentName(data.student?.displayName || studentId);
    } catch (_) { /* ID remains visible when the service is unavailable. */ }
  }

  window.SATEnglishStudent = {studentId, storageKey, studentizeLinks};
  const ready = () => { studentizeLinks(); loadStudentName(); };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready, {once:true});
  else ready();
})();
