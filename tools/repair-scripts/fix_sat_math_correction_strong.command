#!/usr/bin/env bash
set -euo pipefail

PROFILE="denduluru"
EXPECTED_ACCOUNT="989174615155"
REGION="us-east-1"
BUCKET="sat-prep-josh"
APP_KEY="math/app.js"
DISTRIBUTION_ID="E2WHKAAIHGKMVF"

HTML_KEYS=(
  "math/volume-1-algebra-foundations.html"
  "math/volume-2-advanced-math.html"
  "math/volume-3-data-geometry-trigonometry.html"
  "math/set-2-volume-1-algebra.html"
  "math/set-2-volume-2-advanced-math.html"
  "math/set-2-volume-3-data-geometry-trigonometry.html"
)

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
VERSION="20260801-${STAMP}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/math"

echo "AWS account: $ACCOUNT"
echo "Downloading current Math files..."

aws --profile "$PROFILE" --region "$REGION" \
  s3 cp "s3://$BUCKET/$APP_KEY" "$WORK_DIR/math/app.js" \
  --only-show-errors

for key in "${HTML_KEYS[@]}"; do
  file="$WORK_DIR/${key}"
  mkdir -p "$(dirname "$file")"
  aws --profile "$PROFILE" --region "$REGION" \
    s3 cp "s3://$BUCKET/$key" "$file" \
    --only-show-errors
done

python3 - "$WORK_DIR/math/app.js" "$VERSION" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text(encoding="utf-8")

marker_start = "      const saved = await recordAttempt("
marker_end = "    } catch (error) {"

start = text.find(marker_start)
if start < 0:
    raise SystemExit("ERROR: Could not find the recordAttempt success block.")

end = text.find(marker_end, start)
if end < 0:
    raise SystemExit("ERROR: Could not find the end of the recordAttempt success block.")

replacement = """      await recordAttempt(
        question.id,
        correct,
        choice,
        question.topic
      );

      /*
       * The submitted answer is authoritative for this render.
       * Do not dispatch sat-progress here because that event recreates
       * the card before the correction feedback can be displayed.
       */
      const progress = loadProgress();
      const now = new Date().toISOString();
      const previousAttempts = Number(existing?.attempts || 1);

      progress[question.id] = {
        ...(progress[question.id] || {}),
        correct,
        choice,
        attempts: previousAttempts + 1,
        attemptedAt: now,
        syncedAt: now,
        locked: true,
        correctionAllowed: false,
        correctionSource: null,
        autoCorrectionAvailable: false
      };

      localStorage.setItem(
        storageKey(),
        JSON.stringify(progress)
      );

      delete state.selected[question.id];

      /*
       * Rebuild from the newly submitted local record. This prevents
       * an immediately stale cloud query from restoring the old answer.
       */
      render();

      requestAnimationFrame(() => {
        const updatedCard = document.getElementById(question.id);
        if (!updatedCard) return;

        updatedCard.classList.remove("incorrect");
        updatedCard.classList.add(
          correct ? "correct" : "incorrect"
        );

        showFeedback(
          updatedCard,
          correct,
          correct
            ? "Correct after correction. This question is complete."
            : "Incorrect after correction. This question is now locked."
        );

        updatedCard.scrollIntoView({
          behavior: "smooth",
          block: "center"
        });
      });
"""

text = text[:start] + replacement + text[end:]

# Add a visible build marker for verification.
build_line = f"const SAT_CORRECTION_BUILD = '{version}';\n"
if "const SAT_CORRECTION_BUILD =" in text:
    text = re.sub(
        r"const SAT_CORRECTION_BUILD\s*=\s*['\"][^'\"]+['\"];\s*",
        build_line,
        text,
        count=1,
    )
else:
    text = build_line + text

path.write_text(text, encoding="utf-8")
print(f"Patched app.js build {version}")
PY

echo "Checking JavaScript syntax..."
node --check "$WORK_DIR/math/app.js"

echo "Verifying the strong fix..."
grep -q "The submitted answer is authoritative for this render" \
  "$WORK_DIR/math/app.js"
grep -q "localStorage.setItem" "$WORK_DIR/math/app.js"
grep -q "Correct after correction. This question is complete." \
  "$WORK_DIR/math/app.js"

echo "Updating Math HTML cache versions..."
for key in "${HTML_KEYS[@]}"; do
  file="$WORK_DIR/$key"
  python3 - "$file" "$VERSION" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text(encoding="utf-8")

text, count = re.subn(
    r'(<script\s+src=["\'](?:\./)?app\.js)(?:\?[^"\']*)?(["\'])',
    rf'\1?v={version}\2',
    text,
    count=1,
    flags=re.IGNORECASE,
)

if count != 1:
    raise SystemExit(
        f"ERROR: app.js script reference not found in {path.name}"
    )

path.write_text(text, encoding="utf-8")
print(f"Updated {path.name}")
PY
done

echo "Backing up live files..."
aws --profile "$PROFILE" --region "$REGION" \
  s3 cp \
  "s3://$BUCKET/$APP_KEY" \
  "s3://$BUCKET/backups/correction-strong-fix-$STAMP/$APP_KEY" \
  --only-show-errors

for key in "${HTML_KEYS[@]}"; do
  aws --profile "$PROFILE" --region "$REGION" \
    s3 cp \
    "s3://$BUCKET/$key" \
    "s3://$BUCKET/backups/correction-strong-fix-$STAMP/$key" \
    --only-show-errors
done

echo "Uploading fixed app.js..."
aws --profile "$PROFILE" --region "$REGION" \
  s3 cp "$WORK_DIR/math/app.js" "s3://$BUCKET/$APP_KEY" \
  --content-type "application/javascript; charset=utf-8" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --only-show-errors

echo "Uploading cache-busted Math pages..."
for key in "${HTML_KEYS[@]}"; do
  aws --profile "$PROFILE" --region "$REGION" \
    s3 cp "$WORK_DIR/$key" "s3://$BUCKET/$key" \
    --content-type "text/html; charset=utf-8" \
    --cache-control "no-cache, no-store, must-revalidate" \
    --only-show-errors
done

echo "Verifying deployed build marker..."
REMOTE_BUILD="$(
  aws --profile "$PROFILE" --region "$REGION" \
    s3 cp "s3://$BUCKET/$APP_KEY" - \
    --only-show-errors |
    head -n 1
)"

echo "Remote first line: $REMOTE_BUILD"

if [[ "$REMOTE_BUILD" != *"$VERSION"* ]]; then
  echo "ERROR: Uploaded app.js did not contain the expected build marker." >&2
  exit 1
fi

if aws --profile "$PROFILE" --region "$REGION" \
  cloudfront get-distribution \
  --id "$DISTRIBUTION_ID" >/dev/null 2>&1; then

  echo "Invalidating CloudFront..."
  aws --profile "$PROFILE" --region "$REGION" \
    cloudfront create-invalidation \
    --distribution-id "$DISTRIBUTION_ID" \
    --paths "/math/app.js*" "/math/*.html*" \
    --output text >/dev/null
fi

echo
echo "STRONG CORRECTION FIX DEPLOYED"
echo "Build: $VERSION"
echo
echo "Close the Math browser tab completely."
echo "Open the student Math link again in a new tab."
echo "The old answer must no longer replace the newly submitted correction."
