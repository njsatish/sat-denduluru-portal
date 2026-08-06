#!/bin/bash
set -e

python3 - <<'PY'
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

PROFILE = "denduluru"
EXPECTED_ACCOUNT = "989174615155"
REGION = "us-east-1"
BUCKET = "sat-prep-josh"
APP_KEY = "math/app.js"
TABLE_NAME = "sat-progress"
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
BUILD = f"20260801-retry-v4-{STAMP}"
TEST_USER = f"retrytest{int(time.time())}{os.getpid()}"

AWS_BASE = [
    "aws",
    "--profile", PROFILE,
    "--region", REGION,
]


class DeployError(RuntimeError):
    pass


def run(
    args: list[str],
    *,
    capture: bool = False,
    check: bool = True,
    cwd: Path | None = None,
) -> str:
    command = [str(value) for value in args]
    result = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        details = result.stderr.strip() if capture else ""
        raise DeployError(
            f"Command failed ({result.returncode}): {' '.join(command)}"
            + (f"\n{details}" if details else "")
        )
    return result.stdout.strip() if capture else ""


def aws(*args: str, capture: bool = False, check: bool = True) -> str:
    return run(AWS_BASE + list(args), capture=capture, check=check)


def require_commands() -> None:
    missing = [
        command for command in ("aws", "python3", "node")
        if shutil.which(command) is None
    ]
    if missing:
        raise DeployError(
            "Missing required command(s): " + ", ".join(missing)
        )


def download_s3(key: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    aws(
        "s3", "cp",
        f"s3://{BUCKET}/{key}",
        str(destination),
        "--only-show-errors",
    )


def upload_s3(
    source: Path,
    key: str,
    *,
    content_type: str | None = None,
    cache_control: str | None = None,
) -> None:
    args = [
        "s3", "cp",
        str(source),
        f"s3://{BUCKET}/{key}",
        "--only-show-errors",
    ]
    if content_type:
        args += ["--content-type", content_type]
    if cache_control:
        args += ["--cache-control", cache_control]
    aws(*args)


def copy_s3(source_key: str, destination_key: str) -> None:
    aws(
        "s3", "cp",
        f"s3://{BUCKET}/{source_key}",
        f"s3://{BUCKET}/{destination_key}",
        "--only-show-errors",
    )


def extract_progress_api(app_text: str) -> str:
    match = re.search(
        r"""const\s+PROGRESS_API\s*=\s*['"]([^'"]+)['"]""",
        app_text,
    )
    if not match:
        match = re.search(
            r"""https://[A-Za-z0-9-]+\.lambda-url\.[A-Za-z0-9-]+\.on\.aws/?""",
            app_text,
        )
    if not match:
        raise DeployError("PROGRESS_API was not found in live math/app.js.")
    url = match.group(1) if match.lastindex else match.group(0)
    return url if url.endswith("/") else url + "/"


def find_lambda_for_url(progress_api: str) -> str:
    output = aws(
        "lambda", "list-functions",
        "--query", "Functions[].FunctionName",
        "--output", "text",
        capture=True,
    )
    names = [value for value in re.split(r"\s+", output) if value]

    for name in names:
        url = aws(
            "lambda", "get-function-url-config",
            "--function-name", name,
            "--query", "FunctionUrl",
            "--output", "text",
            capture=True,
            check=False,
        )
        if url == progress_api:
            return name

    raise DeployError(
        f"No Lambda Function URL matches the live PROGRESS_API: {progress_api}"
    )


def http_post(url: str, payload: dict) -> dict:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise DeployError(
            f"API returned HTTP {error.code}: {body}"
        ) from error
    except OSError as error:
        raise DeployError(f"Could not call progress API: {error}") from error

    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise DeployError(f"API returned invalid JSON: {body}") from error


def find_handler_file(extracted_dir: Path, handler_setting: str) -> Path:
    module = handler_setting.rsplit(".", 1)[0]
    for extension in ("mjs", "js", "cjs"):
        candidate = extracted_dir / f"{module}.{extension}"
        if candidate.exists():
            return candidate

    candidates = []
    for extension in ("*.mjs", "*.js", "*.cjs"):
        candidates.extend(extracted_dir.rglob(extension))

    candidates = [
        path for path in candidates
        if "node_modules" not in path.parts
    ]
    if not candidates:
        raise DeployError("Lambda handler source was not found in its ZIP.")

    return sorted(candidates, key=lambda path: len(path.parts))[0]


LAMBDA_BLOCK = r"""// BEGIN SAT_MILESTONE_RETRY_V4
const SAT_RETRY_BUILD = '__BUILD__';
const SAT_RETRY_MILESTONE_SIZE = 20;

function mathQuestionPosition(questionId) {
  const id = String(questionId || '').trim();

  let match = id.match(/^v([1-3])q(\d{3})$/i);
  if (match) {
    return {
      group: `v${match[1]}q`,
      setNumber: 1,
      volumeNumber: Number(match[1]),
      questionNumber: Number(match[2]),
      totalQuestions: 100
    };
  }

  match = id.match(/^s(\d+)v([1-3])q(\d{3})$/i);
  if (match) {
    return {
      group: `s${match[1]}v${match[2]}q`,
      setNumber: Number(match[1]),
      volumeNumber: Number(match[2]),
      questionNumber: Number(match[3]),
      totalQuestions: 100
    };
  }

  return null;
}

function progressFirstTime(item) {
  const time = Date.parse(item?.firstAt || item?.lastAt || '');
  return Number.isFinite(time) ? time : Number.MAX_SAFE_INTEGER;
}

function normalizeProgressItem(item) {
  const attempted = Boolean(item?.lastResult);
  const storedLocked =
    typeof item?.locked === 'boolean' ? item.locked : attempted;
  const storedCorrectionAllowed =
    item?.correctionAllowed === true;

  return {
    ...item,
    attempts: Number(item?.attempts || (attempted ? 1 : 0)),
    storedLocked,
    storedCorrectionAllowed,
    locked: storedLocked,
    correctionAllowed:
      attempted &&
      item.lastResult === 'incorrect' &&
      (!storedLocked || storedCorrectionAllowed)
  };
}

function decorateProgressItems(rawItems) {
  const items = (rawItems || []).map(normalizeProgressItem);
  const grouped = new Map();

  for (const item of items) {
    const position = mathQuestionPosition(item.questionId);
    if (!position) continue;

    if (!grouped.has(position.group)) {
      grouped.set(position.group, {
        position,
        items: []
      });
    }

    grouped.get(position.group).items.push(item);
  }

  const retryPolicy = {};

  for (const [group, value] of grouped.entries()) {
    const sorted = [...value.items].sort((left, right) => {
      const timeDifference =
        progressFirstTime(left) - progressFirstTime(right);

      if (timeDifference !== 0) return timeDifference;

      const leftNumber =
        mathQuestionPosition(left.questionId)?.questionNumber || 999;
      const rightNumber =
        mathQuestionPosition(right.questionId)?.questionNumber || 999;

      return leftNumber - rightNumber;
    });

    const attempted = sorted.length;
    const milestoneUnlocked = Math.min(
      value.position.totalQuestions,
      Math.floor(attempted / SAT_RETRY_MILESTONE_SIZE) *
        SAT_RETRY_MILESTONE_SIZE
    );
    const nextMilestone = attempted >= value.position.totalQuestions
      ? value.position.totalQuestions
      : Math.min(
          value.position.totalQuestions,
          milestoneUnlocked + SAT_RETRY_MILESTONE_SIZE
        );

    let retryAvailable = 0;

    sorted.forEach((item, index) => {
      const attemptRank = index + 1;
      const incorrect = item.lastResult === 'incorrect';
      const administratorAllowed =
        incorrect &&
        (
          item.storedLocked === false ||
          item.storedCorrectionAllowed === true
        );
      const autoCorrectionAvailable =
        incorrect &&
        item.attempts === 1 &&
        attemptRank <= milestoneUnlocked;
      const correctionAllowed =
        administratorAllowed || autoCorrectionAvailable;

      item.attemptRank = attemptRank;
      item.milestoneUnlocked = milestoneUnlocked;
      item.nextMilestone = nextMilestone;
      item.attemptsToNext =
        Math.max(0, nextMilestone - attempted);
      item.autoCorrectionAvailable =
        autoCorrectionAvailable;
      item.correctionAllowed = correctionAllowed;
      item.correctionSource = administratorAllowed
        ? 'administrator'
        : autoCorrectionAvailable
          ? 'milestone'
          : null;
      item.locked = item.lastResult === 'correct'
        ? true
        : incorrect
          ? !correctionAllowed
          : false;

      if (correctionAllowed) retryAvailable += 1;
    });

    retryPolicy[group] = {
      setNumber: value.position.setNumber,
      volumeNumber: value.position.volumeNumber,
      totalQuestions: value.position.totalQuestions,
      attempted,
      milestoneUnlocked,
      nextMilestone,
      attemptsToNext: Math.max(0, nextMilestone - attempted),
      retryAvailable
    };
  }

  return { items, retryPolicy };
}

async function queryAllProgress(userId) {
  const result = await ddb.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: 'userId = :userId',
    ExpressionAttributeValues: { ':userId': userId },
    ConsistentRead: true
  }));

  return result.Items || [];
}

async function queryVolumeProgress(userId, group) {
  const result = await ddb.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression:
      'userId = :userId AND begins_with(questionId, :group)',
    ExpressionAttributeValues: {
      ':userId': userId,
      ':group': group
    },
    ConsistentRead: true
  }));

  return result.Items || [];
}

async function getProgressItem(userId, questionId) {
  const result = await ddb.send(new GetCommand({
    TableName: TABLE,
    Key: { userId, questionId },
    ConsistentRead: true
  }));

  return result.Item || null;
}

async function isAutomaticCorrectionAvailable(userId, questionId) {
  const position = mathQuestionPosition(questionId);
  if (!position) return false;

  const rawItems =
    await queryVolumeProgress(userId, position.group);
  const item = decorateProgressItems(rawItems).items.find(
    candidate => candidate.questionId === questionId
  );

  return Boolean(item?.autoCorrectionAvailable);
}

async function decorateSavedProgressItem(userId, savedItem) {
  const position =
    mathQuestionPosition(savedItem?.questionId);

  if (!position) return normalizeProgressItem(savedItem);

  const rawItems =
    await queryVolumeProgress(userId, position.group);
  return decorateProgressItems(rawItems).items.find(
    candidate => candidate.questionId === savedItem.questionId
  ) || normalizeProgressItem(savedItem);
}

async function recordAttempt({
  userId,
  questionId,
  correct,
  choice,
  category
}) {
  const validQuestionId = requireQuestionId(questionId);
  const now = new Date().toISOString();
  const existing =
    await getProgressItem(userId, validQuestionId);

  let attemptMode = 'first';

  if (existing) {
    const attempts = Number(existing.attempts || 1);

    if (existing.lastResult === 'correct') {
      throw new HttpError(
        409,
        'QUESTION_LOCKED',
        'This question has already been completed'
      );
    }

    if (existing.locked === false) {
      attemptMode = 'administrator';
    } else if (
      attempts === 1 &&
      await isAutomaticCorrectionAvailable(
        userId,
        validQuestionId
      )
    ) {
      attemptMode = 'milestone';
    } else {
      throw new HttpError(
        409,
        'QUESTION_LOCKED',
        attempts > 1
          ? 'The correction attempt is complete; administrator approval is required'
          : 'This question is locked until its 20-question correction milestone'
      );
    }
  }

  const conditionExpression =
    attemptMode === 'first'
      ? 'attribute_not_exists(#lastResult)'
      : attemptMode === 'administrator'
        ? '#lastResult = :incorrect AND #locked = :false'
        : '#lastResult = :incorrect AND #attempts = :one';

  try {
    const result = await ddb.send(new UpdateCommand({
      TableName: TABLE,
      Key: {
        userId,
        questionId: validQuestionId
      },
      UpdateExpression:
        'ADD #attempts :one, #correctCount :correctIncrement ' +
        'SET #lastResult = :result, #lastChoice = :choice, ' +
        '#lastAt = :now, #category = :category, ' +
        '#firstAt = if_not_exists(#firstAt, :now), ' +
        '#locked = :true, #correctionAllowed = :false, ' +
        '#lastAttemptType = :attemptMode',
      ConditionExpression: conditionExpression,
      ExpressionAttributeNames: {
        '#attempts': 'attempts',
        '#correctCount': 'correctCount',
        '#lastResult': 'lastResult',
        '#lastChoice': 'lastChoice',
        '#lastAt': 'lastAt',
        '#category': 'category',
        '#firstAt': 'firstAt',
        '#locked': 'locked',
        '#correctionAllowed': 'correctionAllowed',
        '#lastAttemptType': 'lastAttemptType'
      },
      ExpressionAttributeValues: {
        ':one': 1,
        ':correctIncrement': correct ? 1 : 0,
        ':result': correct ? 'correct' : 'incorrect',
        ':incorrect': 'incorrect',
        ':choice': choice ?? null,
        ':now': now,
        ':category': category ?? 'unknown',
        ':true': true,
        ':false': false,
        ':attemptMode': attemptMode
      },
      ReturnValues: 'ALL_NEW'
    }));

    return decorateSavedProgressItem(
      userId,
      result.Attributes
    );
  } catch (error) {
    if (
      error?.name ===
      'ConditionalCheckFailedException'
    ) {
      throw new HttpError(
        409,
        'QUESTION_LOCKED',
        'This question is no longer available for another attempt'
      );
    }

    throw error;
  }
}

async function getProgress(userId) {
  const rawItems = await queryAllProgress(userId);
  const decorated = decorateProgressItems(rawItems);
  const items = decorated.items;

  const summary = items.reduce((value, item) => {
    const everCorrect =
      Number(item.correctCount || 0) > 0;
    const category = item.category || 'unknown';

    value.attempted += 1;
    value.totalAttempts += Number(item.attempts || 0);
    value.totalCorrect += Number(item.correctCount || 0);
    value.mastered += everCorrect ? 1 : 0;
    value.lockedIncorrect +=
      item.lastResult === 'incorrect' && item.locked
        ? 1
        : 0;
    value.retryAvailable +=
      item.lastResult === 'incorrect' &&
      item.correctionAllowed
        ? 1
        : 0;

    value.byCategory[category] ||= {
      attempted: 0,
      mastered: 0
    };
    value.byCategory[category].attempted += 1;

    if (everCorrect) {
      value.byCategory[category].mastered += 1;
    }

    return value;
  }, {
    attempted: 0,
    mastered: 0,
    totalAttempts: 0,
    totalCorrect: 0,
    lockedIncorrect: 0,
    retryAvailable: 0,
    byCategory: {}
  });

  summary.accuracy = summary.totalAttempts > 0
    ? +(
        summary.totalCorrect /
        summary.totalAttempts
      ).toFixed(3)
    : 0;

  return {
    items,
    summary,
    retryPolicy: decorated.retryPolicy,
    retryBuild: SAT_RETRY_BUILD
  };
}
// END SAT_MILESTONE_RETRY_V4

"""


def patch_lambda(handler_path: Path) -> None:
    text = handler_path.read_text(encoding="utf-8")

    import_match = re.search(
        r'import\s*\{(?P<body>[\s\S]*?)\}\s*from\s*[\'"]@aws-sdk/lib-dynamodb[\'"];?',
        text,
    )
    if not import_match:
        raise DeployError(
            "@aws-sdk/lib-dynamodb import was not found in Lambda."
        )

    names = [
        value.strip()
        for value in import_match.group("body").split(",")
        if value.strip()
    ]
    for required in ("GetCommand", "QueryCommand", "UpdateCommand"):
        if required not in names:
            names.append(required)

    new_import = (
        "import {\n  "
        + ",\n  ".join(dict.fromkeys(names))
        + "\n} from '@aws-sdk/lib-dynamodb';"
    )
    text = (
        text[:import_match.start()]
        + new_import
        + text[import_match.end():]
    )

    possible_starts = [
        index for index in (
            text.find("// BEGIN SAT_MILESTONE_RETRY_V4"),
            text.find("// BEGIN SAT_MILESTONE_RETRY_V3"),
            text.find("function mathQuestionPosition("),
            text.find("async function recordAttempt("),
        )
        if index >= 0
    ]
    if not possible_starts:
        raise DeployError("recordAttempt was not found in Lambda.")

    start = min(possible_starts)
    end = text.find("async function createStudent", start)
    if end < 0:
        raise DeployError(
            "createStudent was not found after the Lambda progress functions."
        )

    block = LAMBDA_BLOCK.replace("__BUILD__", BUILD)
    text = text[:start] + block + text[end:]
    handler_path.write_text(text, encoding="utf-8")


def replace_function(
    text: str,
    start_pattern: str,
    end_pattern: str,
    replacement: str,
    label: str,
) -> str:
    start = text.find(start_pattern)
    if start < 0:
        raise DeployError(f"{label}: start marker was not found.")
    end = text.find(end_pattern, start)
    if end < 0:
        raise DeployError(f"{label}: end marker was not found.")
    return text[:start] + replacement + text[end:]


CLOUD_FUNCTION = r"""function cloudItemToLocal(item) {
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

"""


APPLY_FUNCTION = r"""  function applySavedState(question, card, progress) {
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

"""


CHECK_FUNCTION = r"""  async function check(question, card) {
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

"""


def patch_app(source: Path, destination: Path) -> None:
    text = source.read_text(encoding="utf-8")

    text = re.sub(
        r"const SAT_RETRY_UI_BUILD\s*=\s*['\"][^'\"]+['\"];\s*",
        "",
        text,
        count=1,
    )
    text = f"const SAT_RETRY_UI_BUILD = '{BUILD}';\n" + text

    text = replace_function(
        text,
        "function cloudItemToLocal(item) {",
        "async function syncFromCloud",
        CLOUD_FUNCTION,
        "cloudItemToLocal",
    )
    text = replace_function(
        text,
        "  function applySavedState(question, card, progress) {",
        "  function renderQuestion",
        APPLY_FUNCTION,
        "applySavedState",
    )
    text = replace_function(
        text,
        "  async function check(question, card) {",
        "  function showFeedback",
        CHECK_FUNCTION,
        "check",
    )

    if ".choice.previous-wrong" not in text:
        text += r"""
(function addSatRetryChoiceStyle() {
  if (document.getElementById('sat-retry-choice-style')) return;
  const style = document.createElement('style');
  style.id = 'sat-retry-choice-style';
  style.textContent = `
    .choice.previous-wrong{
      opacity:.48;
      text-decoration:line-through;
      cursor:not-allowed
    }`;
  document.head.appendChild(style);
})();
"""

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text, encoding="utf-8")


def patch_html(source: Path, destination: Path) -> None:
    text = source.read_text(encoding="utf-8")
    text, count = re.subn(
        r'(<script\s+src=["\'](?:\./)?app\.js)(?:\?[^"\']*)?(["\'])',
        rf'\1?v={BUILD}\2',
        text,
        count=1,
        flags=re.IGNORECASE,
    )
    if count != 1:
        raise DeployError(
            f"app.js script reference was not found in {source.name}."
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text, encoding="utf-8")


def create_zip(source_dir: Path, zip_path: Path) -> None:
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(source_dir.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(source_dir))


def cleanup_test_records() -> None:
    request = {
        TABLE_NAME: [
            {
                "DeleteRequest": {
                    "Key": {
                        "userId": {"S": TEST_USER},
                        "questionId": {"S": f"v3q{number:03d}"},
                    }
                }
            }
            for number in range(1, 21)
        ]
    }
    with tempfile.NamedTemporaryFile(
        "w", suffix=".json", delete=False, encoding="utf-8"
    ) as file:
        json.dump(request, file)
        request_file = file.name
    try:
        aws(
            "dynamodb", "batch-write-item",
            "--request-items", f"file://{request_file}",
            check=False,
        )
    finally:
        Path(request_file).unlink(missing_ok=True)


def run_api_test(progress_api: str) -> None:
    print("   Creating 20 temporary first attempts...")
    for number in range(1, 21):
        http_post(
            progress_api,
            {
                "action": "record",
                "userId": TEST_USER,
                "questionId": f"v3q{number:03d}",
                "correct": number != 1,
                "choice": (
                    "wrong-first-answer"
                    if number == 1
                    else "deployment-test-answer"
                ),
                "category": "deployment-test",
            },
        )

    progress = http_post(
        progress_api,
        {
            "action": "progress",
            "userId": TEST_USER,
        },
    )
    item = next(
        (
            value for value in progress.get("items", [])
            if value.get("questionId") == "v3q001"
        ),
        None,
    )
    if not item:
        raise DeployError("API test: v3q001 was not returned.")
    if item.get("correctionAllowed") is not True:
        raise DeployError(
            "API test: correction did not unlock after 20 unique attempts."
        )
    if int(item.get("milestoneUnlocked", 0)) != 20:
        raise DeployError(
            "API test: milestoneUnlocked was not 20."
        )

    print("   Correction unlocked. Submitting a correct retry...")
    saved = http_post(
        progress_api,
        {
            "action": "record",
            "userId": TEST_USER,
            "questionId": "v3q001",
            "correct": True,
            "choice": "corrected-answer",
            "category": "deployment-test",
        },
    )
    if saved.get("lastResult") != "correct":
        raise DeployError(
            f"API test: lastResult is {saved.get('lastResult')!r}."
        )
    if int(saved.get("attempts", 0)) != 2:
        raise DeployError(
            f"API test: attempts is {saved.get('attempts')!r}, expected 2."
        )
    if saved.get("lastChoice") != "corrected-answer":
        raise DeployError(
            f"API test: lastChoice is {saved.get('lastChoice')!r}."
        )

    print("   PASS: the server saved the corrected answer.")


def main() -> None:
    require_commands()

    account = aws(
        "sts", "get-caller-identity",
        "--query", "Account",
        "--output", "text",
        capture=True,
    )
    if account != EXPECTED_ACCOUNT:
        raise DeployError(
            f"Expected account {EXPECTED_ACCOUNT}, but AWS returned {account}."
        )

    print("=" * 60)
    print(" SAT Math correction repair - Mac compatible")
    print("=" * 60)
    print(f"AWS profile: {PROFILE}")
    print(f"AWS account: {account}")
    print(f"S3 bucket:   {BUCKET}")
    print(f"Build:       {BUILD}")
    print()

    with tempfile.TemporaryDirectory(prefix="sat-retry-") as temp_name:
        root = Path(temp_name)
        live = root / "live"
        patched = root / "patched"
        lambda_original = root / "lambda-original"
        old_lambda_zip = root / "lambda-before.zip"
        new_lambda_zip = root / "lambda-patched.zip"

        print("1. Downloading the exact live files...")
        download_s3(APP_KEY, live / APP_KEY)
        for key in HTML_KEYS:
            download_s3(key, live / key)

        app_text = (live / APP_KEY).read_text(encoding="utf-8")
        progress_api = extract_progress_api(app_text)
        print(f"   Progress API: {progress_api}")

        print("2. Finding and downloading the live Lambda...")
        lambda_function = find_lambda_for_url(progress_api)
        print(f"   Lambda: {lambda_function}")

        handler_setting = aws(
            "lambda", "get-function-configuration",
            "--function-name", lambda_function,
            "--query", "Handler",
            "--output", "text",
            capture=True,
        )
        code_url = aws(
            "lambda", "get-function",
            "--function-name", lambda_function,
            "--query", "Code.Location",
            "--output", "text",
            capture=True,
        )
        urllib.request.urlretrieve(code_url, old_lambda_zip)

        lambda_original.mkdir(parents=True)
        with zipfile.ZipFile(old_lambda_zip) as archive:
            archive.extractall(lambda_original)

        handler_file = find_handler_file(
            lambda_original,
            handler_setting,
        )
        print(
            "   Handler: "
            + str(handler_file.relative_to(lambda_original))
        )

        print("3. Patching Lambda and Math app...")
        patch_lambda(handler_file)
        patch_app(live / APP_KEY, patched / APP_KEY)
        for key in HTML_KEYS:
            patch_html(live / key, patched / key)

        run(["node", "--check", str(handler_file)])
        run(["node", "--check", str(patched / APP_KEY)])
        create_zip(lambda_original, new_lambda_zip)
        print("   JavaScript syntax checks passed.")

        backup_prefix = f"backups/retry-v4-{STAMP}"

        print("4. Backing up current production files...")
        copy_s3(APP_KEY, f"{backup_prefix}/{APP_KEY}")
        for key in HTML_KEYS:
            copy_s3(key, f"{backup_prefix}/{key}")
        upload_s3(
            old_lambda_zip,
            f"{backup_prefix}/lambda-before.zip",
        )

        lambda_deployed = False
        test_passed = False
        try:
            print("5. Deploying Lambda...")
            aws(
                "lambda", "update-function-code",
                "--function-name", lambda_function,
                "--zip-file", f"fileb://{new_lambda_zip}",
            )
            lambda_deployed = True
            aws(
                "lambda", "wait", "function-updated",
                "--function-name", lambda_function,
            )

            print("6. Running a real API test...")
            run_api_test(progress_api)
            test_passed = True

            print("7. API test passed. Uploading website files...")
            upload_s3(
                patched / APP_KEY,
                APP_KEY,
                content_type="application/javascript; charset=utf-8",
                cache_control="no-cache, no-store, must-revalidate",
            )
            for key in HTML_KEYS:
                upload_s3(
                    patched / key,
                    key,
                    content_type="text/html; charset=utf-8",
                    cache_control="no-cache, no-store, must-revalidate",
                )

            remote_first_line = aws(
                "s3", "cp",
                f"s3://{BUCKET}/{APP_KEY}",
                "-",
                "--only-show-errors",
                capture=True,
            ).splitlines()[0]
            if BUILD not in remote_first_line:
                raise DeployError(
                    "Uploaded app.js build marker could not be verified."
                )

            distribution_check = aws(
                "cloudfront", "get-distribution",
                "--id", DISTRIBUTION_ID,
                capture=True,
                check=False,
            )
            if distribution_check:
                print("8. Invalidating CloudFront...")
                aws(
                    "cloudfront", "create-invalidation",
                    "--distribution-id", DISTRIBUTION_ID,
                    "--paths", "/math/app.js*", "/math/*.html*",
                )

        except Exception:
            if lambda_deployed and not test_passed:
                print()
                print("The live API test failed. Restoring the old Lambda...")
                aws(
                    "lambda", "update-function-code",
                    "--function-name", lambda_function,
                    "--zip-file", f"fileb://{old_lambda_zip}",
                    check=False,
                )
                aws(
                    "lambda", "wait", "function-updated",
                    "--function-name", lambda_function,
                    check=False,
                )
            raise
        finally:
            cleanup_test_records()

    print()
    print("=" * 60)
    print(" DEPLOYMENT AND LIVE API TEST PASSED")
    print("=" * 60)
    print(f"Build: {BUILD}")
    print()
    print("Verified:")
    print("  - 20 unique attempts unlocked correction.")
    print("  - The correct retry was stored.")
    print("  - attempts changed from 1 to 2.")
    print("  - lastChoice changed to corrected-answer.")
    print()
    print("Close every SAT Math tab, then reopen the student link.")


try:
    main()
except KeyboardInterrupt:
    print("\nDeployment cancelled.", file=sys.stderr)
    sys.exit(130)
except Exception as error:
    print()
    print(f"ERROR: {error}", file=sys.stderr)
    print("The website files were not updated unless the live API test passed.", file=sys.stderr)
    sys.exit(1)
PY
