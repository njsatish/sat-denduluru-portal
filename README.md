# SAT Denduluru Portal

Private source-control and disaster-recovery repository for **https://sat.denduluru.com**.

## What is captured

- `site/`: live files from `s3://sat-prep-josh`, excluding `backups/`
- `lambda/sat-progress-handler/source/`: current Lambda source
- `lambda/sat-progress-handler/configuration.redacted.json`: Lambda configuration with environment values removed
- `infrastructure/`: S3, CloudFront, Lambda URL, resource-policy, and DynamoDB schema snapshots
- `tools/repair-scripts/`: SAT repair/deployment command files copied from `~/Downloads`
- `scripts/`: snapshot and guarded restore utilities

## Important security rule

Lambda environment-variable **values are deliberately not committed**. This repository contains only environment-variable names and redacted placeholders.

DynamoDB student/progress records are not copied to GitHub.

## Take another snapshot

```bash
cd "/Users/njsatish2icloud.com/Documents/sat-denduluru-portal"
./scripts/snapshot-live-to-github.command
```

Run this after each successful production change.

## Restore an earlier version

First inspect history:

```bash
cd "/Users/njsatish2icloud.com/Documents/sat-denduluru-portal"
git log --oneline
```

Check out the commit to restore:

```bash
git checkout <commit-id>
```

Restore the static website:

```bash
./scripts/restore-website.command
```

Restore Lambda code:

```bash
./scripts/restore-lambda.command
```

Return to the latest version afterward:

```bash
git switch main
git pull
```

## Snapshot metadata

Initial or latest snapshot generated: **2026-08-06T01:55:03Z**
AWS account: `989174615155`
Region: `us-east-1`
CloudFront distribution: `E2WHKAAIHGKMVF`
