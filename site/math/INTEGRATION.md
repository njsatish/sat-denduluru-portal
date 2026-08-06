# SAT Progress Tracker — Setup & Integration

Static S3 site  →  fetch()  →  Lambda Function URL  →  DynamoDB. No API Gateway,
no server, stays inside AWS always-free allowances at this scale.

## 1. Create the table (on-demand billing)

```bash
aws dynamodb create-table \
  --table-name sat-progress \
  --attribute-definitions \
      AttributeName=userId,AttributeType=S \
      AttributeName=questionId,AttributeType=S \
  --key-schema \
      AttributeName=userId,KeyType=HASH \
      AttributeName=questionId,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

`PAY_PER_REQUEST` = on-demand: no capacity to manage, pennies at your volume.
(If you'd rather sit fully inside the free tier, use `--billing-mode PROVISIONED
--provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5` instead — the
25/25 always-free provisioned allowance covers it. The cost difference is cents.)

## 2. IAM role for the Lambda

Attach `AWSLambdaBasicExecutionRole` (for CloudWatch logs) plus an inline policy
granting only what the handler uses, scoped to the table ARN:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["dynamodb:UpdateItem", "dynamodb:Query"],
    "Resource": "arn:aws:dynamodb:us-east-1:<ACCOUNT_ID>:table/sat-progress"
  }]
}
```

## 3. Create the Lambda

- Runtime: Node.js 22 (or 20)
- Paste `handler.mjs`
- Environment variable: `TABLE_NAME = sat-progress`
- Handler entry point: `handler.handler`

## 4. Enable the Function URL

- Auth type: `NONE` (fine for a family study tool — the data isn't sensitive)
- CORS: allow origin `https://josh-satmath-prep.s3.us-east-1.amazonaws.com`,
  method `POST`, header `Content-Type`

You'll get a URL like `https://abc123.lambda-url.us-east-1.on.aws/`.

## 5. Wire it into app.js

Add this near the top of `app.js`:

```js
const PROGRESS_API = "https://<your-id>.lambda-url.us-east-1.on.aws/";

// One student: hardcode. Two: prompt once and remember.
const USER =
  localStorage.getItem("sat_user") ||
  (localStorage.setItem("sat_user", prompt("Name?") || "josh"),
   localStorage.getItem("sat_user"));

// Fire-and-forget: a failed save must never interrupt practice.
function recordAttempt(questionId, correct, choice, category) {
  fetch(PROGRESS_API, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      action: "record",
      userId: USER,
      questionId,
      correct,
      choice,
      category,
    }),
  }).catch((e) => console.warn("progress save failed", e));
}

async function loadProgress() {
  const r = await fetch(PROGRESS_API, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "progress", userId: USER }),
  });
  return r.json(); // { items: [...], summary: {...} }
}
```

Then, wherever your existing answer-checking code decides right vs. wrong, add:

```js
// correct  -> boolean you already compute
// choice   -> what the student selected/entered
// category -> "algebra" | "advanced" | "data-geo-trig" (from the volume/page)
recordAttempt(currentQuestion.id, correct, choice, category);
```

Call `loadProgress()` on page load to render a dashboard (mastered per category,
overall accuracy) or to grey out already-mastered questions.

## Notes

- **"Mastered" vs "last correct":** the summary counts a question as mastered once
  it's ever been answered correctly (`correctCount > 0`). Each item also stores
  `lastResult`, so the frontend can show most-recent status instead if you prefer.
- **Security:** Function URL auth `NONE` means anyone with the URL can post. Low
  risk for SAT progress, but if you want a gate, send a shared secret header from
  app.js and check it in the handler. Also tighten the CORS Allow-Origin off `*`.
- **Cost:** at one or two students this stays in the always-free tier — DynamoDB
  storage (kilobytes vs. 25 GB free), Lambda (thousands vs. 1M free requests/mo),
  and CloudWatch logs (kilobytes vs. 5 GB free). Effectively $0/month.
