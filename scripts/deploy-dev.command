#!/usr/bin/env bash
set -Eeuo pipefail

PROFILE="denduluru"
REGION="us-east-1"
EXPECTED_ACCOUNT="989174615155"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_SOURCE="$ROOT/site"
LAMBDA_SOURCE="$ROOT/lambda/sat-progress-handler/source"

DEV_BUCKET="sat-prep-josh-dev"
DEV_FUNCTION="sat-progress-handler-dev"
DEV_TABLE="sat-progress-dev"
DEV_DOMAIN="dev-sat.denduluru.com"
DISTRIBUTION_ID="E2YNYV2XTI6ODH"

PROD_TABLE="sat-progress"
PROD_BUCKET="sat-prep-josh"

AWS=(aws --profile "$PROFILE" --region "$REGION")
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sat-deploy-dev.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

ACCOUNT="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] || {
  echo "Wrong AWS account: $ACCOUNT" >&2
  exit 1
}

cd "$ROOT"

[[ "$(git branch --show-current)" == "develop" ]] || {
  echo "Development deployment must run from the develop branch." >&2
  exit 1
}

[[ -z "$(git status --porcelain)" ]] || {
  echo "Commit your changes before deploying development." >&2
  exit 1
}

DEV_FUNCTION_URL="$(
  "${AWS[@]}" lambda get-function-url-config     --function-name "$DEV_FUNCTION"     --query FunctionUrl     --output text
)"

mkdir -p "$TEMP_DIR/site" "$TEMP_DIR/lambda"
cp -R "$SITE_SOURCE/." "$TEMP_DIR/site/"
cp -R "$LAMBDA_SOURCE/." "$TEMP_DIR/lambda/"

python3 -   "$TEMP_DIR/site"   "$TEMP_DIR/lambda"   "$DEV_FUNCTION_URL"   "$PROD_TABLE" "$DEV_TABLE"   "$PROD_BUCKET" "$DEV_BUCKET"   "https://sat.denduluru.com" "https://$DEV_DOMAIN" <<'PY'
import re
import sys
from pathlib import Path

site_root = Path(sys.argv[1])
lambda_root = Path(sys.argv[2])
dev_url = sys.argv[3]
replacements = list(zip(sys.argv[4::2], sys.argv[5::2]))

lambda_url_pattern = re.compile(
    r"https://[a-z0-9]+\.lambda-url\.[a-z0-9-]+\.on\.aws/?"
)

binary_suffixes = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico",
    ".zip", ".jar", ".class", ".woff", ".woff2", ".pdf",
    ".mp3", ".mp4", ".mov",
}

changed_lambda_urls = 0

for root in (site_root, lambda_root):
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() in binary_suffixes:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        updated, count = lambda_url_pattern.subn(dev_url, text)
        changed_lambda_urls += count

        for old, new in replacements:
            updated = updated.replace(old, new)

        if updated != text:
            path.write_text(updated, encoding="utf-8")

print(
    f"Patched {changed_lambda_urls} Lambda Function URL reference(s) "
    "for development."
)
PY

(
  cd "$TEMP_DIR/lambda"
  zip -qr "$TEMP_DIR/dev-lambda.zip" .
)

"${AWS[@]}" lambda update-function-code   --function-name "$DEV_FUNCTION"   --zip-file "fileb://$TEMP_DIR/dev-lambda.zip"   >/dev/null

"${AWS[@]}" lambda wait function-updated   --function-name "$DEV_FUNCTION"

"${AWS[@]}" s3 sync   "$TEMP_DIR/site"   "s3://$DEV_BUCKET"   --delete   --exclude "backups/*"   --only-show-errors

INVALIDATION_ID="$(
  "${AWS[@]}" cloudfront create-invalidation     --distribution-id "$DISTRIBUTION_ID"     --paths '/*'     --query 'Invalidation.Id'     --output text
)"

"${AWS[@]}" cloudfront wait invalidation-completed   --distribution-id "$DISTRIBUTION_ID"   --id "$INVALIDATION_ID"

HTTP_STATUS="$(
  curl -L -sS -o /dev/null -w '%{http_code}'     "https://$DEV_DOMAIN/"
)"

[[ "$HTTP_STATUS" == "200" ]] || {
  echo "Development portal returned HTTP $HTTP_STATUS." >&2
  exit 1
}

echo
echo "DEVELOPMENT DEPLOYMENT PASSED"
echo "URL: https://$DEV_DOMAIN"
echo "Commit: $(git rev-parse --short HEAD)"
