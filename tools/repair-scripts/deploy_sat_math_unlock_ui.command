#!/usr/bin/env python3
from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PROFILE = "denduluru"
EXPECTED_ACCOUNT = "989174615155"
REGION = "us-east-1"
BUCKET = "sat-prep-josh"
APP_KEY = "math/app.js"
DISTRIBUTION_ID = "E2WHKAAIHGKMVF"

HTML_KEYS = [
    "math/volume-1-algebra-foundations.html",
    "math/volume-2-advanced-math.html",
    "math/volume-3-data-geometry-trigonometry.html",
    "math/set-2-volume-1-algebra.html",
    "math/set-2-volume-2-advanced-math.html",
    "math/set-2-volume-3-data-geometry-trigonometry.html",
]

STAMP = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
BUILD = f"20260801-unlock-ui-{STAMP}"
BACKUP_PREFIX = f"backups/unlock-ui-{STAMP}"

AWS_BASE = [
    "aws",
    "--profile", PROFILE,
    "--region", REGION,
]


class DeployError(RuntimeError):
    pass


def run(args, capture=False, check=True):
    result = subprocess.run(
        [str(value) for value in args],
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        details = result.stderr.strip() if capture else ""
        raise DeployError(
            f"Command failed ({result.returncode}): {' '.join(map(str, args))}"
            + (f"\n{details}" if details else "")
        )
    return result.stdout.strip() if capture else ""


def aws(*args, capture=False, check=True):
    return run(
        AWS_BASE + list(args),
        capture=capture,
        check=check,
    )


def require_commands():
    missing = [
        command
        for command in ("aws", "python3", "node")
        if shutil.which(command) is None
    ]
    if missing:
        raise DeployError(
            "Missing required command(s): " + ", ".join(missing)
        )


def download_s3(key, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    aws(
        "s3", "cp",
        f"s3://{BUCKET}/{key}",
        str(destination),
        "--only-show-errors",
    )


def upload_s3(source, key, content_type):
    aws(
        "s3", "cp",
        str(source),
        f"s3://{BUCKET}/{key}",
        "--content-type", content_type,
        "--cache-control", "no-cache, no-store, must-revalidate",
        "--only-show-errors",
    )


def copy_s3(source_key, destination_key):
    aws(
        "s3", "cp",
        f"s3://{BUCKET}/{source_key}",
        f"s3://{BUCKET}/{destination_key}",
        "--only-show-errors",
    )


def replace_function(text, start_marker, end_marker, replacement, label):
    start = text.find(start_marker)
    if start < 0:
        raise DeployError(f"{label}: start marker was not found.")

    end = text.find(end_marker, start)
    if end < 0:
        raise DeployError(f"{label}: end marker was not found.")

    return text[:start] + replacement + text[end:]


CORRECTION_EXPERIENCE = r'''
const CORRECTION_MILESTONE_SIZE = 20;

function correctionActivationStorageKey() {
  return `${storageKey()}:activated-correction-milestones:${location.pathname}`;
}

function loadActivatedCorrectionMilestones() {
  try {
    const value = JSON.parse(
      localStorage.getItem(
        correctionActivationStorageKey()
      ) || '[]'
    );

    return new Set(
      Array.isArray(value)
        ? value.map(Number).filter(Number.isFinite)
        : []
    );
  } catch {
    return new Set();
  }
}

function saveActivatedCorrectionMilestones(milestones) {
  localStorage.setItem(
    correctionActivationStorageKey(),
    JSON.stringify(
      [...milestones].sort((left, right) => left - right)
    )
  );
}

function correctionMilestoneForProgress(progress) {
  const rank = Number(progress?.attemptRank || 0);

  if (rank > 0) {
    return Math.ceil(rank / CORRECTION_MILESTONE_SIZE)
      * CORRECTION_MILESTONE_SIZE;
  }

  return Number(progress?.milestoneUnlocked || 0);
}

function isCorrectionActivated(progress) {
  if (!progress?.correctionAllowed) return false;

  if (progress.correctionSource === 'administrator') {
    return true;
  }

  if (
    progress.correctionSource !== 'milestone' &&
    progress.autoCorrectionAvailable !== true
  ) {
    return true;
  }

  const milestone =
    correctionMilestoneForProgress(progress);

  return milestone > 0 &&
    loadActivatedCorrectionMilestones().has(milestone);
}

function activatePendingCorrections(questions) {
  const progress = loadProgress();
  const activated =
    loadActivatedCorrectionMilestones();
  const milestones = new Set();

  questions.forEach(question => {
    const item = progress[question.id];

    if (
      !item ||
      item.correct ||
      !item.correctionAllowed ||
      item.correctionSource === 'administrator' ||
      isCorrectionActivated(item)
    ) {
      return;
    }

    const milestone =
      correctionMilestoneForProgress(item);

    if (milestone > 0) {
      milestones.add(milestone);
    }
  });

  milestones.forEach(milestone => {
    activated.add(milestone);
  });

  saveActivatedCorrectionMilestones(activated);
  return milestones;
}

function correctionSummaryFor(questions) {
  const progress = loadProgress();
  const items = questions
    .map(question => progress[question.id])
    .filter(Boolean);

  const attempted = items.length;
  const correct = items.filter(item => item.correct).length;
  const total = questions.length;

  const milestoneUnlocked = Math.min(
    total,
    Math.floor(
      attempted / CORRECTION_MILESTONE_SIZE
    ) * CORRECTION_MILESTONE_SIZE
  );

  const nextMilestone = attempted >= total
    ? total
    : Math.min(
        total,
        milestoneUnlocked + CORRECTION_MILESTONE_SIZE
      );

  const pendingUnlock = items.filter(item =>
    !item.correct &&
    item.correctionAllowed &&
    item.correctionSource !== 'administrator' &&
    !isCorrectionActivated(item)
  );

  const retryAvailable = items.filter(item =>
    !item.correct &&
    item.correctionAllowed &&
    isCorrectionActivated(item)
  );

  const lockedIncorrect = items.filter(item =>
    !item.correct &&
    (
      item.locked ||
      (
        Number(item.attempts || 0) > 1 &&
        !item.correctionAllowed
      )
    )
  );

  return {
    attempted,
    correct,
    total,
    milestoneUnlocked,
    nextMilestone,
    attemptsToNext: Math.max(
      0,
      nextMilestone - attempted
    ),
    pendingUnlockCount: pendingUnlock.length,
    retryAvailableCount: retryAvailable.length,
    lockedIncorrectCount: lockedIncorrect.length
  };
}

function addCorrectionExperienceStyles() {
  if (
    document.getElementById(
      'sat-correction-experience-styles'
    )
  ) {
    return;
  }

  const style = document.createElement('style');
  style.id = 'sat-correction-experience-styles';
  style.textContent = `
    #print-page{display:none!important}

    .sat-correction-panel{
      display:grid;
      grid-template-columns:minmax(0,1.45fr) minmax(280px,.75fr);
      gap:18px;
      margin:22px 0 28px;
      padding:20px;
      border:1px solid rgba(226,199,102,.24);
      border-radius:18px;
      background:
        linear-gradient(135deg,rgba(212,175,55,.07),transparent 42%),
        linear-gradient(180deg,#202226,#191b1f);
      box-shadow:0 12px 32px rgba(0,0,0,.24)
    }

    .sat-correction-head{
      display:flex;
      align-items:flex-start;
      justify-content:space-between;
      gap:16px
    }

    .sat-correction-head h2{
      margin:0;
      color:#f3e2a0;
      font-size:1.25rem
    }

    .sat-correction-copy{
      margin:5px 0 0;
      color:#bdb7aa;
      line-height:1.45
    }

    .sat-correction-count{
      color:#e7c96f;
      font-weight:950;
      white-space:nowrap
    }

    .sat-correction-track{
      height:12px;
      margin:17px 0 12px;
      overflow:hidden;
      border:1px solid #303339;
      border-radius:999px;
      background:#0e0f11
    }

    .sat-correction-fill{
      height:100%;
      width:0;
      border-radius:inherit;
      background:linear-gradient(90deg,#c9982d,#f0dc91);
      transition:width .2s ease
    }

    .sat-correction-milestones{
      display:grid;
      grid-template-columns:repeat(5,minmax(54px,1fr));
      gap:8px
    }

    .sat-correction-milestone{
      padding:8px 6px;
      border:1px solid #484b50;
      border-radius:10px;
      background:#17191d;
      color:#99968e;
      text-align:center;
      font-size:.78rem;
      font-weight:850
    }

    .sat-correction-milestone.ready{
      border-color:#9a7b31;
      background:#31291a;
      color:#f0d67e
    }

    .sat-correction-milestone.unlocked{
      border-color:#a98d48;
      background:#2d2a21;
      color:#f4dfa0;
      box-shadow:inset 0 0 0 1px rgba(226,199,102,.12)
    }

    .sat-correction-action{
      display:flex;
      flex-direction:column;
      justify-content:center;
      padding:18px;
      border:1px solid rgba(226,199,102,.28);
      border-radius:15px;
      background:linear-gradient(180deg,#28271f,#1f201e)
    }

    .sat-correction-action.locked{
      border-color:#555960;
      background:linear-gradient(180deg,#24262a,#1d1f23)
    }

    .sat-correction-action strong{
      display:block;
      margin-bottom:6px;
      color:#f1dda0;
      font-size:1.08rem
    }

    .sat-correction-action.locked strong{
      color:#d1cec5
    }

    .sat-correction-action p{
      margin:0 0 14px;
      color:#c4c0b6;
      line-height:1.48
    }

    .sat-unlock-button{
      min-height:44px;
      padding:0 16px;
      border:1px solid #d4af37;
      border-radius:11px;
      background:linear-gradient(145deg,#f0dc91,#c9982d);
      color:#1c1709;
      font:inherit;
      font-weight:950;
      cursor:pointer;
      box-shadow:0 8px 22px rgba(212,175,55,.16)
    }

    .sat-unlock-button:hover:not(:disabled){
      transform:translateY(-1px);
      filter:brightness(1.04)
    }

    .sat-unlock-button:disabled{
      cursor:not-allowed;
      opacity:.38;
      filter:grayscale(.35);
      box-shadow:none
    }

    .choice.previous-wrong{
      opacity:.48;
      text-decoration:line-through
    }

    @media(max-width:850px){
      .sat-correction-panel{
        grid-template-columns:1fr
      }
    }

    @media(max-width:520px){
      .sat-correction-head{
        align-items:stretch;
        flex-direction:column
      }

      .sat-correction-milestones{
        overflow-x:auto
      }
    }

    @media print{
      .sat-correction-panel{
        display:none!important
      }
    }
  `;

  document.head.appendChild(style);
}

function installCorrectionExperience({
  questions,
  state,
  render,
  topicSelect,
  topicNav
}) {
  addCorrectionExperienceStyles();

  document.getElementById('print-page')?.remove();
  document.querySelector('.sat-navigator-toolbar')?.remove();
  document.querySelector('.sat-navigator-region')?.remove();

  const stats =
    document.querySelector('main > .stats') ||
    document.querySelector('main .stats');
  const statusSelect =
    document.getElementById('status-filter');

  if (
    statusSelect &&
    ![...statusSelect.options].some(
      option => option.value === 'Corrections available'
    )
  ) {
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
      <div class="sat-correction-head">
        <div>
          <h2>Correction progress</h2>
          <p class="sat-correction-copy"
             id="sat-correction-copy"></p>
        </div>
        <div class="sat-correction-count"
             id="sat-correction-count"></div>
      </div>

      <div class="sat-correction-track"
           aria-hidden="true">
        <div class="sat-correction-fill"
             id="sat-correction-fill"></div>
      </div>

      <div class="sat-correction-milestones"
           id="sat-correction-milestones"></div>
    </div>

    <div class="sat-correction-action locked"
         id="sat-correction-action">
      <strong id="sat-correction-title">
        Unlock questions
      </strong>
      <p id="sat-correction-message"></p>
      <button class="sat-unlock-button"
              id="sat-unlock-button"
              type="button"
              disabled>
        Answer 20 Questions
      </button>
    </div>
  `;

  if (stats) {
    stats.insertAdjacentElement('afterend', panel);
  }

  function showCorrections() {
    state.quizIds = null;
    state.status = 'Corrections available';

    if (statusSelect) {
      statusSelect.value = 'Corrections available';
    }

    document
      .getElementById('quiz-banner')
      ?.classList.remove('show');

    render();

    requestAnimationFrame(() => {
      document
        .getElementById('practice')
        ?.scrollIntoView({
          behavior: 'smooth',
          block: 'start'
        });
    });
  }

  const unlockButton =
    panel.querySelector('#sat-unlock-button');

  unlockButton.addEventListener('click', () => {
    const summary = correctionSummaryFor(questions);

    if (summary.pendingUnlockCount > 0) {
      activatePendingCorrections(questions);
      render();
      showCorrections();
      return;
    }

    if (summary.retryAvailableCount > 0) {
      showCorrections();
    }
  });

  function update() {
    const summary = correctionSummaryFor(questions);
    const attemptedPercent = summary.total
      ? Math.round(
          summary.attempted / summary.total * 100
        )
      : 0;

    const activated =
      loadActivatedCorrectionMilestones();

    const milestones = Array.from(
      {
        length: Math.ceil(
          summary.total / CORRECTION_MILESTONE_SIZE
        )
      },
      (_, index) => Math.min(
        summary.total,
        (index + 1) * CORRECTION_MILESTONE_SIZE
      )
    );

    panel.querySelector(
      '#sat-correction-copy'
    ).textContent =
      `${summary.attempted} of ${summary.total} unique questions answered`;

    panel.querySelector(
      '#sat-correction-count'
    ).textContent = `${attemptedPercent}% attempted`;

    panel.querySelector(
      '#sat-correction-fill'
    ).style.width = `${attemptedPercent}%`;

    panel.querySelector(
      '#sat-correction-milestones'
    ).innerHTML = milestones.map(milestone => {
      const isReached =
        milestone <= summary.milestoneUnlocked;
      const isActivated =
        activated.has(milestone);

      const stateClass = isActivated
        ? 'unlocked'
        : isReached
          ? 'ready'
          : '';

      const stateText = isActivated
        ? 'Unlocked'
        : isReached
          ? 'Ready'
          : 'Locked';

      return `
        <div class="sat-correction-milestone ${stateClass}">
          ${milestone}<br>${stateText}
        </div>
      `;
    }).join('');

    const action =
      panel.querySelector('#sat-correction-action');
    const title =
      panel.querySelector('#sat-correction-title');
    const message =
      panel.querySelector('#sat-correction-message');

    if (summary.pendingUnlockCount > 0) {
      action.classList.remove('locked');
      title.textContent =
        `${summary.milestoneUnlocked}-question milestone reached`;

      message.textContent =
        `${summary.pendingUnlockCount} wrong question${
          summary.pendingUnlockCount === 1 ? ' is' : 's are'
        } ready to unlock for one correction attempt.`;

      unlockButton.disabled = false;
      unlockButton.textContent =
        `Unlock ${summary.pendingUnlockCount} Question${
          summary.pendingUnlockCount === 1 ? '' : 's'
        }`;
      return;
    }

    if (summary.retryAvailableCount > 0) {
      action.classList.remove('locked');
      title.textContent = 'Questions unlocked';

      message.textContent =
        `${summary.retryAvailableCount} question${
          summary.retryAvailableCount === 1 ? ' is' : 's are'
        } available for correction.`;

      unlockButton.disabled = false;
      unlockButton.textContent =
        `View ${summary.retryAvailableCount} Unlocked Question${
          summary.retryAvailableCount === 1 ? '' : 's'
        }`;
      return;
    }

    action.classList.add('locked');

    if (summary.attempted < summary.total) {
      const remaining = summary.attemptsToNext;

      title.textContent = 'Unlock questions';
      message.textContent =
        `Answer ${remaining} more different question${
          remaining === 1 ? '' : 's'
        } to reach the ${summary.nextMilestone}-question milestone.`;

      unlockButton.disabled = true;
      unlockButton.textContent =
        `Answer ${remaining} More Question${
          remaining === 1 ? '' : 's'
        }`;
      return;
    }

    if (summary.lockedIncorrectCount > 0) {
      title.textContent = 'Automatic corrections used';
      message.textContent =
        `${summary.lockedIncorrectCount} question${
          summary.lockedIncorrectCount === 1 ? ' remains' : 's remain'
        } incorrect and require administrator approval.`;
      unlockButton.disabled = true;
      unlockButton.textContent =
        'No Automatic Unlocks Available';
      return;
    }

    title.textContent = 'Volume complete';
    message.textContent =
      'There are no wrong questions waiting to be unlocked.';
    unlockButton.disabled = true;
    unlockButton.textContent = 'Nothing to Unlock';
  }

  return { update };
}

'''


APPLY_SAVED_STATE = r'''  function applySavedState(question, card, progress) {
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
          : 'Previously answered correctly. This question is complete.'
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
          : `Incorrect. Answer ${
              progress.attemptsToNext || 0
            } more different question${
              Number(progress.attemptsToNext || 0) === 1
                ? ''
                : 's'
            } to reach the next correction milestone.`
      );
      return;
    }

    if (
      progress.correctionAllowed &&
      !isCorrectionActivated(progress)
    ) {
      if (previousChoice) {
        previousChoice.classList.add(
          'selected',
          'previous-wrong'
        );
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
        'The milestone is complete. Select Unlock Questions above to begin the correction attempt.'
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
          : 'Question unlocked. Enter a new answer for the one correction attempt.'
      );
    }
  }

'''


CHECK_FUNCTION = r'''  async function check(question, card) {
    const existing =
      loadProgress()[question.id];

    if (
      existing?.correctionAllowed &&
      !isCorrectionActivated(existing)
    ) {
      showFeedback(
        card,
        false,
        'Select Unlock Questions above before submitting the correction.'
      );
      disableAnswerControls(card);
      return;
    }

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

'''


def patch_app(source, destination):
    text = source.read_text(encoding="utf-8")

    text = re.sub(
        r"const SAT_UNLOCK_UI_BUILD\s*=\s*['\"][^'\"]+['\"];\s*",
        "",
        text,
        count=1,
    )
    text = f"const SAT_UNLOCK_UI_BUILD = '{BUILD}';\n" + text

    block_start = text.find(
        "const CORRECTION_MILESTONE_SIZE = 20;"
    )
    block_end = text.find(
        "const SAT_FORMULA_GROUPS = {",
        block_start,
    )

    if block_start < 0 or block_end < 0:
        raise DeployError(
            "The live correction UI block could not be located."
        )

    text = (
        text[:block_start]
        + CORRECTION_EXPERIENCE
        + text[block_end:]
    )

    text = replace_function(
        text,
        "  function applySavedState(question, card, progress) {",
        "  function renderQuestion",
        APPLY_SAVED_STATE,
        "applySavedState",
    )

    text = replace_function(
        text,
        "  async function check(question, card) {",
        "  function showFeedback",
        CHECK_FUNCTION,
        "check",
    )

    correction_filter_pattern = re.compile(
        r"if\s*\(\s*state\.status\s*===\s*['\"]Corrections available['\"]\s*&&[\s\S]*?\)\s*return false;"
    )
    correction_filter_replacement = (
        "if (state.status === 'Corrections available' && "
        "(!progress || progress.correct || progress.locked || "
        "!progress.correctionAllowed || !isCorrectionActivated(progress))) "
        "return false;"
    )

    text, filter_count = correction_filter_pattern.subn(
        correction_filter_replacement,
        text,
        count=1,
    )

    if filter_count != 1:
        raise DeployError(
            "The Corrections available filter could not be updated."
        )

    quiz_pattern = re.compile(
        r"return\s+!progress\?\.correct\s*&&\s*!progress\?\.locked\s*;"
    )
    text, quiz_count = quiz_pattern.subn(
        "return !progress?.correct && !progress?.locked && "
        "(!progress?.correctionAllowed || isCorrectionActivated(progress));",
        text,
        count=1,
    )

    if quiz_count != 1:
        raise DeployError(
            "The quiz availability rule could not be updated."
        )

    text = re.sub(
        r"document\.getElementById\(['\"]print-page['\"]\)\.onclick\s*=\s*\(\)\s*=>\s*window\.print\(\);",
        "document.getElementById('print-page')?.remove();",
        text,
        count=1,
    )

    required_markers = [
        "Unlock Questions",
        "activatePendingCorrections",
        "isCorrectionActivated",
        "sat-unlock-button",
        "SAT_UNLOCK_UI_BUILD",
    ]
    for marker in required_markers:
        if marker not in text:
            raise DeployError(
                f"Patched app.js is missing required marker: {marker}"
            )

    forbidden_markers = [
        "Show question navigator",
        "sat-navigator-toolbar{",
        "sat-navigator-region[hidden]",
    ]
    for marker in forbidden_markers:
        if marker in text:
            raise DeployError(
                f"Question navigator code remains in app.js: {marker}"
            )

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text, encoding="utf-8")


def remove_print_control(text):
    patterns = [
        re.compile(
            r"<button\b[^>]*\bid\s*=\s*['\"]print-page['\"][^>]*>[\s\S]*?</button>",
            re.IGNORECASE,
        ),
        re.compile(
            r"<a\b[^>]*\bid\s*=\s*['\"]print-page['\"][^>]*>[\s\S]*?</a>",
            re.IGNORECASE,
        ),
    ]

    for pattern in patterns:
        text = pattern.sub("", text, count=1)

    return text


def patch_html(source, destination):
    text = source.read_text(encoding="utf-8")
    text = remove_print_control(text)

    text, count = re.subn(
        r"(<script\s+src=['\"](?:\./)?app\.js)(?:\?[^'\"]*)?(['\"])",
        rf"\1?v={BUILD}\2",
        text,
        count=1,
        flags=re.IGNORECASE,
    )

    if count != 1:
        raise DeployError(
            f"app.js reference was not found in {source.name}."
        )

    if re.search(
        r"\bid\s*=\s*['\"]print-page['\"]",
        text,
        re.IGNORECASE,
    ):
        raise DeployError(
            f"Print control remains in {source.name}."
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text, encoding="utf-8")


def restore_backups():
    print()
    print("Restoring the previous Math website files...")

    aws(
        "s3", "cp",
        f"s3://{BUCKET}/{BACKUP_PREFIX}/{APP_KEY}",
        f"s3://{BUCKET}/{APP_KEY}",
        "--only-show-errors",
        check=False,
    )

    for key in HTML_KEYS:
        aws(
            "s3", "cp",
            f"s3://{BUCKET}/{BACKUP_PREFIX}/{key}",
            f"s3://{BUCKET}/{key}",
            "--only-show-errors",
            check=False,
        )


def main():
    require_commands()

    account = aws(
        "sts", "get-caller-identity",
        "--query", "Account",
        "--output", "text",
        capture=True,
    )

    if account != EXPECTED_ACCOUNT:
        raise DeployError(
            f"Expected account {EXPECTED_ACCOUNT}, "
            f"but AWS returned {account}."
        )

    print("=" * 60)
    print(" SAT Math Gold/Charcoal Unlock Questions deployment")
    print("=" * 60)
    print(f"AWS profile: {PROFILE}")
    print(f"AWS account: {account}")
    print(f"S3 bucket:   {BUCKET}")
    print(f"Build:       {BUILD}")
    print()

    with tempfile.TemporaryDirectory(
        prefix="sat-unlock-ui-"
    ) as temp_name:
        root = Path(temp_name)
        live = root / "live"
        patched = root / "patched"

        print("1. Downloading the exact live Math files...")
        download_s3(APP_KEY, live / APP_KEY)

        for key in HTML_KEYS:
            download_s3(key, live / key)

        print("2. Applying the Gold/Charcoal unlock design...")
        patch_app(
            live / APP_KEY,
            patched / APP_KEY,
        )

        for key in HTML_KEYS:
            patch_html(
                live / key,
                patched / key,
            )

        print("3. Checking JavaScript syntax...")
        run([
            "node",
            "--check",
            str(patched / APP_KEY),
        ])
        print("   PASS: app.js syntax is valid.")

        print("4. Backing up the current live files...")
        copy_s3(
            APP_KEY,
            f"{BACKUP_PREFIX}/{APP_KEY}",
        )

        for key in HTML_KEYS:
            copy_s3(
                key,
                f"{BACKUP_PREFIX}/{key}",
            )

        uploaded = False

        try:
            print("5. Uploading the shared Math application...")
            upload_s3(
                patched / APP_KEY,
                APP_KEY,
                "application/javascript; charset=utf-8",
            )

            for key in HTML_KEYS:
                upload_s3(
                    patched / key,
                    key,
                    "text/html; charset=utf-8",
                )

            uploaded = True

            print("6. Verifying the deployed build...")
            remote_text = aws(
                "s3", "cp",
                f"s3://{BUCKET}/{APP_KEY}",
                "-",
                "--only-show-errors",
                capture=True,
            )

            required = [
                BUILD,
                "Unlock Questions",
                "activatePendingCorrections",
                "sat-unlock-button",
            ]

            for marker in required:
                if marker not in remote_text:
                    raise DeployError(
                        "Deployment verification failed: "
                        f"{marker!r} is missing."
                    )

            for marker in (
                "Show question navigator",
                "sat-navigator-toolbar{",
                "sat-navigator-region[hidden]",
            ):
                if marker in remote_text:
                    raise DeployError(
                        "Deployment verification failed: "
                        "question navigator code remains."
                    )

            print("   PASS: deployed app.js is verified.")

            distribution = aws(
                "cloudfront", "get-distribution",
                "--id", DISTRIBUTION_ID,
                capture=True,
                check=False,
            )

            if distribution:
                print("7. Invalidating CloudFront...")
                aws(
                    "cloudfront", "create-invalidation",
                    "--distribution-id", DISTRIBUTION_ID,
                    "--paths",
                    "/math/app.js*",
                    "/math/*.html*",
                    capture=True,
                )

        except Exception:
            if uploaded:
                restore_backups()
            raise

    print()
    print("=" * 60)
    print(" GOLD/CHARCOAL UNLOCK UI DEPLOYED")
    print("=" * 60)
    print()
    print("Implemented:")
    print("  - Print / Save as PDF removed.")
    print("  - Question Navigator removed.")
    print("  - Gold Unlock Questions button added.")
    print("  - Button enables after each 20-question milestone.")
    print("  - Clicking it activates wrong questions for correction.")
    print("  - Milestones continue at 40, 60, 80, and 100.")
    print()
    print("Close every open SAT Math tab and reopen the student link.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nDeployment cancelled.", file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print()
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
