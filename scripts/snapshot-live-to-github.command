#!/usr/bin/env bash
set -Eeuo pipefail

# Capture the absolute path immediately. Later steps change into the repository,
# so resolving $0 at that point would incorrectly look inside the repository.
SCRIPT_SOURCE="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Creates or updates a private GitHub disaster-recovery repository for
# sat.denduluru.com.
#
# Captures:
#   - Live S3 website files, excluding S3 backups
#   - Lambda source for sat-progress-handler
#   - Redacted Lambda and AWS infrastructure configuration
#   - SAT repair/deployment command files from ~/Downloads
#   - Guarded website and Lambda restore scripts
#
# Does NOT commit:
#   - Lambda environment-variable values
#   - AWS/GitHub credentials
#   - DynamoDB student/progress records
#   - Files larger than 95 MiB

PROFILE="denduluru"
REGION="us-east-1"
EXPECTED_ACCOUNT="989174615155"
BUCKET="sat-prep-josh"
LAMBDA_FUNCTION="sat-progress-handler"
DISTRIBUTION_ID="E2WHKAAIHGKMVF"
REPO_NAME="sat-denduluru-portal"
ROOT="${HOME}/Documents/${REPO_NAME}"
SITE_ORIGIN="https://sat.denduluru.com"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sat-github-backup.XXXXXX")"

AWS=(aws --profile "$PROFILE" --region "$REGION")

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

for command in aws git gh curl unzip zip python3; do
  if ! require_command "$command"; then
    if [[ "$command" == "gh" ]]; then
      cat >&2 <<'EOF'

ERROR: GitHub CLI (gh) is required.

On a Mac with Homebrew, install it with:
  brew install gh

Then run this command file again.
EOF
      exit 1
    fi
    fail "$command is required but was not found."
  fi
done

ACCOUNT="$(
  "${AWS[@]}" sts get-caller-identity \
    --query Account \
    --output text
)"

if [[ "$ACCOUNT" != "$EXPECTED_ACCOUNT" ]]; then
  fail "Expected AWS account $EXPECTED_ACCOUNT, but found $ACCOUNT."
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not signed in."
  echo "A browser window will open for GitHub authentication."
  gh auth login --web --git-protocol https
fi

GH_LOGIN="$(gh api user --jq .login)"
REMOTE_REPO="${GH_LOGIN}/${REPO_NAME}"

echo "========================================================================"
echo " SAT Denduluru private GitHub repository"
echo "========================================================================"
echo "AWS account:   $ACCOUNT"
echo "S3 bucket:     $BUCKET"
echo "Lambda:        $LAMBDA_FUNCTION"
echo "GitHub owner:  $GH_LOGIN"
echo "Repository:    $REMOTE_REPO"
echo "Local folder:  $ROOT"
echo "Snapshot:      $STAMP"
echo

if [[ -d "$ROOT/.git" ]]; then
  echo "1. Resuming with the existing local repository..."
  cd "$ROOT"
  if git remote get-url origin >/dev/null 2>&1; then
    git pull --rebase --autostash origin main || \
      fail "Could not update the existing local repository."
  fi
elif gh repo view "$REMOTE_REPO" >/dev/null 2>&1; then
  echo "1. Cloning the existing private repository..."
  mkdir -p "$(dirname "$ROOT")"
  gh repo clone "$REMOTE_REPO" "$ROOT"
  cd "$ROOT"
else
  echo "1. Preparing a new local repository..."
  mkdir -p "$ROOT"
  cd "$ROOT"
  git init -b main
fi

mkdir -p \
  "$ROOT/site" \
  "$ROOT/lambda/$LAMBDA_FUNCTION/source" \
  "$ROOT/infrastructure" \
  "$ROOT/tools/repair-scripts" \
  "$ROOT/scripts" \
  "$ROOT/docs"

cat > "$ROOT/.gitignore" <<'EOF'
.DS_Store
.env
.env.*
!.env.example
*.pem
*.key
*.p12
*.pfx
*.zip
__pycache__/
*.pyc
.local/
tmp/
EOF

echo "2. Mirroring the live S3 website..."
"${AWS[@]}" s3 sync \
  "s3://$BUCKET" \
  "$ROOT/site" \
  --delete \
  --exclude "backups/*" \
  --only-show-errors

echo "3. Recording the S3 manifest and bucket configuration..."
"${AWS[@]}" s3api list-objects-v2 \
  --bucket "$BUCKET" \
  --query 'Contents[].{Key:Key,Size:Size,ETag:ETag,LastModified:LastModified,StorageClass:StorageClass}' \
  --output json \
  > "$ROOT/infrastructure/s3-object-manifest.json"

"${AWS[@]}" s3api get-bucket-versioning \
  --bucket "$BUCKET" \
  --output json \
  > "$ROOT/infrastructure/s3-versioning.json"

"${AWS[@]}" s3api get-bucket-website \
  --bucket "$BUCKET" \
  --output json \
  > "$ROOT/infrastructure/s3-website.json" 2>/dev/null || \
  printf '{}\n' > "$ROOT/infrastructure/s3-website.json"

"${AWS[@]}" s3api get-bucket-policy \
  --bucket "$BUCKET" \
  --output json \
  > "$ROOT/infrastructure/s3-policy-wrapper.json" 2>/dev/null || \
  printf '{}\n' > "$ROOT/infrastructure/s3-policy-wrapper.json"

echo "4. Downloading and expanding the live Lambda source..."
rm -rf "$ROOT/lambda/$LAMBDA_FUNCTION/source"
mkdir -p "$ROOT/lambda/$LAMBDA_FUNCTION/source"

CODE_URL="$(
  "${AWS[@]}" lambda get-function \
    --function-name "$LAMBDA_FUNCTION" \
    --query 'Code.Location' \
    --output text
)"
curl -fsSL "$CODE_URL" -o "$TEMP_DIR/lambda-package.zip"
unzip -q "$TEMP_DIR/lambda-package.zip" \
  -d "$ROOT/lambda/$LAMBDA_FUNCTION/source"

"${AWS[@]}" lambda get-function-configuration \
  --function-name "$LAMBDA_FUNCTION" \
  --output json \
  > "$TEMP_DIR/lambda-config-raw.json"

python3 - \
  "$TEMP_DIR/lambda-config-raw.json" \
  "$ROOT/lambda/$LAMBDA_FUNCTION/configuration.redacted.json" \
  "$ROOT/lambda/$LAMBDA_FUNCTION/environment-keys.txt" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
keys_file = Path(sys.argv[3])

data = json.loads(source.read_text(encoding="utf-8"))
variables = (
    data.get("Environment", {})
    .get("Variables", {})
)

if "Environment" in data:
    data["Environment"]["Variables"] = {
        key: "<redacted>"
        for key in sorted(variables)
    }

destination.write_text(
    json.dumps(data, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
keys_file.write_text(
    "\n".join(sorted(variables)) + ("\n" if variables else ""),
    encoding="utf-8",
)
PY

"${AWS[@]}" lambda get-function-url-config \
  --function-name "$LAMBDA_FUNCTION" \
  --output json \
  > "$ROOT/lambda/$LAMBDA_FUNCTION/function-url.json"

"${AWS[@]}" lambda get-policy \
  --function-name "$LAMBDA_FUNCTION" \
  --output json \
  > "$ROOT/lambda/$LAMBDA_FUNCTION/resource-policy.json" 2>/dev/null || \
  printf '{}\n' > "$ROOT/lambda/$LAMBDA_FUNCTION/resource-policy.json"

echo "5. Recording CloudFront and DynamoDB configuration..."
"${AWS[@]}" cloudfront get-distribution-config \
  --id "$DISTRIBUTION_ID" \
  --output json \
  > "$ROOT/infrastructure/cloudfront-distribution.json"

"${AWS[@]}" dynamodb describe-table \
  --table-name sat-progress \
  --output json \
  > "$ROOT/infrastructure/dynamodb-table.json"

echo "6. Copying SAT repair and deployment scripts..."
rm -rf "$ROOT/tools/repair-scripts"
mkdir -p "$ROOT/tools/repair-scripts"

shopt -s nullglob
repair_files=(
  "$HOME"/Downloads/fix_sat_*.command
  "$HOME"/Downloads/deploy_sat_*.command
  "$HOME"/Downloads/repair_sat_*.command
  "$HOME"/Downloads/fix_sat_*.sh
  "$HOME"/Downloads/deploy_sat_*.sh
  "$HOME"/Downloads/repair_sat_*.sh
)
shopt -u nullglob

for source_file in "${repair_files[@]}"; do
  [[ -f "$source_file" ]] || continue
  cp "$source_file" "$ROOT/tools/repair-scripts/"
done

# Keep this snapshot utility inside the repository for future updates.
REPO_SCRIPT="$ROOT/scripts/snapshot-live-to-github.command"
if [[ "$SCRIPT_SOURCE" != "$REPO_SCRIPT" ]]; then
  cp "$SCRIPT_SOURCE" "$REPO_SCRIPT"
fi
chmod +x "$REPO_SCRIPT"

cat > "$ROOT/scripts/restore-website.command" <<'RESTORE_SITE'
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
RESTORE_SITE
chmod +x "$ROOT/scripts/restore-website.command"

cat > "$ROOT/scripts/restore-lambda.command" <<'RESTORE_LAMBDA'
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
RESTORE_LAMBDA
chmod +x "$ROOT/scripts/restore-lambda.command"

cat > "$ROOT/README.md" <<EOF
# SAT Denduluru Portal

Private source-control and disaster-recovery repository for **$SITE_ORIGIN**.

## What is captured

- \`site/\`: live files from \`s3://$BUCKET\`, excluding \`backups/\`
- \`lambda/$LAMBDA_FUNCTION/source/\`: current Lambda source
- \`lambda/$LAMBDA_FUNCTION/configuration.redacted.json\`: Lambda configuration with environment values removed
- \`infrastructure/\`: S3, CloudFront, Lambda URL, resource-policy, and DynamoDB schema snapshots
- \`tools/repair-scripts/\`: SAT repair/deployment command files copied from \`~/Downloads\`
- \`scripts/\`: snapshot and guarded restore utilities

## Important security rule

Lambda environment-variable **values are deliberately not committed**. This repository contains only environment-variable names and redacted placeholders.

DynamoDB student/progress records are not copied to GitHub.

## Take another snapshot

\`\`\`bash
cd "$ROOT"
./scripts/snapshot-live-to-github.command
\`\`\`

Run this after each successful production change.

## Restore an earlier version

First inspect history:

\`\`\`bash
cd "$ROOT"
git log --oneline
\`\`\`

Check out the commit to restore:

\`\`\`bash
git checkout <commit-id>
\`\`\`

Restore the static website:

\`\`\`bash
./scripts/restore-website.command
\`\`\`

Restore Lambda code:

\`\`\`bash
./scripts/restore-lambda.command
\`\`\`

Return to the latest version afterward:

\`\`\`bash
git switch main
git pull
\`\`\`

## Snapshot metadata

Initial or latest snapshot generated: **$STAMP**
AWS account: \`$EXPECTED_ACCOUNT\`
Region: \`$REGION\`
CloudFront distribution: \`$DISTRIBUTION_ID\`
EOF

echo "7. Excluding files that exceed GitHub's individual-file limit..."
LARGE_LIST="$ROOT/docs/excluded-large-files.txt"
: > "$LARGE_LIST"

while IFS= read -r -d '' large_file; do
  relative="${large_file#"$ROOT/"}"
  size="$(stat -f '%z' "$large_file" 2>/dev/null || stat -c '%s' "$large_file")"
  printf '%s\t%s bytes\n' "$relative" "$size" >> "$LARGE_LIST"
  rm -f "$large_file"
done < <(find "$ROOT/site" "$ROOT/lambda" -type f -size +95M -print0)

if [[ -s "$LARGE_LIST" ]]; then
  echo "   WARNING: files above 95 MiB were listed and excluded:"
  sed 's/^/     /' "$LARGE_LIST"
else
  echo "No files exceeded 95 MiB." > "$LARGE_LIST"
  echo "   PASS: no oversized GitHub files were found."
fi

echo "8. Scanning the snapshot for obvious secrets..."
python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
patterns = {
    "AWS access key": re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "GitHub token": re.compile(
        rb"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b"
    ),
    "Private key": re.compile(
        rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
    ),
    "Unredacted ADMIN_PASSWORD JSON": re.compile(
        rb'"ADMIN_PASSWORD"\s*:\s*"(?!<redacted>)[^"]+"'
    ),
    "Assigned ADMIN_PASSWORD": re.compile(
        rb"\bADMIN_PASSWORD\s*=\s*['\"][^'\"]+['\"]"
    ),
}

skip_suffixes = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico",
    ".mp3", ".mp4", ".mov", ".pdf", ".woff", ".woff2",
}

findings = []
for path in root.rglob("*"):
    if not path.is_file() or ".git" in path.parts:
        continue
    if path.suffix.lower() in skip_suffixes:
        continue
    try:
        data = path.read_bytes()
    except OSError:
        continue
    if b"\x00" in data[:4096]:
        continue
    for label, pattern in patterns.items():
        if pattern.search(data):
            findings.append((label, path.relative_to(root)))

if findings:
    print("Potential secrets were detected:", file=sys.stderr)
    for label, path in findings:
        print(f"  - {label}: {path}", file=sys.stderr)
    print(
        "\nNothing was committed or pushed. Review these files first.",
        file=sys.stderr,
    )
    raise SystemExit(1)

print("   PASS: no obvious credentials or private keys were detected.")
PY

echo "9. Creating the Git commit..."
git config user.name >/dev/null 2>&1 || \
  git config user.name "$GH_LOGIN"
git config user.email >/dev/null 2>&1 || \
  git config user.email "${GH_LOGIN}@users.noreply.github.com"

git add -A

if git diff --cached --quiet; then
  echo "   No source changes were detected; no new commit is needed."
else
  git commit -m "Snapshot live SAT site ${STAMP}"
fi

echo "10. Creating or updating the private GitHub repository..."
if gh repo view "$REMOTE_REPO" >/dev/null 2>&1; then
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "https://github.com/${REMOTE_REPO}.git"
  fi
  git branch -M main
  git push -u origin main
else
  gh repo create "$REMOTE_REPO" \
    --private \
    --description "Private source and disaster-recovery repository for sat.denduluru.com" \
    --source "$ROOT" \
    --remote origin \
    --push
fi

IS_PRIVATE="$(gh repo view "$REMOTE_REPO" --json isPrivate --jq .isPrivate)"
REPO_URL="$(gh repo view "$REMOTE_REPO" --json url --jq .url)"

if [[ "$IS_PRIVATE" != "true" ]]; then
  fail "Repository exists but is not private: $REPO_URL"
fi

echo
echo "========================================================================"
echo " PRIVATE GITHUB REPOSITORY CREATED"
echo "========================================================================"
echo "Repository:   $REPO_URL"
echo "Local folder: $ROOT"
echo
echo "Future snapshot:"
echo "  cd \"$ROOT\""
echo "  ./scripts/snapshot-live-to-github.command"
echo
echo "Before running any future production repair:"
echo "  1. Run a snapshot."
echo "  2. Confirm the commit appears in GitHub."
echo "  3. Then run the repair."
