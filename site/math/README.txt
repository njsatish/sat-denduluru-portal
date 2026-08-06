SAT Math 600 — Set 2 deployment package

CONTENTS
- index.html
  Replaces the current home page with a Set 1 / Set 2 selector.
- set-1.html
  New home page for the existing 300-question set.
- set-2.html
  New home page for the new 300-question set.
- set-2-volume-1-algebra.html
  100 new Algebra and Linear Relationships questions.
- set-2-volume-2-advanced-math.html
  100 new Advanced Math questions.
- set-2-volume-3-data-geometry-trigonometry.html
  100 new Data, Geometry, and Trigonometry questions.
- set-2-question-bank.json
  Source copy of all 300 new questions.
- app.js
  Updated progress code supporting both sets and the 600-question selector.
- validation-report.txt
  Automated counts and structural validation.

DIFFICULTY DISTRIBUTION
Each new volume:
- Medium: 40
- Hard: 40
- Challenge: 20
- Foundation: 0

QUESTION IDS
Set 1 remains unchanged:
- v1q001 through v1q100
- v2q001 through v2q100
- v3q001 through v3q100

Set 2 uses independent IDs:
- s2v1q001 through s2v1q100
- s2v2q001 through s2v2q100
- s2v3q001 through s2v3q100

Because the IDs are different, DynamoDB progress from Set 1 and Set 2 cannot overwrite each other.

AWS CHANGES
No Lambda, DynamoDB table, IAM, or admin-page change is required.
The existing progress, student validation, wrong-answer locking, and admin unlock workflow continue to work.

UPLOAD
Upload these files to the root of the existing S3 bucket:
- index.html
- set-1.html
- set-2.html
- set-2-volume-1-algebra.html
- set-2-volume-2-advanced-math.html
- set-2-volume-3-data-geometry-trigonometry.html
- set-2-question-bank.json
- app.js

Overwrite the existing index.html and app.js.
Keep the existing styles.css and the three original Set 1 volume files.

CONTENT TYPES
- .html: text/html
- .js: application/javascript
- .json: application/json

TEST
Use an administrator-created student link:
https://josh-satmath-prep.s3.us-east-1.amazonaws.com/index.html?student=josh

Confirm:
1. The home page displays Set 1 and Set 2.
2. Set 1 still shows existing progress.
3. Set 2 begins at 0/300 for a student who has not attempted it.
4. Answering a Set 2 question creates a DynamoDB item with a questionId beginning s2v.
5. Another browser loads the same Set 2 progress.
6. A wrong answer locks and appears in the existing admin correction workflow.

CACHE
The new pages load app.js?v=7. S3 Bucket Versioning is not required; the query string is only browser cache busting.
