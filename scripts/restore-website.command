#!/usr/bin/env bash
set -Eeuo pipefail

PROFILE="denduluru"
REGION="us-east-1"
EXPECTED_ACCOUNT="989174615155"
BUCKET="sat-prep-josh"
DISTRIBUTION_ID="E2WHKAAIHGKMVF"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS=(aws --profile "$PROFILE" --region "$REGION")

ACCOUNT="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] || {
  echo "Wrong AWS account: $ACCOUNT" >&2
  exit 1
}

echo "This will restore the checked-out Git commit's site/ folder to:"
echo "  s3://$BUCKET"
echo
echo "Current Git commit:"
git -C "$ROOT" log -1 --oneline
echo
read -r -p "Type RESTORE to continue: " confirmation
[[ "$confirmation" == "RESTORE" ]] || {
  echo "Restore cancelled."
  exit 0
}

aws --profile "$PROFILE" --region "$REGION" s3 sync \
  "$ROOT/site" \
  "s3://$BUCKET" \
  --delete \
  --exclude "backups/*" \
  --only-show-errors

INVALIDATION_ID="$(
  aws --profile "$PROFILE" --region "$REGION" cloudfront create-invalidation \
    --distribution-id "$DISTRIBUTION_ID" \
    --paths '/*' \
    --query 'Invalidation.Id' \
    --output text
)"

aws --profile "$PROFILE" --region "$REGION" cloudfront wait \
  invalidation-completed \
  --distribution-id "$DISTRIBUTION_ID" \
  --id "$INVALIDATION_ID"

echo "Website restore completed."
