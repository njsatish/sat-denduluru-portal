const PROGRESS_API = 'https://qi7mrsjuu5jj4nsmiukcprtvya0scnrg.lambda-url.us-east-1.on.aws/';
const LOGIN_PATH = '/login.html';
const MATH_TOTAL = 600;
const ENGLISH_TOTAL = 375;

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
    throw new ApiError(data.message || data.error || `Request failed (${response.status})`,
      response.status, data.code);
  }
  return data;
}

function getAdminPassword() {
  return document.getElementById('admin-password').value;
}
function setStatus(message, type = '') {
  const status = document.getElementById('admin-status');
  status.className = `status ${type}`;
  status.textContent = message;
}
function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, character => ({
    '&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'
  })[character]);
}
async function copyText(text) {
  try { await navigator.clipboard.writeText(text); }
  catch {
    const input=document.createElement('textarea');
    input.value=text; document.body.appendChild(input); input.select();
    document.execCommand('copy'); input.remove();
  }
}
function normalizeUsername(value) {
  return String(value||'').trim().toLowerCase().replace(/[^a-z0-9_-]/g,'');
}
function loginUrl() { return new URL(LOGIN_PATH, location.origin).href; }
function isMathQuestionId(value) {
  const match=/^(?:v[123]q|s2v[123]q)(\d{3})$/.exec(String(value||''));
  if(!match)return false;
  const number=Number(match[1]);
  return number>=1&&number<=100;
}
function showCredentials({title,displayName,username,temporaryPassword}) {
  document.getElementById('credential-title').textContent=title;
  document.getElementById('credential-name').textContent=displayName||username;
  document.getElementById('credential-username').textContent=username;
  document.getElementById('credential-password').textContent=temporaryPassword;
  document.getElementById('credential-login').textContent=loginUrl();
  document.getElementById('credential-box').classList.add('show');
}
function credentialText() {
  return ['SAT Student Login',loginUrl(),'',
    `Username: ${document.getElementById('credential-username').textContent}`,
    `Temporary password: ${document.getElementById('credential-password').textContent}`,'',
    'You will be asked to choose a new password on first login.'].join('\n');
}

let loadedStudents=[];
const overviewByStudent=new Map();

async function loadStudents() {
  const password=getAdminPassword();
  if(!password){setStatus('Enter the administrator password.','error');return;}
  sessionStorage.setItem('sat_admin_password',password);
  setStatus('Loading students…');
  try{
    const data=await apiRequest({action:'listStudents',adminPassword:password});
    loadedStudents=data.students||[];
    renderStudents(loadedStudents);
    document.getElementById('stat-students').textContent=loadedStudents.length;
    document.getElementById('stat-active').textContent=
      loadedStudents.filter(student=>student.active!==false).length;
    document.getElementById('stat-corrections').textContent='…';
    await Promise.allSettled(loadedStudents.map(student=>loadOverview(student.studentId)));
    refreshStats();
    setStatus(`${loadedStudents.length} student(s) loaded.`,'success');
  }catch(error){setStatus(error.message,'error');}
}

async function createStudent(event) {
  event.preventDefault();
  const adminPassword=getAdminPassword();
  const displayName=document.getElementById('display-name').value.trim();
  const username=normalizeUsername(document.getElementById('username').value);
  const email=document.getElementById('email').value.trim();
  if(!adminPassword||!displayName||!username){
    setStatus('Administrator password, student name, and username are required.','error');return;
  }
  setStatus('Creating Cognito login and student profile…');
  try{
    const data=await apiRequest({
      action:'createStudentAccount',adminPassword,displayName,username,email:email||undefined
    });
    showCredentials({
      title:'✓ Student created',displayName:data.student.displayName,
      username:data.student.studentId,temporaryPassword:data.temporaryPassword
    });
    document.getElementById('student-form').reset();
    setStatus(`Created ${data.student.displayName}.`,'success');
    await loadStudents();
  }catch(error){setStatus(error.message,'error');}
}

function accountBadge(overview) {
  const account=overview?.account;
  if(!account)return '<span class="badge warn">Login not provisioned</span>';
  if(!account.enabled)return '<span class="badge off">● Disabled</span>';
  const status=String(account.userStatus||'Active').replaceAll('_',' ');
  const cls=status==='FORCE CHANGE PASSWORD'?'badge warn':'badge';
  return `<span class="${cls}">${escapeHtml(status)}</span>`;
}

function renderStudents(students) {
  const container=document.getElementById('student-list');
  if(!students.length){container.innerHTML='<div class="empty">No students have been created yet.</div>';return;}
  container.innerHTML=students.map(student=>`
    <article class="student" data-student-id="${escapeHtml(student.studentId)}"
      data-search="${escapeHtml(`${student.displayName} ${student.studentId}`.toLowerCase())}">
      <div class="student-main">
        <div class="identity">
          <div class="avatar">${escapeHtml((student.displayName||student.studentId).slice(0,1).toUpperCase())}</div>
          <div><h3>${escapeHtml(student.displayName)}</h3>
            <p>Username: <strong>${escapeHtml(student.studentId)}</strong></p>
            <div class="badges account-badges">
              <span class="${student.active===false?'badge off':'badge'}">${student.active===false?'● Disabled':'● Active'}</span>
              <span class="badge warn">Loading login…</span>
            </div>
          </div>
        </div>
        <div class="progress-grid">
          <div class="progress math-progress"><small>Math</small><strong>Loading…</strong>
            <div class="bar"><span style="--pct:0%"></span></div></div>
          <div class="progress english-progress"><small>English</small><strong>Loading…</strong>
            <div class="bar"><span style="--pct:0%"></span></div></div>
        </div>
        <div class="actions">
          <button class="btn view-progress" type="button">View Progress</button>
          <button class="btn reset-password" type="button">Reset Password</button>
          <button class="btn toggle-active ${student.active===false?'primary':'danger'}"
            data-active="${student.active===false?'true':'false'}" type="button">
            ${student.active===false?'Enable Account':'Disable'}</button>
        </div>
      </div><div class="details"></div>
    </article>`).join('');
  wireStudentActions(container); applySearch();
}

function wireStudentActions(container) {
  container.querySelectorAll('.view-progress').forEach(button=>{
    button.addEventListener('click',async()=>{
      const article=button.closest('.student'); const details=article.querySelector('.details');
      if(details.classList.contains('open')){
        details.classList.remove('open');details.innerHTML='';button.textContent='View Progress';return;
      }
      button.textContent='Hide Progress';
      await loadStudentProgress(article.dataset.studentId,details);
    });
  });
  container.querySelectorAll('.reset-password').forEach(button=>{
    button.addEventListener('click',async()=>{
      const article=button.closest('.student');const studentId=article.dataset.studentId;
      const student=loadedStudents.find(value=>value.studentId===studentId);
      if(!confirm(`Reset the login password for ${student?.displayName||studentId}?`))return;
      button.disabled=true;
      try{
        const data=await apiRequest({action:'resetStudentPassword',adminPassword:getAdminPassword(),studentId});
        showCredentials({title:'✓ Temporary password created',
          displayName:student?.displayName||studentId,username:studentId,
          temporaryPassword:data.temporaryPassword});
        setStatus(`Temporary password created for ${studentId}.`,'success');
        await loadOverview(studentId);
      }catch(error){setStatus(error.message,'error');}
      finally{button.disabled=false;}
    });
  });
  container.querySelectorAll('.toggle-active').forEach(button=>{
    button.addEventListener('click',async()=>{
      const article=button.closest('.student');const studentId=article.dataset.studentId;
      const active=button.dataset.active==='true';const verb=active?'enable':'disable';
      if(!confirm(`${verb[0].toUpperCase()+verb.slice(1)} ${studentId}?`))return;
      button.disabled=true;
      try{
        await apiRequest({action:'setStudentActive',adminPassword:getAdminPassword(),studentId,active});
        setStatus(`${studentId} is now ${active?'enabled':'disabled'}.`,'success');
        await loadStudents();
      }catch(error){setStatus(error.message,'error');button.disabled=false;}
    });
  });
}

async function loadOverview(studentId) {
  const article=document.querySelector(`.student[data-student-id="${CSS.escape(studentId)}"]`);
  if(!article)return;
  try{
    const overview=await apiRequest({action:'adminStudentOverview',adminPassword:getAdminPassword(),studentId});
    overviewByStudent.set(studentId,overview);
    const math=overview.math||{mastered:0,attempted:0,total:MATH_TOTAL};
    const english=overview.english||{learned:0,total:ENGLISH_TOTAL};
    const mathPct=Math.round((math.mastered/Math.max(1,math.total||MATH_TOTAL))*100);
    const englishPct=Math.round((english.learned/Math.max(1,english.total||ENGLISH_TOTAL))*100);
    const mathBox=article.querySelector('.math-progress');
    mathBox.querySelector('strong').textContent=`${math.mastered} mastered · ${math.attempted} attempted`;
    mathBox.querySelector('.bar span').style.setProperty('--pct',`${mathPct}%`);
    const englishBox=article.querySelector('.english-progress');
    englishBox.querySelector('strong').textContent=`${english.learned} of ${english.total||ENGLISH_TOTAL} learned`;
    englishBox.querySelector('.bar span').style.setProperty('--pct',`${englishPct}%`);
    const activeStudent=loadedStudents.find(value=>value.studentId===studentId);
    article.querySelector('.account-badges').innerHTML=`
      <span class="${activeStudent?.active===false?'badge off':'badge'}">
        ${activeStudent?.active===false?'● Disabled':'● Active'}</span>${accountBadge(overview)}`;
  }catch(error){
    article.querySelector('.math-progress strong').textContent='Unable to load';
    article.querySelector('.english-progress strong').textContent='Unable to load';
    console.warn('Student overview failed',studentId,error);
  }
}

function refreshStats() {
  let corrections=0;
  overviewByStudent.forEach(value=>{corrections+=Number(value?.math?.awaitingCorrections||0);});
  document.getElementById('stat-corrections').textContent=corrections;
}

async function loadStudentProgress(studentId,target) {
  target.classList.add('open');target.innerHTML='<p class="note">Loading Math progress and correction approvals…</p>';
  try{
    const data=await apiRequest({action:'adminProgress',adminPassword:getAdminPassword(),studentId});
    const mathItems=(data.items||[]).filter(item=>isMathQuestionId(item.questionId));
    const mastered=mathItems.filter(item=>Number(item.correctCount||0)>0||item.lastResult==='correct').length;
    const attempted=mathItems.filter(item=>item.lastResult==='correct'||item.lastResult==='incorrect').length;
    const locked=mathItems.filter(item=>item.lastResult==='incorrect'&&item.locked!==false&&item.correctionAllowed!==true);
    target.innerHTML=`
      <div class="summary"><span><strong>${mastered}</strong> Math mastered</span>
        <span><strong>${attempted}</strong> Math attempted</span>
        <span><strong>${locked.length}</strong> corrections awaiting approval</span></div>
      <h4>Questions awaiting correction approval</h4>
      ${locked.length?locked.map(item=>`
        <div class="locked"><div><strong>${escapeHtml(item.questionId)}</strong>
          <span>${escapeHtml(item.category||'Unknown category')}</span>
          <span>Last answer: ${escapeHtml(item.lastChoice??'')}</span></div>
          <button class="btn primary unlock-question" data-question-id="${escapeHtml(item.questionId)}"
            type="button">Allow correction</button></div>`).join(''):
        '<p class="note">No Math corrections are awaiting approval.</p>'}`;
    target.querySelectorAll('.unlock-question').forEach(button=>{
      button.addEventListener('click',async()=>{
        button.disabled=true;
        try{
          await apiRequest({action:'unlockQuestion',adminPassword:getAdminPassword(),
            studentId,questionId:button.dataset.questionId});
          setStatus(`${button.dataset.questionId} is available for one correction attempt.`,'success');
          await loadStudentProgress(studentId,target);await loadOverview(studentId);refreshStats();
        }catch(error){setStatus(error.message,'error');button.disabled=false;}
      });
    });
  }catch(error){target.innerHTML=`<p class="status error">${escapeHtml(error.message)}</p>`;}
}

function applySearch() {
  const query=document.getElementById('student-search').value.trim().toLowerCase();
  document.querySelectorAll('.student').forEach(article=>{
    article.hidden=Boolean(query&&!article.dataset.search.includes(query));
  });
}

document.getElementById('username').addEventListener('input',event=>{
  event.target.value=normalizeUsername(event.target.value);
});
document.getElementById('student-form').addEventListener('submit',createStudent);
document.getElementById('load-students').addEventListener('click',loadStudents);
document.getElementById('student-search').addEventListener('input',applySearch);
document.getElementById('copy-login-details').addEventListener('click',async event=>{
  await copyText(credentialText());event.target.textContent='Copied ✓';
  setTimeout(()=>{event.target.textContent='Copy Login Details';},1400);
});
const savedPassword=sessionStorage.getItem('sat_admin_password');
if(savedPassword){document.getElementById('admin-password').value=savedPassword;loadStudents();}
