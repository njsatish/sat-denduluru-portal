#!/usr/bin/env bash
set -euo pipefail

# SAT Math milestone-retry repair
# No arguments are required.

PROFILE="denduluru"
EXPECTED_ACCOUNT="989174615155"
REGION="us-east-1"
BUCKET="sat-prep-josh"
APP_KEY="math/app.js"
TABLE_NAME="sat-progress"
DISTRIBUTION_ID="E2WHKAAIHGKMVF"

HTML_KEYS=(
  "math/volume-1-algebra-foundations.html"
  "math/volume-2-advanced-math.html"
  "math/volume-3-data-geometry-trigonometry.html"
  "math/set-2-volume-1-algebra.html"
  "math/set-2-volume-2-advanced-math.html"
  "math/set-2-volume-3-data-geometry-trigonometry.html"
)

required_commands=(aws python3 node curl unzip zip)
for command in "${required_commands[@]}"; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: $command is required." >&2
    exit 1
  }
done

AWS=(aws --profile "$PROFILE" --region "$REGION")
WORK_DIR="$(mktemp -d)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BUILD="20260801-retry-v3-$STAMP"
TEST_USER="retrytest$(date -u +%H%M%S)$$"
ROLLBACK_NEEDED=0
LAMBDA_FUNCTION=""
OLD_LAMBDA_ZIP="$WORK_DIR/lambda-before.zip"

cleanup_test_data() {
  if [[ -n "${TEST_USER:-}" ]]; then
    python3 - "$WORK_DIR/delete-test-items.json" "$TABLE_NAME" "$TEST_USER" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
table = sys.argv[2]
user = sys.argv[3]
requests = [
    {
        "DeleteRequest": {
            "Key": {
                "userId": {"S": user},
                "questionId": {"S": f"v3q{number:03d}"}
            }
        }
    }
    for number in range(1, 21)
]
path.write_text(json.dumps({table: requests}), encoding="utf-8")
PY
    "${AWS[@]}" dynamodb batch-write-item \
      --request-items "file://$WORK_DIR/delete-test-items.json" \
      >/dev/null 2>&1 || true
  fi
}

rollback_lambda() {
  if [[ "$ROLLBACK_NEEDED" -eq 1 && -s "$OLD_LAMBDA_ZIP" && -n "$LAMBDA_FUNCTION" ]]; then
    echo
    echo "Restoring the previous Lambda package..."
    "${AWS[@]}" lambda update-function-code \
      --function-name "$LAMBDA_FUNCTION" \
      --zip-file "fileb://$OLD_LAMBDA_ZIP" \
      >/dev/null || true
    "${AWS[@]}" lambda wait function-updated \
      --function-name "$LAMBDA_FUNCTION" >/dev/null 2>&1 || true
  fi
}

finish() {
  status=$?
  cleanup_test_data
  if [[ "$status" -ne 0 ]]; then
    rollback_lambda
    echo
    echo "DEPLOYMENT STOPPED. The website files were not changed." >&2
  fi
  rm -rf "$WORK_DIR"
  exit "$status"
}
trap finish EXIT

ACCOUNT="$(
  "${AWS[@]}" sts get-caller-identity \
    --query Account \
    --output text
)"

if [[ "$ACCOUNT" != "$EXPECTED_ACCOUNT" ]]; then
  echo "ERROR: Expected account $EXPECTED_ACCOUNT, but AWS returned $ACCOUNT." >&2
  exit 1
fi

echo "============================================================"
echo " SAT Math correction repair"
echo "============================================================"
echo "AWS profile:  $PROFILE"
echo "AWS account:  $ACCOUNT"
echo "S3 bucket:    $BUCKET"
echo "Build:        $BUILD"
echo

mkdir -p "$WORK_DIR/live/math" "$WORK_DIR/patched/math" "$WORK_DIR/lambda"

echo "1. Downloading the exact live Math files..."
"${AWS[@]}" s3 cp \
  "s3://$BUCKET/$APP_KEY" \
  "$WORK_DIR/live/math/app.js" \
  --only-show-errors

for key in "${HTML_KEYS[@]}"; do
  destination="$WORK_DIR/live/$key"
  mkdir -p "$(dirname "$destination")"
  "${AWS[@]}" s3 cp \
    "s3://$BUCKET/$key" \
    "$destination" \
    --only-show-errors
done

PROGRESS_API="$(
  python3 - "$WORK_DIR/live/math/app.js" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r"""const\s+PROGRESS_API\s*=\s*['"]([^'"]+)['"]""",
    text,
)
if not match:
    match = re.search(
        r"""https://[A-Za-z0-9-]+\.lambda-url\.[A-Za-z0-9-]+\.on\.aws/?""",
        text,
    )
if not match:
    raise SystemExit("ERROR: PROGRESS_API was not found in live math/app.js.")
url = match.group(1) if match.lastindex else match.group(0)
print(url if url.endswith("/") else url + "/")
PY
)"

echo "Progress API: $PROGRESS_API"

echo
echo "2. Finding the Lambda used by that exact Function URL..."
while IFS= read -r function_name; do
  [[ -z "$function_name" ]] && continue
  function_url="$(
    "${AWS[@]}" lambda get-function-url-config \
      --function-name "$function_name" \
      --query FunctionUrl \
      --output text 2>/dev/null || true
  )"
  if [[ "$function_url" == "$PROGRESS_API" ]]; then
    LAMBDA_FUNCTION="$function_name"
    break
  fi
done < <(
  "${AWS[@]}" lambda list-functions \
    --query 'Functions[].FunctionName' \
    --output text |
    tr '\t' '\n'
)

if [[ -z "$LAMBDA_FUNCTION" ]]; then
  echo "ERROR: No Lambda Function URL matches $PROGRESS_API" >&2
  exit 1
fi

echo "Lambda:       $LAMBDA_FUNCTION"

HANDLER_SETTING="$(
  "${AWS[@]}" lambda get-function-configuration \
    --function-name "$LAMBDA_FUNCTION" \
    --query Handler \
    --output text
)"
HANDLER_MODULE="${HANDLER_SETTING%.*}"

CODE_URL="$(
  "${AWS[@]}" lambda get-function \
    --function-name "$LAMBDA_FUNCTION" \
    --query 'Code.Location' \
    --output text
)"

curl -fsSL "$CODE_URL" -o "$OLD_LAMBDA_ZIP"
unzip -q "$OLD_LAMBDA_ZIP" -d "$WORK_DIR/lambda/original"

HANDLER_FILE=""
for extension in mjs js cjs; do
  candidate="$WORK_DIR/lambda/original/$HANDLER_MODULE.$extension"
  if [[ -f "$candidate" ]]; then
    HANDLER_FILE="$candidate"
    break
  fi
done

if [[ -z "$HANDLER_FILE" ]]; then
  HANDLER_FILE="$(
    find "$WORK_DIR/lambda/original" -maxdepth 2 \
      -type f \( -name '*.mjs' -o -name '*.js' -o -name '*.cjs' \) \
      | head -n 1
  )"
fi

if [[ -z "$HANDLER_FILE" || ! -f "$HANDLER_FILE" ]]; then
  echo "ERROR: Lambda handler source could not be located." >&2
  exit 1
fi

echo "Handler file: ${HANDLER_FILE#$WORK_DIR/lambda/original/}"

echo
echo "3. Patching the live Lambda with a consistent, server-enforced retry policy..."
python3 - "$HANDLER_FILE" "$BUILD" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
build = sys.argv[2]
text = path.read_text(encoding="utf-8")

# Ensure required DynamoDB document commands are imported.
import_match = re.search(
    r'import\s*\{(?P<body>[\s\S]*?)\}\s*from\s*[\'"]@aws-sdk/lib-dynamodb[\'"];?',
    text,
)
if not import_match:
    raise SystemExit(
        "ERROR: @aws-sdk/lib-dynamodb import was not found in the Lambda."
    )

names = [
    name.strip()
    for name in import_match.group("body").split(",")
    if name.strip()
]
for required in ("GetCommand", "QueryCommand", "UpdateCommand"):
    if required not in names:
        names.append(required)

new_import = (
    "import {\n  " +
    ",\n  ".join(dict.fromkeys(names)) +
    "\n} from '@aws-sdk/lib-dynamodb';"
)
text = (
    text[:import_match.start()] +
    new_import +
    text[import_match.end():]
)

start_candidates = [
    index for index in (
        text.find("// BEGIN SAT_MILESTONE_RETRY_V3"),
        text.find("function mathQuestionPosition("),
        text.find("async function recordAttempt("),
    )
    if index >= 0
]
if not start_candidates:
    raise SystemExit("ERROR: recordAttempt function was not found.")

start = min(start_candidates)
end = text.find("async function createStudent", start)
if end < 0:
    raise SystemExit("ERROR: createStudent function was not found after recordAttempt.")

block = f"""// BEGIN SAT_MILESTONE_RETRY_V3
const SAT_RETRY_BUILD = '{build}';
const SAT_RETRY_MILESTONE_SIZE = 20;

function mathQuestionPosition(questionId) {{
  const id = String(questionId || '').trim();

  let match = id.match(/^v([1-3])q(\\d{{3}})$/i);
  if (match) {{
    return {{
      group: `v${{match[1]}}q`,
      setNumber: 1,
      volumeNumber: Number(match[1]),
      questionNumber: Number(match[2]),
      totalQuestions: 100
    }};
  }}

  match = id.match(/^s(\\d+)v([1-3])q(\\d{{3}})$/i);
  if (match) {{
    return {{
      group: `s${{match[1]}}v${{match[2]}}q`,
      setNumber: Number(match[1]),
      volumeNumber: Number(match[2]),
      questionNumber: Number(match[3]),
      totalQuestions: 100
    }};
  }}

  return null;
}}

function progressFirstTime(item) {{
  const time = Date.parse(item?.firstAt || item?.lastAt || '');
  return Number.isFinite(time) ? time : Number.MAX_SAFE_INTEGER;
}}

function normalizeProgressItem(item) {{
  const attempted = Boolean(item?.lastResult);
  const storedLocked =
    typeof item?.locked === 'boolean' ? item.locked : attempted;
  const storedCorrectionAllowed =
    item?.correctionAllowed === true;

  return {{
    ...item,
    attempts: Number(item?.attempts || (attempted ? 1 : 0)),
    storedLocked,
    storedCorrectionAllowed,
    locked: storedLocked,
    correctionAllowed:
      attempted &&
      item.lastResult === 'incorrect' &&
      (!storedLocked || storedCorrectionAllowed)
  }};
}}

function decorateProgressItems(rawItems) {{
  const items = (rawItems || []).map(normalizeProgressItem);
  const grouped = new Map();

  for (const item of items) {{
    const position = mathQuestionPosition(item.questionId);
    if (!position) continue;

    if (!grouped.has(position.group)) {{
      grouped.set(position.group, {{
        position,
        items: []
      }});
    }}

    grouped.get(position.group).items.push(item);
  }}

  const retryPolicy = {{}};

  for (const [group, value] of grouped.entries()) {{
    const sorted = [...value.items].sort((left, right) => {{
      const timeDifference =
        progressFirstTime(left) - progressFirstTime(right);

      if (timeDifference !== 0) return timeDifference;

      const leftNumber =
        mathQuestionPosition(left.questionId)?.questionNumber || 999;
      const rightNumber =
        mathQuestionPosition(right.questionId)?.questionNumber || 999;

      return leftNumber - rightNumber;
    }});

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

    sorted.forEach((item, index) => {{
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
    }});

    retryPolicy[group] = {{
      setNumber: value.position.setNumber,
      volumeNumber: value.position.volumeNumber,
      totalQuestions: value.position.totalQuestions,
      attempted,
      milestoneUnlocked,
      nextMilestone,
      attemptsToNext: Math.max(0, nextMilestone - attempted),
      retryAvailable
    }};
  }}

  return {{ items, retryPolicy }};
}}

async function queryAllProgress(userId) {{
  const result = await ddb.send(new QueryCommand({{
    TableName: TABLE,
    KeyConditionExpression: 'userId = :userId',
    ExpressionAttributeValues: {{ ':userId': userId }},
    ConsistentRead: true
  }}));

  return result.Items || [];
}}

async function queryVolumeProgress(userId, group) {{
  const result = await ddb.send(new QueryCommand({{
    TableName: TABLE,
    KeyConditionExpression:
      'userId = :userId AND begins_with(questionId, :group)',
    ExpressionAttributeValues: {{
      ':userId': userId,
      ':group': group
    }},
    ConsistentRead: true
  }}));

  return result.Items || [];
}}

async function getProgressItem(userId, questionId) {{
  const result = await ddb.send(new GetCommand({{
    TableName: TABLE,
    Key: {{ userId, questionId }},
    ConsistentRead: true
  }}));

  return result.Item || null;
}}

async function isAutomaticCorrectionAvailable(userId, questionId) {{
  const position = mathQuestionPosition(questionId);
  if (!position) return false;

  const rawItems =
    await queryVolumeProgress(userId, position.group);
  const decorated =
    decorateProgressItems(rawItems).items;
  const item = decorated.find(candidate =>
    candidate.questionId === questionId
  );

  return Boolean(item?.autoCorrectionAvailable);
}}

async function decorateSavedProgressItem(userId, savedItem) {{
  const position =
    mathQuestionPosition(savedItem?.questionId);

  if (!position) return normalizeProgressItem(savedItem);

  const rawItems =
    await queryVolumeProgress(userId, position.group);
  const item = decorateProgressItems(rawItems).items.find(
    candidate => candidate.questionId === savedItem.questionId
  );

  return item || normalizeProgressItem(savedItem);
}}

async function recordAttempt({{
  userId,
  questionId,
  correct,
  choice,
  category
}}) {{
  const validQuestionId = requireQuestionId(questionId);
  const now = new Date().toISOString();
  const existing =
    await getProgressItem(userId, validQuestionId);

  let attemptMode = 'first';

  if (existing) {{
    const attempts = Number(existing.attempts || 1);

    if (existing.lastResult === 'correct') {{
      throw new HttpError(
        409,
        'QUESTION_LOCKED',
        'This question has already been completed'
      );
    }}

    if (existing.locked === false) {{
      attemptMode = 'administrator';
    }} else if (
      attempts === 1 &&
      await isAutomaticCorrectionAvailable(
        userId,
        validQuestionId
      )
    ) {{
      attemptMode = 'milestone';
    }} else {{
      throw new HttpError(
        409,
        'QUESTION_LOCKED',
        attempts > 1
          ? 'The correction attempt is complete; administrator approval is required'
          : 'This question is locked until its 20-question correction milestone'
      );
    }}
  }}

  const conditionExpression =
    attemptMode === 'first'
      ? 'attribute_not_exists(#lastResult)'
      : attemptMode === 'administrator'
        ? '#lastResult = :incorrect AND #locked = :false'
        : '#lastResult = :incorrect AND #attempts = :one';

  try {{
    const result = await ddb.send(new UpdateCommand({{
      TableName: TABLE,
      Key: {{
        userId,
        questionId: validQuestionId
      }},
      UpdateExpression:
        'ADD #attempts :one, #correctCount :correctIncrement ' +
        'SET #lastResult = :result, #lastChoice = :choice, ' +
        '#lastAt = :now, #category = :category, ' +
        '#firstAt = if_not_exists(#firstAt, :now), ' +
        '#locked = :true, #correctionAllowed = :false, ' +
        '#lastAttemptType = :attemptMode',
      ConditionExpression: conditionExpression,
      ExpressionAttributeNames: {{
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
      }},
      ExpressionAttributeValues: {{
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
      }},
      ReturnValues: 'ALL_NEW'
    }}));

    return decorateSavedProgressItem(
      userId,
      result.Attributes
    );
  }} catch (error) {{
    if (
      error?.name ===
      'ConditionalCheckFailedException'
    ) {{
      throw new HttpError(
        409,
        'QUESTION_LOCKED',
        'This question is no longer available for another attempt'
      );
    }}

    throw error;
  }}
}}

async function getProgress(userId) {{
  const rawItems = await queryAllProgress(userId);
  const decorated = decorateProgressItems(rawItems);
  const items = decorated.items;

  const summary = items.reduce((value, item) => {{
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

    value.byCategory[category] ||= {{
      attempted: 0,
      mastered: 0
    }};
    value.byCategory[category].attempted += 1;

    if (everCorrect) {{
      value.byCategory[category].mastered += 1;
    }}

    return value;
  }}, {{
    attempted: 0,
    mastered: 0,
    totalAttempts: 0,
    totalCorrect: 0,
    lockedIncorrect: 0,
    retryAvailable: 0,
    byCategory: {{}}
  }});

  summary.accuracy = summary.totalAttempts > 0
    ? +(
        summary.totalCorrect /
        summary.totalAttempts
      ).toFixed(3)
    : 0;

  return {{
    items,
    summary,
    retryPolicy: decorated.retryPolicy,
    retryBuild: SAT_RETRY_BUILD
  }};
}}
// END SAT_MILESTONE_RETRY_V3

"""

text = text[:start] + block + text[end:]
path.write_text(text, encoding="utf-8")
print("Lambda retry policy patched.")
PY

echo "Checking Lambda syntax..."
node --check "$HANDLER_FILE"

echo
echo "4. Patching the exact live Math application..."
cp "$WORK_DIR/live/math/app.js" \
   "$WORK_DIR/patched/math/app.js"

python3 - "$WORK_DIR/patched/math/app.js" "$BUILD" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
build = sys.argv[2]
text = path.read_text(encoding="utf-8")

# Add or replace a visible build marker.
build_line = f"const SAT_RETRY_UI_BUILD = '{build}';\n"
text = re.sub(
    r"const SAT_RETRY_UI_BUILD\s*=\s*['\"][^'\"]+['\"];\s*",
    "",
    text,
    count=1,
)
text = build_line + text

cloud_pattern = re.compile(
    r"function cloudItemToLocal\(item\) \{[\s\S]*?\n\}\n\nasync function syncFromCloud",
)
cloud_replacement = """function cloudItemToLocal(item) {
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

async function syncFromCloud"""
text, count = cloud_pattern.subn(
    cloud_replacement,
    text,
    count=1,
)
if count != 1:
    raise SystemExit(
        "ERROR: cloudItemToLocal could not be patched."
    )

apply_pattern = re.compile(
    r"  function applySavedState\(question, card, progress\) \{[\s\S]*?\n  \}\n\n  function renderQuestion",
)
apply_replacement = """  function applySavedState(question, card, progress) {
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

  function renderQuestion"""
text, count = apply_pattern.subn(
    apply_replacement,
    text,
    count=1,
)
if count != 1:
    raise SystemExit(
        "ERROR: applySavedState could not be patched."
    )

check_pattern = re.compile(
    r"  async function check\(question, card\) \{[\s\S]*?\n  \}\n\n  function showFeedback",
)
check_replacement = """  async function check(question, card) {
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
    checkButton.textContent = 'Saving…';

    try {
      const saved = await recordAttempt(
        question.id,
        correct,
        choice,
        question.topic
      );

      /*
       * The Lambda response from UpdateCommand is the source of truth.
       * Store that response and render it immediately. Do not perform
       * another progress query in this save path.
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

  function showFeedback"""
text, count = check_pattern.subn(
    check_replacement,
    text,
    count=1,
)
if count != 1:
    raise SystemExit(
        "ERROR: check function could not be patched."
    )

# Ensure the previously wrong MCQ choice has visible styling.
if ".choice.previous-wrong" not in text:
    style = """
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
    text += "\n" + style

path.write_text(text, encoding="utf-8")
print("Math app save and render behavior patched.")
PY

echo "Checking Math JavaScript syntax..."
node --check "$WORK_DIR/patched/math/app.js"

echo
echo "5. Cache-busting all six Math volume pages..."
for key in "${HTML_KEYS[@]}"; do
  source="$WORK_DIR/live/$key"
  destination="$WORK_DIR/patched/$key"
  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"

  python3 - "$destination" "$BUILD" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
build = sys.argv[2]
text = path.read_text(encoding="utf-8")

text, count = re.subn(
    r'(<script\s+src=["\'](?:\./)?app\.js)(?:\?[^"\']*)?(["\'])',
    rf'\1?v={build}\2',
    text,
    count=1,
    flags=re.IGNORECASE,
)

if count != 1:
    raise SystemExit(
        f"ERROR: app.js reference not found in {path.name}"
    )

path.write_text(text, encoding="utf-8")
PY
done

echo
echo "6. Backing up the current live files..."
"${AWS[@]}" s3 cp \
  "s3://$BUCKET/$APP_KEY" \
  "s3://$BUCKET/backups/retry-v3-$STAMP/$APP_KEY" \
  --only-show-errors

for key in "${HTML_KEYS[@]}"; do
  "${AWS[@]}" s3 cp \
    "s3://$BUCKET/$key" \
    "s3://$BUCKET/backups/retry-v3-$STAMP/$key" \
    --only-show-errors
done

"${AWS[@]}" s3 cp \
  "$OLD_LAMBDA_ZIP" \
  "s3://$BUCKET/backups/retry-v3-$STAMP/lambda-before.zip" \
  --only-show-errors

echo
echo "7. Deploying the Lambda and running a real end-to-end API test..."
(
  cd "$WORK_DIR/lambda/original"
  zip -qr "$WORK_DIR/lambda-patched.zip" .
)

ROLLBACK_NEEDED=1
"${AWS[@]}" lambda update-function-code \
  --function-name "$LAMBDA_FUNCTION" \
  --zip-file "fileb://$WORK_DIR/lambda-patched.zip" \
  >/dev/null

"${AWS[@]}" lambda wait function-updated \
  --function-name "$LAMBDA_FUNCTION"

api_call() {
  local payload="$1"
  curl -fsS \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$PROGRESS_API"
}

for number in $(seq 1 20); do
  question_id="$(printf 'v3q%03d' "$number")"

  if [[ "$number" -eq 1 ]]; then
    correct=false
    choice='"wrong-first-answer"'
  else
    correct=true
    choice='"test-answer"'
  fi

  payload="$(
    python3 - "$TEST_USER" "$question_id" "$correct" "$choice" <<'PY'
import json
import sys

user, question, correct_raw, choice_raw = sys.argv[1:]
print(json.dumps({
    "action": "record",
    "userId": user,
    "questionId": question,
    "correct": correct_raw == "true",
    "choice": json.loads(choice_raw),
    "category": "deployment-test"
}))
PY
  )"

  api_call "$payload" >/dev/null
done

progress_payload="$(
  python3 - "$TEST_USER" <<'PY'
import json
import sys
print(json.dumps({
    "action": "progress",
    "userId": sys.argv[1]
}))
PY
)"

api_call "$progress_payload" \
  > "$WORK_DIR/progress-after-20.json"

python3 - "$WORK_DIR/progress-after-20.json" <<'PY'
from pathlib import Path
import json
import sys

data = json.loads(Path(sys.argv[1]).read_text())
item = next(
    (
        value
        for value in data.get("items", [])
        if value.get("questionId") == "v3q001"
    ),
    None,
)

if not item:
    raise SystemExit("API TEST FAILED: v3q001 was not returned.")

if item.get("correctionAllowed") is not True:
    raise SystemExit(
        "API TEST FAILED: correction did not unlock after 20 unique attempts."
    )

if item.get("milestoneUnlocked") != 20:
    raise SystemExit(
        f"API TEST FAILED: milestone was {item.get('milestoneUnlocked')}, expected 20."
    )

print("PASS: correction unlocked after 20 unique first attempts.")
PY

retry_payload="$(
  python3 - "$TEST_USER" <<'PY'
import json
import sys
print(json.dumps({
    "action": "record",
    "userId": sys.argv[1],
    "questionId": "v3q001",
    "correct": True,
    "choice": "corrected-answer",
    "category": "deployment-test"
}))
PY
)"

api_call "$retry_payload" \
  > "$WORK_DIR/retry-result.json"

python3 - "$WORK_DIR/retry-result.json" <<'PY'
from pathlib import Path
import json
import sys

item = json.loads(Path(sys.argv[1]).read_text())

if item.get("lastResult") != "correct":
    raise SystemExit(
        f"API TEST FAILED: retry result is {item.get('lastResult')!r}."
    )

if int(item.get("attempts", 0)) != 2:
    raise SystemExit(
        f"API TEST FAILED: attempts is {item.get('attempts')!r}, expected 2."
    )

if item.get("lastChoice") != "corrected-answer":
    raise SystemExit(
        f"API TEST FAILED: lastChoice is {item.get('lastChoice')!r}."
    )

print("PASS: corrected answer was saved as the latest answer.")
PY

ROLLBACK_NEEDED=0
cleanup_test_data
TEST_USER=""

echo
echo "8. API test passed. Uploading the corrected website files..."
"${AWS[@]}" s3 cp \
  "$WORK_DIR/patched/math/app.js" \
  "s3://$BUCKET/$APP_KEY" \
  --content-type "application/javascript; charset=utf-8" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --only-show-errors

for key in "${HTML_KEYS[@]}"; do
  "${AWS[@]}" s3 cp \
    "$WORK_DIR/patched/$key" \
    "s3://$BUCKET/$key" \
    --content-type "text/html; charset=utf-8" \
    --cache-control "no-cache, no-store, must-revalidate" \
    --only-show-errors
done

REMOTE_BUILD="$(
  "${AWS[@]}" s3 cp \
    "s3://$BUCKET/$APP_KEY" - \
    --only-show-errors |
    head -n 1
)"

if [[ "$REMOTE_BUILD" != *"$BUILD"* ]]; then
  echo "ERROR: The deployed app.js build marker could not be verified." >&2
  exit 1
fi

if "${AWS[@]}" cloudfront get-distribution \
  --id "$DISTRIBUTION_ID" >/dev/null 2>&1; then

  echo
  echo "9. Invalidating CloudFront..."
  "${AWS[@]}" cloudfront create-invalidation \
    --distribution-id "$DISTRIBUTION_ID" \
    --paths "/math/app.js*" "/math/*.html*" \
    --output text >/dev/null
fi

echo
echo "============================================================"
echo " DEPLOYMENT AND LIVE API TEST PASSED"
echo "============================================================"
echo "Build: $BUILD"
echo
echo "The server successfully proved all of these:"
echo "  • 20 unique first attempts unlocked correction."
echo "  • The corrected answer was accepted."
echo "  • attempts changed from 1 to 2."
echo "  • lastChoice changed to the newly submitted answer."
echo
echo "Close every open SAT Math tab."
echo "Open the student link in a completely new tab."
echo "Submit the correction once."
