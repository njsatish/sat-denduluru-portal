#!/usr/bin/env bash
set -Eeuo pipefail

PROFILE="denduluru"
REGION="us-east-1"
EXPECTED_ACCOUNT="989174615155"
LAMBDA_FUNCTION="sat-progress-handler"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT/lambda/$LAMBDA_FUNCTION/source"
AWS=(aws --profile "$PROFILE" --region "$REGION")
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sat-lambda-restore.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

ACCOUNT="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] || {
  echo "Wrong AWS account: $ACCOUNT" >&2
  exit 1
}

[[ -d "$SOURCE_DIR" ]] || {
  echo "Lambda source folder is missing: $SOURCE_DIR" >&2
  exit 1
}

echo "This restores only Lambda CODE from the checked-out Git commit."
echo "The existing Lambda environment variables and Function URL remain unchanged."
echo
echo "Current Git commit:"
git -C "$ROOT" log -1 --oneline
echo
read -r -p "Type RESTORE to continue: " confirmation
[[ "$confirmation" == "RESTORE" ]] || {
  echo "Restore cancelled."
  exit 0
}

(
  cd "$SOURCE_DIR"
  zip -qr "$TEMP_DIR/lambda-package.zip" .
)

"${AWS[@]}" lambda update-function-code \
  --function-name "$LAMBDA_FUNCTION" \
  --zip-file "fileb://$TEMP_DIR/lambda-package.zip" \
  >/dev/null

"${AWS[@]}" lambda wait function-updated \
  --function-name "$LAMBDA_FUNCTION"

echo "Lambda code restore completed."
