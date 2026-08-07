#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ "$(git branch --show-current)" == "develop" ]] || {
  echo "Run this command from the develop branch." >&2
  exit 1
}

[[ -z "$(git status --porcelain)" ]] || {
  echo "Commit your changes first." >&2
  exit 1
}

git push origin develop

EXISTING_PR="$(
  gh pr list \
    --base main \
    --head develop \
    --state open \
    --json url \
    --jq '.[0].url // empty'
)"

if [[ -n "$EXISTING_PR" ]]; then
  echo "An open production promotion PR already exists:"
  echo "$EXISTING_PR"
  exit 0
fi

gh pr create \
  --base main \
  --head develop \
  --title "Promote tested development release to production" \
  --body "$(cat <<'BODY'
## Promotion checklist

- [ ] Tested student sign-in on dev-sat.denduluru.com
- [ ] Tested Math question save and refresh
- [ ] Tested English question save and refresh
- [ ] Tested progress/dashboard behavior
- [ ] Confirmed no test data was written to production
- [ ] Reviewed the Git diff
- [ ] Took a current production snapshot
BODY
)"
