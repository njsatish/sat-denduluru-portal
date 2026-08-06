# Development portal workflow

## Environments

| Environment | Branch | URL | S3 | Lambda | DynamoDB |
|---|---|---|---|---|---|
| Development | `develop` | `https://dev-sat.denduluru.com` | `sat-prep-josh-dev` | `sat-progress-handler-dev` | `sat-progress-dev` |
| Production | `main` | `https://sat.denduluru.com` | `sat-prep-josh` | `sat-progress-handler` | `sat-progress` |

Development currently shares the existing Cognito user pool for authentication,
but progress and application data are isolated in `sat-progress-dev`.

Create a separate Cognito development user pool before testing account-creation,
password-reset, or destructive user-administration features.

## Develop and deploy

```bash
cd "/Users/njsatish2icloud.com/Documents/sat-denduluru-portal"
git switch develop
git pull

git switch -c feature/my-change
# Edit and test files.
git add .
git commit -m "Describe the feature"
git switch develop
git merge --no-ff feature/my-change
git push origin develop

./scripts/deploy-dev.command
```

## Test before promotion

At minimum:

1. Sign in to `https://dev-sat.denduluru.com`.
2. Answer a new Math question and refresh.
3. Answer a new English question and refresh.
4. Confirm progress appears under the development account.
5. Confirm production progress was not changed.
6. Test logout and sign-in again.

## Promote

```bash
cd "/Users/njsatish2icloud.com/Documents/sat-denduluru-portal"
git switch develop
./scripts/open-production-promotion-pr.command
```

Review and merge the pull request into `main`. Production deployment should use
the exact merged commit after taking a current production snapshot.

## Rollback development

To redeploy an earlier development commit:

```bash
git switch develop
git log --oneline
git switch -c rollback/dev-<date> <known-good-commit>
git switch develop
git merge --no-ff rollback/dev-<date>
git push origin develop
./scripts/deploy-dev.command
```
