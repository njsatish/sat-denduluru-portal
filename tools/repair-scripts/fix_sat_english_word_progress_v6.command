#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

PROFILE = "denduluru"
EXPECTED_ACCOUNT = "989174615155"
REGION = "us-east-1"
BUCKET = "sat-prep-josh"
TABLE_NAME = "sat-progress"
SITE_ALIAS = "sat.denduluru.com"
ENGLISH_PAGE_KEY = "english/SAT_Words_326_350.html"
ENGLISH_ROW_KEY = "__english_words__"
TEST_USER = f"engv6{int(time.time())}{os.getpid()}"
STAMP = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
BUILD = f"20260803-english-progress-v6-{STAMP}"
BACKUP_PREFIX = f"backups/english-progress-v6-{STAMP}"

AWS_BASE = ["aws", "--profile", PROFILE, "--region", REGION]


class RepairError(RuntimeError):
    pass


def run(args, *, capture=False, check=True, cwd=None):
    result = subprocess.run(
        [str(value) for value in args],
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        details = result.stderr.strip() if capture else ""
        raise RepairError(
            f"Command failed ({result.returncode}): {' '.join(map(str, args))}"
            + (f"\n{details}" if details else "")
        )
    return result.stdout.strip() if capture else ""


def aws(*args, capture=False, check=True):
    return run(AWS_BASE + list(args), capture=capture, check=check)


def require_commands():
    missing = [name for name in ("aws", "node", "python3") if not shutil.which(name)]
    if missing:
        raise RepairError("Missing required command(s): " + ", ".join(missing))


def http_post(url, payload):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8")
            status = response.status
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RepairError(f"API returned HTTP {error.code}: {body}") from error
    except OSError as error:
        raise RepairError(f"Could not reach progress API: {error}") from error

    if not 200 <= status < 300:
        raise RepairError(f"API returned HTTP {status}: {body}")
    try:
        return json.loads(body or "{}")
    except json.JSONDecodeError as error:
        raise RepairError(f"API returned invalid JSON: {body}") from error


def read_s3_text(key):
    return aws(
        "s3", "cp", f"s3://{BUCKET}/{key}", "-", "--only-show-errors",
        capture=True,
    )


def download_s3(key, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    aws(
        "s3", "cp", f"s3://{BUCKET}/{key}", str(destination),
        "--only-show-errors",
    )


def upload_s3(source, key, *, content_type=None):
    args = [
        "s3", "cp", str(source), f"s3://{BUCKET}/{key}",
        "--cache-control", "no-cache, no-store, must-revalidate",
        "--only-show-errors",
    ]
    if content_type:
        args.extend(["--content-type", content_type])
    aws(*args)


def extract_progress_api(text):
    match = re.search(
        r"const\s+PROGRESS_API\s*=\s*['\"]([^'\"]+)['\"]",
        text,
    )
    if not match:
        match = re.search(
            r"https://[A-Za-z0-9-]+\.lambda-url\.[A-Za-z0-9-]+\.on\.aws/?",
            text,
        )
    if not match:
        raise RepairError("Progress API URL was not found in the English page/scripts.")
    url = match.group(1) if match.lastindex else match.group(0)
    return url if url.endswith("/") else url + "/"


def local_script_keys(page_key, html):
    keys = []
    for src in re.findall(
        r"<script\b[^>]*\bsrc\s*=\s*['\"]([^'\"]+)['\"]",
        html,
        flags=re.IGNORECASE,
    ):
        parsed = urllib.parse.urlparse(src)
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        if parsed.path.startswith("/"):
            key = parsed.path.lstrip("/")
        else:
            key = str(PurePosixPath(page_key).parent / parsed.path)
        key = str(PurePosixPath(key))
        if key not in keys:
            keys.append(key)
    return keys


def find_lambda_for_url(progress_api):
    names = aws(
        "lambda", "list-functions",
        "--query", "Functions[].FunctionName",
        "--output", "text",
        capture=True,
    ).split()
    for name in names:
        found = aws(
            "lambda", "get-function-url-config",
            "--function-name", name,
            "--query", "FunctionUrl",
            "--output", "text",
            capture=True,
            check=False,
        )
        if found == progress_api:
            return name
    raise RepairError(f"No Lambda Function URL matches {progress_api}")


def find_handler_file(root, handler_setting):
    module = handler_setting.rsplit(".", 1)[0]
    for extension in ("mjs", "js", "cjs"):
        candidate = root / f"{module}.{extension}"
        if candidate.exists():
            return candidate
    candidates = [
        path for pattern in ("*.mjs", "*.js", "*.cjs")
        for path in root.rglob(pattern)
        if "node_modules" not in path.parts
    ]
    if not candidates:
        raise RepairError("Lambda handler source file was not found.")
    return sorted(candidates, key=lambda path: (len(path.parts), str(path)))[0]


def patch_imports(source):
    match = re.search(
        r"import\s*\{(?P<body>[\s\S]*?)\}\s*from\s*"
        r"['\"]@aws-sdk/lib-dynamodb['\"]\s*;?",
        source,
    )
    if not match:
        raise RepairError("@aws-sdk/lib-dynamodb import was not found.")
    names = [value.strip() for value in match.group("body").split(",") if value.strip()]
    for required in ("GetCommand", "UpdateCommand"):
        if required not in names:
            names.append(required)
    replacement = (
        "import {\n  " + ",\n  ".join(dict.fromkeys(names))
        + "\n} from '@aws-sdk/lib-dynamodb';"
    )
    return source[:match.start()] + replacement + source[match.end():]


def rename_original_handler(source):
    patterns = [
        (
            r"export\s+const\s+handler\s*=",
            "const satEnglishOriginalHandler =",
        ),
        (
            r"export\s+let\s+handler\s*=",
            "let satEnglishOriginalHandler =",
        ),
        (
            r"export\s+async\s+function\s+handler\s*\(",
            "async function satEnglishOriginalHandler(",
        ),
        (
            r"export\s+function\s+handler\s*\(",
            "function satEnglishOriginalHandler(",
        ),
    ]
    for pattern, replacement in patterns:
        updated, count = re.subn(pattern, replacement, source, count=1)
        if count == 1:
            return updated

    # Less common ESM form: const handler = ...; export { handler };
    if re.search(r"\bconst\s+handler\s*=", source) and re.search(
        r"export\s*\{\s*handler\s*\}\s*;?", source
    ):
        source = re.sub(
            r"\bconst\s+handler\s*=",
            "const satEnglishOriginalHandler =",
            source,
            count=1,
        )
        source = re.sub(
            r"export\s*\{\s*handler\s*\}\s*;?",
            "",
            source,
            count=1,
        )
        return source

    raise RepairError(
        "The exported Lambda handler declaration was not recognized. Nothing was changed."
    )


LAMBDA_MARKER_START = "// BEGIN SAT_ENGLISH_PROGRESS_V6"
LAMBDA_MARKER_END = "// END SAT_ENGLISH_PROGRESS_V6"

LAMBDA_WRAPPER = r'''
// BEGIN SAT_ENGLISH_PROGRESS_V6
const SAT_ENGLISH_PROGRESS_ROW = '__english_words__';
const SAT_ENGLISH_TOTAL_WORDS = 375;

function satEnglishNormalizeStudent(value) {
  const id = String(value || '').trim().toLowerCase();
  return /^[a-z0-9_-]{1,80}$/.test(id) ? id : '';
}

function satEnglishNormalizeLearned(values) {
  return [...new Set((Array.isArray(values) ? values : [])
    .map(Number)
    .filter(number =>
      Number.isInteger(number) &&
      number >= 1 &&
      number <= SAT_ENGLISH_TOTAL_WORDS
    ))].sort((left, right) => left - right);
}

function satEnglishParseBody(event) {
  if (!event || typeof event !== 'object') return {};
  if (!Object.prototype.hasOwnProperty.call(event, 'body')) return event;
  let raw = event.body;
  if (event.isBase64Encoded && typeof raw === 'string') {
    raw = Buffer.from(raw, 'base64').toString('utf8');
  }
  if (raw && typeof raw === 'object') return raw;
  if (typeof raw !== 'string' || !raw.trim()) return {};
  try {
    return JSON.parse(raw);
  } catch (_) {
    return {};
  }
}

function satEnglishResponse(statusCode, payload) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'content-type,authorization',
      'Access-Control-Allow-Methods': 'POST,OPTIONS',
      'Cache-Control': 'no-store'
    },
    body: JSON.stringify(payload)
  };
}

function satEnglishRequestLearned(body) {
  return satEnglishNormalizeLearned(
    body.learned ??
    body.learnedWords ??
    body.words ??
    body.progress?.learned ??
    []
  );
}

async function satEnglishSaveProgress(body) {
  const userId = satEnglishNormalizeStudent(
    body.userId || body.studentId || body.student
  );
  if (!userId) {
    return satEnglishResponse(400, {
      error: 'STUDENT_REQUIRED',
      message: 'A valid student ID is required.'
    });
  }

  const learned = satEnglishRequestLearned(body);
  const updatedAt = new Date().toISOString();

  await ddb.send(new UpdateCommand({
    TableName: TABLE,
    Key: {
      userId,
      questionId: SAT_ENGLISH_PROGRESS_ROW
    },
    UpdateExpression:
      'SET #learned = :learned, #updatedAt = :updatedAt, #category = :category',
    ExpressionAttributeNames: {
      '#learned': 'learned',
      '#updatedAt': 'updatedAt',
      '#category': 'category'
    },
    ExpressionAttributeValues: {
      ':learned': learned,
      ':updatedAt': updatedAt,
      ':category': 'english-vocabulary'
    }
  }));

  return satEnglishResponse(200, {
    ok: true,
    studentId: userId,
    learned,
    updatedAt
  });
}

async function satEnglishReadProgress(body) {
  const userId = satEnglishNormalizeStudent(
    body.userId || body.studentId || body.student
  );
  if (!userId) {
    return satEnglishResponse(400, {
      error: 'STUDENT_REQUIRED',
      message: 'A valid student ID is required.'
    });
  }

  const result = await ddb.send(new GetCommand({
    TableName: TABLE,
    Key: {
      userId,
      questionId: SAT_ENGLISH_PROGRESS_ROW
    },
    ConsistentRead: true
  }));

  return satEnglishResponse(200, {
    ok: true,
    studentId: userId,
    learned: satEnglishNormalizeLearned(result.Item?.learned),
    updatedAt: result.Item?.updatedAt || null
  });
}

export const handler = async (event, context) => {
  if (event?.requestContext?.http?.method === 'OPTIONS') {
    return satEnglishResponse(204, {});
  }

  const body = satEnglishParseBody(event);
  const action = String(body.action || '').trim();

  try {
    if (action === 'saveEnglishProgress') {
      return await satEnglishSaveProgress(body);
    }
    if (action === 'englishProgress') {
      return await satEnglishReadProgress(body);
    }
    return await satEnglishOriginalHandler(event, context);
  } catch (error) {
    console.error('SAT English progress v6 error', error);
    return satEnglishResponse(500, {
      error: 'ENGLISH_PROGRESS_ERROR',
      message: error?.message || 'Unable to save English progress.'
    });
  }
};
// END SAT_ENGLISH_PROGRESS_V6
'''


def patch_lambda_source(source):
    source = patch_imports(source)
    if LAMBDA_MARKER_START in source:
        print("   English v6 Lambda wrapper is already present; leaving source unchanged.")
        return source
    source = rename_original_handler(source)
    return source.rstrip() + "\n\n" + LAMBDA_WRAPPER.strip() + "\n"


def make_zip(source_dir, destination):
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(source_dir.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(source_dir))


def ddb_get_test_row():
    raw = aws(
        "dynamodb", "get-item",
        "--table-name", TABLE_NAME,
        "--key", json.dumps({
            "userId": {"S": TEST_USER},
            "questionId": {"S": ENGLISH_ROW_KEY},
        }),
        "--consistent-read",
        "--output", "json",
        capture=True,
    )
    return json.loads(raw or "{}").get("Item")


def ddb_row_words(item):
    values = (item or {}).get("learned", {}).get("L", [])
    result = []
    for value in values:
        raw = value.get("N") if isinstance(value, dict) else None
        try:
            result.append(int(raw))
        except (TypeError, ValueError):
            pass
    return sorted(set(result))


def cleanup_test_row():
    aws(
        "dynamodb", "delete-item",
        "--table-name", TABLE_NAME,
        "--key", json.dumps({
            "userId": {"S": TEST_USER},
            "questionId": {"S": ENGLISH_ROW_KEY},
        }),
        "--output", "json",
        capture=True,
        check=False,
    )


def validate_api(progress_api):
    print("5. Testing an actual English save...")
    saved = http_post(progress_api, {
        "action": "saveEnglishProgress",
        "userId": TEST_USER,
        "learned": [374, 375],
    })
    if saved.get("learned") != [374, 375]:
        raise RepairError(f"Save response was unexpected: {saved}")

    print("6. Reading the English progress back through the API...")
    readback = http_post(progress_api, {
        "action": "englishProgress",
        "userId": TEST_USER,
    })
    if readback.get("learned") != [374, 375]:
        raise RepairError(f"API readback was unexpected: {readback}")

    print("7. Verifying the DynamoDB row directly...")
    direct = ddb_row_words(ddb_get_test_row())
    if direct != [374, 375]:
        raise RepairError(f"DynamoDB contained {direct}, expected [374, 375].")

    print("8. Testing exact replacement/removal...")
    http_post(progress_api, {
        "action": "saveEnglishProgress",
        "userId": TEST_USER,
        "learned": [375],
    })
    readback = http_post(progress_api, {
        "action": "englishProgress",
        "userId": TEST_USER,
    })
    direct = ddb_row_words(ddb_get_test_row())
    if readback.get("learned") != [375] or direct != [375]:
        raise RepairError(
            f"Replacement failed: API={readback.get('learned')}, DynamoDB={direct}"
        )

    print("9. Confirming existing Math progress still routes normally...")
    math = http_post(progress_api, {"action": "progress", "userId": "josh"})
    if not isinstance(math, dict) or "items" not in math:
        raise RepairError("Existing Math progress action did not return its normal items payload.")

    print("   PASS: English writes, reads, replacements, DynamoDB, and Math routing verified.")


FRONTEND_START = "/* BEGIN SAT ENGLISH CLOUD V6 */"
FRONTEND_END = "/* END SAT ENGLISH CLOUD V6 */"

FRONTEND_BRIDGE = r'''
/* BEGIN SAT ENGLISH CLOUD V6 */
(() => {
  'use strict';

  const API = __API__;
  const TOTAL = 375;
  const previous = window.SATEnglishCloud || {};

  function normalizeStudent(value) {
    const id = String(value || '').trim().toLowerCase();
    return /^[a-z0-9_-]{1,80}$/.test(id) ? id : '';
  }

  function tokenStudent() {
    try {
      const token = sessionStorage.getItem('sat_id_token');
      if (!token) return '';
      const part = token.split('.')[1];
      if (!part) return '';
      const normalized = part.replace(/-/g, '+').replace(/_/g, '/');
      const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
      const claims = JSON.parse(decodeURIComponent(
        atob(padded).split('').map(character =>
          '%' + character.charCodeAt(0).toString(16).padStart(2, '0')
        ).join('')
      ));
      return normalizeStudent(claims['cognito:username'] || claims.username);
    } catch (_) {
      return '';
    }
  }

  const params = new URLSearchParams(location.search);
  const studentId =
    normalizeStudent(params.get('student')) ||
    normalizeStudent(localStorage.getItem('sat_user')) ||
    tokenStudent();

  if (studentId) localStorage.setItem('sat_user', studentId);

  const storageKey = studentId
    ? `satEnglish300Progress:${studentId}`
    : 'sat300-nireekshan-progress-v1';

  function normalizeLearned(values) {
    return [...new Set((Array.isArray(values) ? values : [])
      .map(Number)
      .filter(number => Number.isInteger(number) && number >= 1 && number <= TOTAL)
    )].sort((left, right) => left - right);
  }

  function readLocal() {
    try {
      const value = JSON.parse(localStorage.getItem(storageKey) || '{}');
      return normalizeLearned(value.learned);
    } catch (_) {
      return [];
    }
  }

  function writeLocal(learned) {
    localStorage.setItem(storageKey, JSON.stringify({learned: normalizeLearned(learned)}));
  }

  async function post(action, extra = {}) {
    if (!studentId) throw new Error('Student identity is missing.');
    const response = await fetch(API, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      cache: 'no-store',
      body: JSON.stringify({
        action,
        userId: studentId,
        studentId,
        student: studentId,
        ...extra
      })
    });
    const text = await response.text();
    let payload = {};
    try { payload = text ? JSON.parse(text) : {}; } catch (_) { payload = {raw: text}; }
    if (!response.ok) throw new Error(`English progress API ${response.status}: ${text}`);
    return payload;
  }

  let timer = null;
  let pending = null;
  let saveChain = Promise.resolve();
  let lastError = null;

  async function saveNow(values) {
    const learned = normalizeLearned(values);
    const response = await post('saveEnglishProgress', {learned});
    const confirmed = normalizeLearned(response.learned);
    if (confirmed.length !== learned.length || confirmed.some((n, i) => n !== learned[i])) {
      throw new Error('The server did not confirm the saved learned-word list.');
    }
    lastError = null;
    window.dispatchEvent(new CustomEvent('sat-english-progress-synced', {
      detail: {studentId, learned}
    }));
    return learned;
  }

  function queueLearnedSync(values) {
    pending = normalizeLearned(values);
    clearTimeout(timer);
    timer = setTimeout(() => {
      const learned = pending;
      pending = null;
      saveChain = saveChain.catch(() => {}).then(() => saveNow(learned)).catch(error => {
        lastError = error;
        console.error('SAT English progress did not save.', error);
        window.dispatchEvent(new CustomEvent('sat-english-progress-sync-error', {
          detail: {studentId, error: String(error)}
        }));
      });
    }, 120);
    return saveChain;
  }

  const ready = Promise.resolve(previous.ready).catch(() => {}).then(async () => {
    if (!studentId) return;
    const local = readLocal();
    const remotePayload = await post('englishProgress');
    const remote = normalizeLearned(remotePayload.learned);
    const merged = normalizeLearned([...remote, ...local]);
    writeLocal(merged);
    if (merged.length !== remote.length || merged.some((n, i) => n !== remote[i])) {
      await saveNow(merged);
    }
  }).catch(error => {
    lastError = error;
    console.error('SAT English cloud initialization failed.', error);
  });

  window.SATEnglishCloud = {
    ...previous,
    studentId,
    storageKey,
    ready,
    queueLearnedSync,
    flush() {
      clearTimeout(timer);
      if (pending) {
        const learned = pending;
        pending = null;
        saveChain = saveChain.catch(() => {}).then(() => saveNow(learned));
      }
      return saveChain;
    },
    getLastSyncError: () => lastError
  };
})();
/* END SAT ENGLISH CLOUD V6 */
'''


def cloudfront_distribution():
    distribution = aws(
        "cloudfront", "list-distributions",
        "--query",
        f"DistributionList.Items[?Aliases.Quantity > `0` && contains(Aliases.Items, '{SITE_ALIAS}')].Id | [0]",
        "--output", "text",
        capture=True,
    )
    if not distribution or distribution == "None":
        raise RepairError(f"CloudFront distribution for {SITE_ALIAS} was not found.")
    return distribution


def deploy_frontend(progress_api, root):
    print("10. Installing the browser cloud-save bridge...")
    live_js = root / "english-progress.js"
    patched_js = root / "english-progress.patched.js"
    html_root = root / "english-html"
    html_root.mkdir(parents=True, exist_ok=True)

    download_s3("english/english-progress.js", live_js)
    source = live_js.read_text(encoding="utf-8")
    if FRONTEND_START in source and FRONTEND_END in source:
        source = re.sub(
            re.escape(FRONTEND_START) + r"[\s\S]*?" + re.escape(FRONTEND_END),
            "",
            source,
            count=1,
        ).rstrip() + "\n"
    bridge = FRONTEND_BRIDGE.replace("__API__", json.dumps(progress_api))
    patched_js.write_text(source.rstrip() + "\n\n" + bridge.strip() + "\n", encoding="utf-8")
    run(["node", "--check", str(patched_js)])

    aws(
        "s3", "sync", f"s3://{BUCKET}/english", str(html_root),
        "--exclude", "*", "--include", "*.html", "--only-show-errors",
    )

    pattern = re.compile(
        r'(?P<prefix><script\b[^>]*\bsrc=["\'](?:\./)?english-progress\.js)'
        r'(?:\?[^"\']*)?'
        r'(?P<suffix>["\'][^>]*></script>)',
        re.IGNORECASE,
    )
    changed = []
    for path in sorted(html_root.rglob("*.html")):
        original = path.read_text(encoding="utf-8")
        updated, count = pattern.subn(
            lambda match: match.group("prefix") + f"?v={BUILD}" + match.group("suffix"),
            original,
        )
        if count:
            path.write_text(updated, encoding="utf-8")
            changed.append(path)
    if not changed:
        raise RepairError("No English HTML pages referenced english-progress.js.")

    aws(
        "s3", "cp",
        f"s3://{BUCKET}/english/english-progress.js",
        f"s3://{BUCKET}/{BACKUP_PREFIX}/frontend/english/english-progress.js",
        "--only-show-errors",
    )
    upload_s3(patched_js, "english/english-progress.js", content_type="application/javascript; charset=utf-8")

    for path in changed:
        relative = path.relative_to(html_root).as_posix()
        live_key = f"english/{relative}"
        backup_key = f"{BACKUP_PREFIX}/frontend/{live_key}"
        aws(
            "s3", "cp", f"s3://{BUCKET}/{live_key}", f"s3://{BUCKET}/{backup_key}",
            "--only-show-errors",
        )
        upload_s3(path, live_key, content_type="text/html; charset=utf-8")

    distribution = cloudfront_distribution()
    invalidation = aws(
        "cloudfront", "create-invalidation",
        "--distribution-id", distribution,
        "--paths", "/english/english-progress.js*", "/english/*",
        "--query", "Invalidation.Id",
        "--output", "text",
        capture=True,
    )
    aws(
        "cloudfront", "wait", "invalidation-completed",
        "--distribution-id", distribution,
        "--id", invalidation,
    )

    deployed_js = read_s3_text("english/english-progress.js")
    if FRONTEND_START not in deployed_js:
        raise RepairError("Deployed English JavaScript does not contain the v6 bridge.")
    test_html = read_s3_text(ENGLISH_PAGE_KEY)
    if f"english-progress.js?v={BUILD}" not in test_html:
        raise RepairError("The test vocabulary page does not reference the new script version.")

    print(f"   PASS: browser bridge installed on {len(changed)} English page(s).")


def print_logs(function_name):
    output = aws(
        "logs", "tail", f"/aws/lambda/{function_name}",
        "--since", "10m", "--format", "short",
        capture=True,
        check=False,
    )
    if output:
        print("\nRecent Lambda diagnostic log lines:")
        for line in output.splitlines()[-30:]:
            print("   " + line)


def main():
    require_commands()
    account = aws(
        "sts", "get-caller-identity", "--query", "Account", "--output", "text",
        capture=True,
    )
    if account != EXPECTED_ACCOUNT:
        raise RepairError(f"Expected AWS account {EXPECTED_ACCOUNT}, but found {account}.")

    print("=" * 70)
    print(" SAT English learned-word progress repair v6")
    print("=" * 70)
    print(f"AWS account: {account}")
    print(f"Backup:      s3://{BUCKET}/{BACKUP_PREFIX}/")
    print()

    with tempfile.TemporaryDirectory(prefix="sat-english-v6-") as temp_name:
        root = Path(temp_name)

        print("1. Reading the live English page and scripts...")
        html = read_s3_text(ENGLISH_PAGE_KEY)
        scripts = []
        for key in local_script_keys(ENGLISH_PAGE_KEY, html):
            try:
                scripts.append(read_s3_text(key))
            except RepairError:
                pass
        progress_api = extract_progress_api("\n".join([html] + scripts))
        print(f"   Progress API: {progress_api}")

        print("2. Locating and backing up the live Lambda...")
        function_name = find_lambda_for_url(progress_api)
        config = json.loads(aws(
            "lambda", "get-function-configuration",
            "--function-name", function_name,
            "--output", "json",
            capture=True,
        ))
        handler_setting = config["Handler"]
        code_url = aws(
            "lambda", "get-function",
            "--function-name", function_name,
            "--query", "Code.Location",
            "--output", "text",
            capture=True,
        )
        current_zip = root / "lambda-before.zip"
        urllib.request.urlretrieve(code_url, current_zip)
        aws(
            "s3", "cp", str(current_zip),
            f"s3://{BUCKET}/{BACKUP_PREFIX}/lambda-before.zip",
            "--only-show-errors",
        )

        source_dir = root / "lambda-source"
        source_dir.mkdir()
        with zipfile.ZipFile(current_zip) as archive:
            archive.extractall(source_dir)
        handler_path = find_handler_file(source_dir, handler_setting)

        print("3. Adding isolated English save/read handling...")
        original = handler_path.read_text(encoding="utf-8")
        patched = patch_lambda_source(original)
        handler_path.write_text(patched, encoding="utf-8")
        run(["node", "--check", str(handler_path)])
        patched_zip = root / "lambda-v6.zip"
        make_zip(source_dir, patched_zip)

        print("4. Deploying the patched Lambda...")
        deployed = False
        verified = False
        try:
            aws(
                "lambda", "update-function-code",
                "--function-name", function_name,
                "--zip-file", f"fileb://{patched_zip}",
                "--output", "json",
                capture=True,
            )
            deployed = True
            aws("lambda", "wait", "function-updated", "--function-name", function_name)
            validate_api(progress_api)
            verified = True
        except Exception:
            print_logs(function_name)
            if deployed and not verified:
                print("\nA live verification failed. Restoring the previous Lambda...")
                aws(
                    "lambda", "update-function-code",
                    "--function-name", function_name,
                    "--zip-file", f"fileb://{current_zip}",
                    "--output", "json",
                    capture=True,
                    check=False,
                )
                aws(
                    "lambda", "wait", "function-updated",
                    "--function-name", function_name,
                    check=False,
                )
            raise
        finally:
            cleanup_test_row()

        deploy_frontend(progress_api, root)

    print()
    print("=" * 70)
    print(" SAT ENGLISH WORD PROGRESS REPAIR V6 PASSED")
    print("=" * 70)
    print("Verified:")
    print("  - saveEnglishProgress stores an exact learned-word list.")
    print("  - englishProgress reads it back consistently.")
    print("  - The DynamoDB row was verified directly.")
    print("  - Removing a learned word persists.")
    print("  - Existing Math progress still routes through the original handler.")
    print("  - English pages use the new browser bridge and cache version.")
    print()
    print("Close every SAT tab, reopen the student link, mark one word learned,")
    print("wait one second, and refresh the page.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit("Cancelled.")
    except Exception as error:
        print(f"\nERROR: {error}")
        raise SystemExit(1)
