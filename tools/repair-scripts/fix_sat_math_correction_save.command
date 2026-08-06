#!/usr/bin/env bash
set -euo pipefail

PROFILE="denduluru"
EXPECTED_ACCOUNT="989174615155"
REGION="us-east-1"
BUCKET="sat-prep-josh"
APP_KEY="math/app.js"
DISTRIBUTION_ID="E2WHKAAIHGKMVF"

for command in aws python3 node; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERROR: $command is required." >&2
    exit 1
  }
done

ACCOUNT="$(
  aws --profile "$PROFILE" --region "$REGION" \
    sts get-caller-identity \
    --query Account \
    --output text
)"

if [[ "$ACCOUNT" != "$EXPECTED_ACCOUNT" ]]; then
  echo "ERROR: Expected AWS account $EXPECTED_ACCOUNT but found $ACCOUNT." >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

LIVE_APP="$WORK_DIR/app.js"
PATCHED_APP="$WORK_DIR/app-patched.js"

echo "AWS account: $ACCOUNT"
echo "Downloading s3://$BUCKET/$APP_KEY ..."

aws --profile "$PROFILE" --region "$REGION" \
  s3 cp "s3://$BUCKET/$APP_KEY" "$LIVE_APP" \
  --only-show-errors

cp "$LIVE_APP" "$PATCHED_APP"

python3 - "$PATCHED_APP" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

old = """      const saved = await recordAttempt(question.id, correct, choice, question.topic);
      const progress = loadProgress();
      progress[question.id] = cloudItemToLocal(saved);
      saveProgress(progress);
      delete state.selected[question.id];
      await syncFromCloud();"""

new = """      const saved = await recordAttempt(
        question.id,
        correct,
        choice,
        question.topic
      );

      /*
       * Preserve the answer that was just submitted. A DynamoDB query
       * immediately after an update can briefly return the previous record.
       * Do not replace the new correction with that stale cloud value.
       */
      const progress = loadProgress();
      const existingAttempts = Number(existing?.attempts || 1);
      const savedLocal = cloudItemToLocal(saved);

      progress[question.id] = {
        ...savedLocal,
        correct,
        choice,
        attempts: Math.max(
          Number(savedLocal.attempts || 0),
          existingAttempts + 1
        ),
        attemptedAt: new Date().toISOString(),
        syncedAt: new Date().toISOString(),
        locked: true,
        correctionAllowed: false
      };

      saveProgress(progress);
      delete state.selected[question.id];

      card.classList.remove("incorrect");
      card.classList.add(correct ? "correct" : "incorrect");
      disableAnswerControls(card);

      showFeedback(
        card,
        correct,
        correct
          ? "Correct after correction. This question is complete."
          : "Incorrect after correction. This question is now locked."
      );

      updateStats();"""

if old in text:
    text = text.replace(old, new, 1)
elif "Correct after correction. This question is complete." in text and "Do not replace the new correction with that stale cloud value." in text:
    print("Hotfix is already present.")
else:
    pattern = re.compile(
        r"""      const saved = await recordAttempt\(
?.*?
?      await syncFromCloud\(\);""",
        re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        raise SystemExit(
            "ERROR: Could not locate the correction save block in live math/app.js."
        )
    text = text[:match.start()] + new + text[match.end():]

path.write_text(text, encoding="utf-8")
print("Patched correction save behavior.")
PY

echo "Checking JavaScript syntax ..."
node --check "$PATCHED_APP"

if cmp -s "$LIVE_APP" "$PATCHED_APP"; then
  echo "The hotfix is already installed. No upload is needed."
  exit 0
fi

echo "Backing up current app.js ..."
aws --profile "$PROFILE" --region "$REGION" \
  s3 cp \
  "s3://$BUCKET/$APP_KEY" \
  "s3://$BUCKET/backups/correction-save-hotfix-$STAMP/$APP_KEY" \
  --only-show-errors

echo "Uploading corrected app.js ..."
aws --profile "$PROFILE" --region "$REGION" \
  s3 cp "$PATCHED_APP" "s3://$BUCKET/$APP_KEY" \
  --content-type "application/javascript; charset=utf-8" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --only-show-errors

if aws --profile "$PROFILE" --region "$REGION" \
  cloudfront get-distribution \
  --id "$DISTRIBUTION_ID" >/dev/null 2>&1; then

  echo "Invalidating CloudFront cache ..."
  aws --profile "$PROFILE" --region "$REGION" \
    cloudfront create-invalidation \
    --distribution-id "$DISTRIBUTION_ID" \
    --paths "/math/app.js*" \
    --output text >/dev/null
fi

echo
echo "HOTFIX DEPLOYED"
echo "A newly submitted correction will no longer be replaced by the previous answer."
echo "After deployment, refresh the Math page once using Command+Shift+R."
