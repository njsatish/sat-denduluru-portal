#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
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
ENGLISH_PAGE_KEY = "english/SAT_Words_326_350.html"
ENGLISH_TEST_STUDENT = "tim"
ENGLISH_WRITE_USER = f"engwrite{int(time.time())}{os.getpid()}"

STAMP = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
BUILD = f"20260803-english-write-repair-v5-{STAMP}"
EMERGENCY_PREFIX = f"backups/english-write-repair-{STAMP}"
TEST_USER = f"retryrepair{int(time.time())}{os.getpid()}"

AWS_BASE = [
    "aws",
    "--profile", PROFILE,
    "--region", REGION,
]


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
            f"Command failed ({result.returncode}): "
            + " ".join(map(str, args))
            + (f"\n{details}" if details else "")
        )

    return result.stdout.strip() if capture else ""


def aws(*args, capture=False, check=True):
    return run(
        AWS_BASE + list(args),
        capture=capture,
        check=check,
    )


def require_commands():
    missing = [
        command
        for command in ("aws", "python3", "node")
        if shutil.which(command) is None
    ]

    if missing:
        raise RepairError(
            "Missing required command(s): " + ", ".join(missing)
        )


def read_s3_text(key):
    return aws(
        "s3", "cp",
        f"s3://{BUCKET}/{key}",
        "-",
        "--only-show-errors",
        capture=True,
    )


def download_s3(key, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    aws(
        "s3", "cp",
        f"s3://{BUCKET}/{key}",
        str(destination),
        "--only-show-errors",
    )


def upload_s3(source, key):
    aws(
        "s3", "cp",
        str(source),
        f"s3://{BUCKET}/{key}",
        "--only-show-errors",
    )


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
        raise RepairError(
            f"API returned HTTP {error.code}: {body}"
        ) from error
    except OSError as error:
        raise RepairError(
            f"Could not reach the progress API: {error}"
        ) from error

    if not 200 <= status < 300:
        raise RepairError(
            f"API returned HTTP {status}: {body}"
        )

    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise RepairError(
            f"API returned invalid JSON: {body}"
        ) from error


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
        raise RepairError(
            "The Lambda Function URL was not found in the English page scripts."
        )

    url = match.group(1) if match.lastindex else match.group(0)
    return url if url.endswith("/") else url + "/"


def find_lambda_for_url(progress_api):
    output = aws(
        "lambda", "list-functions",
        "--query", "Functions[].FunctionName",
        "--output", "text",
        capture=True,
    )

    function_names = [
        value
        for value in re.split(r"\s+", output)
        if value
    ]

    for function_name in function_names:
        function_url = aws(
            "lambda", "get-function-url-config",
            "--function-name", function_name,
            "--query", "FunctionUrl",
            "--output", "text",
            capture=True,
            check=False,
        )

        if function_url == progress_api:
            return function_name

    raise RepairError(
        f"No Lambda Function URL matches {progress_api}"
    )


def list_pre_retry_backups():
    raw = aws(
        "s3api", "list-objects-v2",
        "--bucket", BUCKET,
        "--prefix", "backups/retry-v4-",
        "--output", "json",
        capture=True,
    )

    objects = json.loads(raw or "{}").get("Contents", [])

    candidates = [
        value
        for value in objects
        if value.get("Key", "").endswith("/lambda-before.zip")
    ]

    candidates.sort(
        key=lambda value: value.get("LastModified", ""),
        reverse=True,
    )

    return candidates


def find_handler_file(extracted_dir, handler_setting):
    module = handler_setting.rsplit(".", 1)[0]

    for extension in ("mjs", "js", "cjs"):
        candidate = extracted_dir / f"{module}.{extension}"
        if candidate.exists():
            return candidate

    candidates = []

    for pattern in ("*.mjs", "*.js", "*.cjs"):
        candidates.extend(extracted_dir.rglob(pattern))

    candidates = [
        path
        for path in candidates
        if "node_modules" not in path.parts
    ]

    if not candidates:
        raise RepairError(
            "The Lambda handler source was not found in the backup ZIP."
        )

    return sorted(
        candidates,
        key=lambda path: (len(path.parts), str(path)),
    )[0]


def choose_clean_pre_retry_backup(root, handler_setting, required_actions):
    candidates = list_pre_retry_backups()

    if not candidates:
        raise RepairError(
            "No pre-retry Lambda backup was found under "
            "backups/retry-v4-*/lambda-before.zip."
        )

    for index, candidate in enumerate(candidates, start=1):
        candidate_zip = root / f"candidate-{index}.zip"
        candidate_dir = root / f"candidate-{index}"

        download_s3(candidate["Key"], candidate_zip)
        candidate_dir.mkdir(parents=True, exist_ok=True)

        try:
            with zipfile.ZipFile(candidate_zip) as archive:
                archive.extractall(candidate_dir)
        except zipfile.BadZipFile:
            continue

        handler = find_handler_file(candidate_dir, handler_setting)
        source = handler.read_text(encoding="utf-8")

        required = (
            "async function recordAttempt",
            "async function getProgress",
            "async function createStudent",
        )
        forbidden = (
            "BEGIN SAT_MILESTONE_RETRY",
            "SAT_RETRY_BUILD",
            "SHARED_PROGRESS_REPAIR_BUILD",
        )

        action_cases_present = all(
            re.search(
                rf"""case\s+['"]{re.escape(action)}['"]\s*:""",
                source,
            )
            for action in required_actions
        )

        if (
            all(value in source for value in required)
            and action_cases_present
            and not any(
                value in source for value in forbidden
            )
        ):
            return candidate["Key"], candidate_zip, candidate_dir, handler

    raise RepairError(
        "No clean pre-retry Lambda backup was found. Nothing was changed."
    )


def create_zip(source_dir, destination):
    with zipfile.ZipFile(
        destination,
        "w",
        zipfile.ZIP_DEFLATED,
    ) as archive:
        for path in sorted(source_dir.rglob("*")):
            if path.is_file():
                archive.write(
                    path,
                    path.relative_to(source_dir),
                )


def skip_string_or_comment(text, index):
    length = len(text)

    if text.startswith("//", index):
        newline = text.find("\n", index + 2)
        return length if newline < 0 else newline + 1

    if text.startswith("/*", index):
        end = text.find("*/", index + 2)
        return length if end < 0 else end + 2

    quote = text[index]

    if quote in ("'", '"'):
        index += 1
        while index < length:
            if text[index] == "\\":
                index += 2
                continue
            if text[index] == quote:
                return index + 1
            index += 1
        return length

    if quote == "`":
        index += 1
        while index < length:
            if text[index] == "\\":
                index += 2
                continue
            if text[index] == "`":
                return index + 1
            index += 1
        return length

    return index + 1


def find_matching_delimiter(
    text,
    start,
    opening,
    closing,
):
    if start < 0 or start >= len(text) or text[start] != opening:
        raise RepairError(
            f"Expected {opening!r} at position {start}."
        )

    depth = 0
    index = start

    while index < len(text):
        if (
            text.startswith("//", index)
            or text.startswith("/*", index)
            or text[index] in ("'", '"', "`")
        ):
            index = skip_string_or_comment(text, index)
            continue

        character = text[index]

        if character == opening:
            depth += 1
        elif character == closing:
            depth -= 1

            if depth == 0:
                return index

        index += 1

    raise RepairError(
        f"Matching {closing!r} was not found."
    )


def find_function_span(text, function_name):
    match = re.search(
        rf"\b(?:async\s+)?function\s+"
        rf"{re.escape(function_name)}\b",
        text,
    )

    if not match:
        raise RepairError(
            f"Function {function_name} was not found."
        )

    parameter_start = text.find("(", match.end())

    if parameter_start < 0:
        raise RepairError(
            f"Parameter list for {function_name} was not found."
        )

    parameter_end = find_matching_delimiter(
        text,
        parameter_start,
        "(",
        ")",
    )

    body_start = parameter_end + 1

    while body_start < len(text):
        if text.startswith("//", body_start):
            body_start = skip_string_or_comment(
                text,
                body_start,
            )
            continue

        if text.startswith("/*", body_start):
            body_start = skip_string_or_comment(
                text,
                body_start,
            )
            continue

        if text[body_start].isspace():
            body_start += 1
            continue

        break

    if (
        body_start >= len(text)
        or text[body_start] != "{"
    ):
        raise RepairError(
            f"Function body for {function_name} was not found."
        )

    body_end = find_matching_delimiter(
        text,
        body_start,
        "{",
        "}",
    )

    end = body_end + 1

    while end < len(text) and text[end] in " \t":
        end += 1

    if end < len(text) and text[end] == ";":
        end += 1

    while end < len(text) and text[end] in "\r\n":
        end += 1

    return match.start(), end


def replace_function(text, function_name, replacement):
    start, end = find_function_span(text, function_name)
    return (
        text[:start]
        + replacement.strip()
        + "\n\n"
        + text[end:]
    )


def patch_dynamodb_import(text):
    match = re.search(
        r"import\s*\{(?P<body>[\s\S]*?)\}\s*from\s*"
        r"['\"]@aws-sdk/lib-dynamodb['\"]\s*;?",
        text,
    )

    if not match:
        raise RepairError(
            "@aws-sdk/lib-dynamodb import was not found."
        )

    names = [
        value.strip()
        for value in match.group("body").split(",")
        if value.strip()
    ]

    for required in (
        "GetCommand",
        "QueryCommand",
        "UpdateCommand",
    ):
        if required not in names:
            names.append(required)

    replacement = (
        "import {\n  "
        + ",\n  ".join(dict.fromkeys(names))
        + "\n} from '@aws-sdk/lib-dynamodb';"
    )

    return (
        text[:match.start()]
        + replacement
        + text[match.end():]
    )


def find_local_script_keys(html_text):
    values = re.findall(
        r"<script\b[^>]*\bsrc\s*=\s*['\"]([^'\"]+)['\"]",
        html_text,
        flags=re.IGNORECASE,
    )

    keys = []

    for value in values:
        parsed = urllib.parse.urlparse(value)

        if parsed.scheme or parsed.netloc:
            continue

        clean = parsed.path.strip()

        if not clean:
            continue

        if clean.startswith("/"):
            key = clean.lstrip("/")
        else:
            key = str(
                PurePosixPath(ENGLISH_PAGE_KEY).parent / clean
            )

        key = str(PurePosixPath(key))

        if key not in keys:
            keys.append(key)

    return keys


def detect_read_actions(html_text, script_texts):
    combined = "\n".join([html_text] + script_texts)
    actions = set(
        re.findall(
            r"action\s*:\s*['\"]([A-Za-z0-9_-]+)['\"]",
            combined,
        )
    )

    unsafe = (
        "create",
        "delete",
        "remove",
        "update",
        "record",
        "save",
        "unlock",
        "reset",
        "send",
        "archive",
    )

    read_actions = sorted(
        action
        for action in actions
        if not any(value in action.lower() for value in unsafe)
        and (
            "progress" in action.lower()
            or "student" in action.lower()
            or "validate" in action.lower()
            or "verify" in action.lower()
            or action.lower().startswith("get")
        )
    )

    if "progress" not in read_actions:
        read_actions.append("progress")

    return read_actions


def cleanup_test_records():
    users = [TEST_USER, ENGLISH_WRITE_USER]
    requests = []

    for user_id in users:
        with tempfile.NamedTemporaryFile(
            "w",
            suffix=".json",
            delete=False,
            encoding="utf-8",
        ) as file:
            json.dump({":userId": {"S": user_id}}, file)
            values_path = Path(file.name)

        try:
            raw = aws(
                "dynamodb",
                "query",
                "--table-name",
                TABLE_NAME,
                "--key-condition-expression",
                "userId = :userId",
                "--expression-attribute-values",
                f"file://{values_path}",
                "--projection-expression",
                "userId, questionId",
                "--consistent-read",
                "--output",
                "json",
                capture=True,
                check=False,
            )
            for item in json.loads(raw or "{}").get("Items", []):
                if "userId" in item and "questionId" in item:
                    requests.append({
                        "DeleteRequest": {
                            "Key": {
                                "userId": item["userId"],
                                "questionId": item["questionId"],
                            }
                        }
                    })
        finally:
            values_path.unlink(missing_ok=True)

        requests.append({
            "DeleteRequest": {
                "Key": {
                    "userId": {"S": "__students__"},
                    "questionId": {"S": f"student#{user_id}"},
                }
            }
        })

    for offset in range(0, len(requests), 25):
        batch = requests[offset:offset + 25]
        with tempfile.NamedTemporaryFile(
            "w",
            suffix=".json",
            delete=False,
            encoding="utf-8",
        ) as file:
            json.dump({TABLE_NAME: batch}, file)
            request_path = Path(file.name)

        try:
            aws(
                "dynamodb",
                "batch-write-item",
                "--request-items",
                f"file://{request_path}",
                capture=True,
                check=False,
            )
        finally:
            request_path.unlink(missing_ok=True)


def extract_learned(payload):
    found = set()

    def visit(value):
        if isinstance(value, dict):
            for key in ("learned", "learnedWords", "words"):
                candidate = value.get(key)
                if isinstance(candidate, list):
                    for number in candidate:
                        try:
                            number = int(number)
                        except (TypeError, ValueError):
                            continue
                        if 1 <= number <= 375:
                            found.add(number)

            question_id = str(value.get("questionId", ""))
            match = re.fullmatch(r"eng-word-(\d{1,3})", question_id)
            if match:
                number = int(match.group(1))
                if 1 <= number <= 375:
                    found.add(number)

            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(payload)
    return sorted(found)


def validate_english(progress_api, actions, admin_password):
    print(
        f"   Testing read-only English API actions "
        f"for student '{ENGLISH_TEST_STUDENT}'..."
    )

    required = {
        action
        for action in actions
        if action in {
            "getStudent",
            "englishProgress",
            "progress",
        }
    }
    passed = set()

    for action in actions:
        payload = {
            "action": action,
            "userId": ENGLISH_TEST_STUDENT,
            "studentId": ENGLISH_TEST_STUDENT,
            "student": ENGLISH_TEST_STUDENT,
            "pageId": "SAT_Words_326_350",
            "pageKey": ENGLISH_PAGE_KEY,
            "fileName": "SAT_Words_326_350.html",
            "sectionId": "SAT_Words_326_350",
            "wordSetId": "326_350",
            "wordRange": "326-350",
        }

        try:
            http_post(progress_api, payload)
            passed.add(action)
            print(f"   PASS: {action}")
        except RepairError as error:
            if action in required:
                raise RepairError(
                    f"Required English action {action!r} failed: {error}"
                ) from error
            print(f"   INFO: skipped optional read action {action!r}.")

    missing = required - passed
    if missing:
        raise RepairError(
            "Required English actions did not pass: "
            + ", ".join(sorted(missing))
        )

    print("   Creating or reusing a temporary English write-test student...")
    try:
        http_post(
            progress_api,
            {
                "action": "createStudent",
                "adminPassword": admin_password,
                "displayName": "English Write Verification",
                "requestedStudentId": ENGLISH_WRITE_USER,
            },
        )
    except RepairError as error:
        message = str(error).lower()
        if "409" not in message and "already" not in message and "exists" not in message:
            raise
        print("   INFO: temporary English write-test student already exists.")

    def save(words):
        return http_post(
            progress_api,
            {
                "action": "saveEnglishProgress",
                "userId": ENGLISH_WRITE_USER,
                "studentId": ENGLISH_WRITE_USER,
                "student": ENGLISH_WRITE_USER,
                "learned": words,
            },
        )

    def read():
        return http_post(
            progress_api,
            {
                "action": "englishProgress",
                "userId": ENGLISH_WRITE_USER,
                "studentId": ENGLISH_WRITE_USER,
                "student": ENGLISH_WRITE_USER,
            },
        )

    print("   Writing learned words 374 and 375...")
    save([374, 375])
    first_read = extract_learned(read())
    if 374 not in first_read or 375 not in first_read:
        raise RepairError(
            "English write/readback failed. Expected words 374 and 375, "
            f"but API returned {first_read}."
        )
    print("   PASS: English words were saved and read back.")

    print("   Removing word 374 and verifying exact replacement...")
    save([375])
    second_read = extract_learned(read())
    if 375 not in second_read or 374 in second_read:
        raise RepairError(
            "English replacement save failed. Expected only word 375, "
            f"but API returned {second_read}."
        )
    print("   PASS: English unlearn/reset changes are also persisted.")


def run_math_retry_test(progress_api, admin_password):
    print("   Creating a temporary administrator-managed student...")

    http_post(
        progress_api,
        {
            "action": "createStudent",
            "adminPassword": admin_password,
            "displayName": "Shared API Repair Test",
            "requestedStudentId": TEST_USER,
        },
    )

    print("   Creating 20 temporary Math first attempts...")

    for number in range(1, 21):
        try:
            http_post(
                progress_api,
                {
                    "action": "record",
                    "userId": TEST_USER,
                    "questionId": f"v3q{number:03d}",
                    "correct": number != 1,
                    "choice": (
                        "wrong-first-answer"
                        if number == 1
                        else "test-answer"
                    ),
                    "category": "shared-api-repair-test",
                },
            )
        except Exception as error:
            raise RepairError(
                f"Math first-attempt test failed on "
                f"question {number}: {error}"
            ) from error

        if number in (1, 20):
            print(
                f"   PASS: temporary first attempt {number}/20"
            )

    progress = http_post(
        progress_api,
        {
            "action": "progress",
            "userId": TEST_USER,
        },
    )

    first = next(
        (
            item
            for item in progress.get("items", [])
            if item.get("questionId") == "v3q001"
        ),
        None,
    )

    if not first or first.get("correctionAllowed") is not True:
        raise RepairError(
            "Math correction did not unlock after 20 unique attempts."
        )

    saved = http_post(
        progress_api,
        {
            "action": "record",
            "userId": TEST_USER,
            "questionId": "v3q001",
            "correct": True,
            "choice": "corrected-answer",
            "category": "shared-api-repair-test",
        },
    )

    if (
        saved.get("lastResult") != "correct"
        or int(saved.get("attempts", 0)) != 2
        or saved.get("lastChoice") != "corrected-answer"
    ):
        raise RepairError(
            "Math correction retry did not save correctly."
        )

    print("   PASS: Math milestone correction still works.")



def print_recent_lambda_errors(lambda_function):
    """Print recent Lambda log lines to diagnose a failed live test."""
    log_group = f"/aws/lambda/{lambda_function}"

    output = aws(
        "logs",
        "tail",
        log_group,
        "--since",
        "10m",
        "--format",
        "short",
        capture=True,
        check=False,
    )

    if not output:
        print("   No recent CloudWatch log lines were available.")
        return

    lines = output.splitlines()
    important = [
        line
        for line in lines
        if any(
            token in line
            for token in (
                "ERROR",
                "Error",
                "Exception",
                "ValidationException",
                "INTERNAL_ERROR",
            )
        )
    ]

    selected = important[-20:] if important else lines[-20:]

    print()
    print("Recent Lambda diagnostic log lines:")
    for line in selected:
        print("   " + line)


def normalize_script_key(page_key, src):
    parsed = urllib.parse.urlsplit(src)
    path = parsed.path
    if path.startswith("/"):
        return path.lstrip("/")
    base = PurePosixPath(page_key).parent
    return str(base / path)


def deploy_frontend_bridge(progress_api, root):
    print("9. Installing the verified English browser write bridge...")

    english_dir = root / "english-site"
    english_dir.mkdir(parents=True, exist_ok=True)
    live_js = english_dir / "english-progress.js"
    original_js = english_dir / "english-progress.js.before"
    patched_js = english_dir / "english-progress.js.patched"
    html_dir = english_dir / "html"
    html_dir.mkdir(parents=True, exist_ok=True)

    download_s3("english/english-progress.js", live_js)
    shutil.copy2(live_js, original_js)

    source = live_js.read_text(encoding="utf-8")
    start_marker = "/* BEGIN SAT ENGLISH VERIFIED WRITE BRIDGE V5 */"
    end_marker = "/* END SAT ENGLISH VERIFIED WRITE BRIDGE V5 */"

    if start_marker in source and end_marker in source:
        source = re.sub(
            re.escape(start_marker) + r"[\s\S]*?" + re.escape(end_marker),
            "",
            source,
            count=1,
        ).rstrip() + "\n"

    bridge = r'''/* BEGIN SAT ENGLISH VERIFIED WRITE BRIDGE V5 */
(() => {
  'use strict';

  const API = __API__;
  const TOTAL = 375;
  const existing = window.SATEnglishCloud || {};

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
      const claims = JSON.parse(decodeURIComponent(atob(padded).split('').map(
        c => '%' + c.charCodeAt(0).toString(16).padStart(2, '0')
      ).join('')));
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

  const storageKey = existing.storageKey ||
    (studentId ? `satEnglish300Progress:${studentId}` : 'sat300-nireekshan-progress-v1');

  function normalizeLearned(values) {
    return [...new Set((Array.isArray(values) ? values : [])
      .map(Number)
      .filter(n => Number.isInteger(n) && n >= 1 && n <= TOTAL))]
      .sort((a, b) => a - b);
  }

  function readLocal() {
    try {
      const saved = JSON.parse(localStorage.getItem(storageKey) || '{}');
      return normalizeLearned(saved.learned);
    } catch (_) {
      return [];
    }
  }

  function writeLocal(learned) {
    localStorage.setItem(storageKey, JSON.stringify({learned: normalizeLearned(learned)}));
  }

  function extractLearned(value, result = new Set()) {
    if (Array.isArray(value)) {
      value.forEach(item => extractLearned(item, result));
      return result;
    }
    if (!value || typeof value !== 'object') return result;

    ['learned', 'learnedWords', 'words'].forEach(key => {
      if (Array.isArray(value[key])) {
        normalizeLearned(value[key]).forEach(number => result.add(number));
      }
    });

    const match = String(value.questionId || '').match(/^eng-word-(\d{1,3})$/);
    if (match) {
      const number = Number(match[1]);
      if (number >= 1 && number <= TOTAL) result.add(number);
    }

    Object.values(value).forEach(child => extractLearned(child, result));
    return result;
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
    let body = {};
    try { body = text ? JSON.parse(text) : {}; } catch (_) { body = {raw: text}; }
    if (!response.ok) {
      throw new Error(`English progress API ${response.status}: ${text}`);
    }
    return body;
  }

  let timer = null;
  let pending = null;
  let activeSave = Promise.resolve();
  let lastError = null;

  async function saveNow(learned) {
    const cleaned = normalizeLearned(learned);
    let error = null;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      try {
        await post('saveEnglishProgress', {learned: cleaned});
        lastError = null;
        window.dispatchEvent(new CustomEvent('sat-english-progress-synced', {
          detail: {studentId, learned: cleaned}
        }));
        return cleaned;
      } catch (caught) {
        error = caught;
        await new Promise(resolve => setTimeout(resolve, attempt * 500));
      }
    }
    lastError = error;
    console.error('SAT English progress was not saved.', error);
    window.dispatchEvent(new CustomEvent('sat-english-progress-sync-error', {
      detail: {studentId, error: String(error)}
    }));
    throw error;
  }

  function queueLearnedSync(learned) {
    pending = normalizeLearned(learned);
    clearTimeout(timer);
    timer = setTimeout(() => {
      const value = pending;
      pending = null;
      activeSave = activeSave.catch(() => {}).then(() => saveNow(value));
    }, 150);
    return activeSave;
  }

  const originalReady = Promise.resolve(existing.ready).catch(error => {
    console.warn('Older English progress initialization failed; verified bridge continuing.', error);
  });

  const ready = originalReady.then(async () => {
    if (!studentId) return;
    const local = readLocal();
    try {
      const remotePayload = await post('englishProgress');
      const remote = normalizeLearned([...extractLearned(remotePayload)]);
      const merged = normalizeLearned([...remote, ...local]);
      writeLocal(merged);
      if (merged.length !== remote.length || merged.some((n, i) => n !== remote[i])) {
        await saveNow(merged);
      }
    } catch (error) {
      lastError = error;
      console.error('Unable to load SAT English cloud progress.', error);
    }
  });

  window.SATEnglishCloud = {
    ...existing,
    studentId,
    storageKey,
    ready,
    queueLearnedSync,
    flush: () => {
      clearTimeout(timer);
      if (pending) {
        const value = pending;
        pending = null;
        activeSave = activeSave.catch(() => {}).then(() => saveNow(value));
      }
      return activeSave;
    },
    getLastSyncError: () => lastError
  };

  window.addEventListener('pagehide', () => {
    const learned = pending || readLocal();
    if (!studentId || !navigator.sendBeacon) return;
    const payload = JSON.stringify({
      action: 'saveEnglishProgress',
      userId: studentId,
      studentId,
      student: studentId,
      learned: normalizeLearned(learned)
    });
    navigator.sendBeacon(API, new Blob([payload], {type: 'application/json'}));
  });
})();
/* END SAT ENGLISH VERIFIED WRITE BRIDGE V5 */'''

    bridge = bridge.replace("__API__", json.dumps(progress_api))
    patched_js.write_text(source.rstrip() + "\n\n" + bridge + "\n", encoding="utf-8")
    run(["node", "--check", str(patched_js)])

    aws(
        "s3", "sync",
        f"s3://{BUCKET}/english",
        str(html_dir),
        "--exclude", "*",
        "--include", "*.html",
        "--only-show-errors",
    )

    changed = []
    script_pattern = re.compile(
        r'(?P<prefix><script\b[^>]*\bsrc=["\'](?:\./)?english-progress\.js)'
        r'(?:\?[^"\']*)?'
        r'(?P<suffix>["\'][^>]*></script>)',
        re.IGNORECASE,
    )

    for path in sorted(html_dir.rglob("*.html")):
        original = path.read_text(encoding="utf-8")
        updated, count = script_pattern.subn(
            lambda match: match.group("prefix") + f"?v={BUILD}" + match.group("suffix"),
            original,
        )
        if count:
            path.write_text(updated, encoding="utf-8")
            changed.append(path)

    if not changed:
        raise RepairError("No English HTML pages reference english-progress.js.")

    backup_prefix = f"{EMERGENCY_PREFIX}/frontend"
    uploaded = []

    try:
        aws(
            "s3", "cp",
            f"s3://{BUCKET}/english/english-progress.js",
            f"s3://{BUCKET}/{backup_prefix}/english/english-progress.js",
            "--only-show-errors",
        )
        aws(
            "s3", "cp",
            str(patched_js),
            f"s3://{BUCKET}/english/english-progress.js",
            "--content-type", "application/javascript; charset=utf-8",
            "--cache-control", "no-cache, no-store, must-revalidate",
            "--only-show-errors",
        )
        uploaded.append("english/english-progress.js")

        for path in changed:
            relative = path.relative_to(html_dir).as_posix()
            live_key = f"english/{relative}"
            backup_key = f"{backup_prefix}/{live_key}"
            aws(
                "s3", "cp",
                f"s3://{BUCKET}/{live_key}",
                f"s3://{BUCKET}/{backup_key}",
                "--only-show-errors",
            )
            aws(
                "s3", "cp",
                str(path),
                f"s3://{BUCKET}/{live_key}",
                "--content-type", "text/html; charset=utf-8",
                "--cache-control", "no-cache, no-store, must-revalidate",
                "--only-show-errors",
            )
            uploaded.append(live_key)

        distribution_id = aws(
            "cloudfront", "list-distributions",
            "--query",
            "DistributionList.Items[?Aliases.Quantity > `0` && contains(Aliases.Items, 'sat.denduluru.com')].Id | [0]",
            "--output", "text",
            capture=True,
        )
        if not distribution_id or distribution_id == "None":
            raise RepairError("CloudFront distribution for sat.denduluru.com was not found.")

        invalidation_id = aws(
            "cloudfront", "create-invalidation",
            "--distribution-id", distribution_id,
            "--paths", "/english/english-progress.js*", "/english/*",
            "--query", "Invalidation.Id",
            "--output", "text",
            capture=True,
        )
        aws(
            "cloudfront", "wait", "invalidation-completed",
            "--distribution-id", distribution_id,
            "--id", invalidation_id,
        )

        deployed_js = read_s3_text("english/english-progress.js")
        if start_marker not in deployed_js:
            raise RepairError("Verified browser write bridge is absent after upload.")

        print(f"   PASS: browser bridge deployed to {len(changed)} English page(s).")
        print(f"   Frontend backup: s3://{BUCKET}/{backup_prefix}/")

    except Exception:
        print("   Frontend deployment failed; restoring the previous English files...")
        for live_key in reversed(uploaded):
            backup_key = f"{backup_prefix}/{live_key}"
            aws(
                "s3", "cp",
                f"s3://{BUCKET}/{backup_key}",
                f"s3://{BUCKET}/{live_key}",
                "--only-show-errors",
                check=False,
            )
        raise


def main():
    require_commands()

    account = aws(
        "sts",
        "get-caller-identity",
        "--query",
        "Account",
        "--output",
        "text",
        capture=True,
    )

    if account != EXPECTED_ACCOUNT:
        raise RepairError(
            f"Expected account {EXPECTED_ACCOUNT}, but AWS returned {account}."
        )

    print("=" * 68)
    print(" Repair SAT English word progress writes v5")
    print("=" * 68)
    print(f"AWS profile: {PROFILE}")
    print(f"AWS account: {account}")
    print(f"S3 bucket:   {BUCKET}")
    print(f"Build:       {BUILD}")
    print()

    with tempfile.TemporaryDirectory(
        prefix="sat-shared-api-repair-"
    ) as temp_name:
        root = Path(temp_name)
        current_lambda_zip = root / "current-lambda.zip"
        repaired_zip = root / "repaired-lambda.zip"

        print("1. Reading the live English page and its scripts...")

        english_html = read_s3_text(ENGLISH_PAGE_KEY)
        script_texts = []

        for key in find_local_script_keys(english_html):
            try:
                script_texts.append(read_s3_text(key))
            except RepairError:
                print(f"   INFO: skipped unavailable script {key}")

        combined = "\n".join([english_html] + script_texts)
        progress_api = extract_progress_api(combined)
        all_actions = sorted(
            set(
                re.findall(
                    r"""action\s*:\s*['"]([A-Za-z0-9_-]+)['"]""",
                    combined,
                )
            )
        )
        actions = detect_read_actions(english_html, script_texts)

        print(f"   Progress API: {progress_api}")
        print("   English actions: " + ", ".join(all_actions))
        print("   Read-only tests: " + ", ".join(actions))

        print("2. Finding the live Lambda...")

        lambda_function = find_lambda_for_url(progress_api)
        print(f"   Lambda: {lambda_function}")

        configuration = json.loads(
            aws(
                "lambda",
                "get-function-configuration",
                "--function-name",
                lambda_function,
                "--output",
                "json",
                capture=True,
            )
        )

        handler_setting = configuration["Handler"]
        admin_password = (
            configuration
            .get("Environment", {})
            .get("Variables", {})
            .get("ADMIN_PASSWORD")
        )

        if not admin_password:
            raise RepairError("ADMIN_PASSWORD is not configured.")

        code_location = aws(
            "lambda",
            "get-function",
            "--function-name",
            lambda_function,
            "--query",
            "Code.Location",
            "--output",
            "text",
            capture=True,
        )

        urllib.request.urlretrieve(
            code_location,
            current_lambda_zip,
        )

        print("3. Selecting a clean pre-retry Lambda backup...")

        (
            backup_key,
            _backup_zip,
            source_dir,
            handler_path,
        ) = choose_clean_pre_retry_backup(
            root,
            handler_setting,
            all_actions,
        )

        print(f"   Source: s3://{BUCKET}/{backup_key}")
        print(
            "   Handler: "
            + str(handler_path.relative_to(source_dir))
        )

        print("4. Preserving all shared functions and patching only Math progress...")

        source = handler_path.read_text(encoding="utf-8")
        source = patch_dynamodb_import(source)

        record_start, _ = find_function_span(source, "recordAttempt")
        helpers = HELPERS_JS.replace("__BUILD__", BUILD).strip()
        source = source[:record_start] + helpers + "\n\n" + source[record_start:]
        source = replace_function(source, "recordAttempt", RECORD_JS)
        source = replace_function(source, "getProgress", GET_PROGRESS_JS)

        handler_path.write_text(source, encoding="utf-8")

        run(["node", "--check", str(handler_path)])
        create_zip(source_dir, repaired_zip)

        print("   PASS: repaired Lambda syntax is valid.")

        print("5. Saving the current Lambda as an emergency backup...")

        upload_s3(
            current_lambda_zip,
            f"{EMERGENCY_PREFIX}/lambda-before-repair.zip",
        )

        deployed = False
        tests_passed = False

        try:
            print("6. Deploying the repaired shared Lambda...")

            aws(
                "lambda",
                "update-function-code",
                "--function-name",
                lambda_function,
                "--zip-file",
                f"fileb://{repaired_zip}",
                capture=True,
            )
            deployed = True

            aws(
                "lambda",
                "wait",
                "function-updated",
                "--function-name",
                lambda_function,
            )

            print("7. Testing English reads and a real DynamoDB write/readback...")
            validate_english(progress_api, actions, admin_password)

            print("8. Testing the 20-question Math correction...")
            run_math_retry_test(progress_api, admin_password)

            deploy_frontend_bridge(progress_api, root)

            print("10. Re-running the English write/readback after frontend deployment...")
            validate_english(progress_api, actions, admin_password)

            tests_passed = True

        except Exception:
            if deployed and not tests_passed:
                print_recent_lambda_errors(
                    lambda_function
                )

                print()
                print("A live test failed. Restoring the previous Lambda...")

                aws(
                    "lambda",
                    "update-function-code",
                    "--function-name",
                    lambda_function,
                    "--zip-file",
                    f"fileb://{current_lambda_zip}",
                    capture=True,
                    check=False,
                )

                aws(
                    "lambda",
                    "wait",
                    "function-updated",
                    "--function-name",
                    lambda_function,
                    check=False,
                )

            raise
        finally:
            cleanup_test_records()

    print()
    print("=" * 68)
    print(" SAT ENGLISH WORD PROGRESS REPAIR PASSED")
    print("=" * 68)
    print()
    print("Verified:")
    print("  - English learned words save to DynamoDB and read back correctly.")
    print("  - Removing/resetting a learned word is persisted correctly.")
    print("  - Math corrections still unlock after 20 unique attempts.")
    print("  - A corrected Math answer is saved as attempt 2.")
    print()
    print("  - Every English vocabulary page now loads the verified write bridge.")
    print()
    print("Close all SAT tabs, reopen the student link, mark one word learned, and refresh.")


HELPERS_JS = "\n// BEGIN SHARED_PROGRESS_REPAIR_HELPERS\nconst SHARED_PROGRESS_REPAIR_BUILD = '__BUILD__';\nconst SAT_RETRY_MILESTONE_SIZE = 20;\n\nfunction satMathQuestionPosition(questionId) {\n  const id = String(questionId || '').trim();\n\n  let match = id.match(/^v([1-3])q(\\d{3})$/i);\n  if (match) {\n    return {\n      group: `v${match[1]}q`,\n      setNumber: 1,\n      volumeNumber: Number(match[1]),\n      questionNumber: Number(match[2]),\n      totalQuestions: 100\n    };\n  }\n\n  match = id.match(/^s(\\d+)v([1-3])q(\\d{3})$/i);\n  if (match) {\n    return {\n      group: `s${match[1]}v${match[2]}q`,\n      setNumber: Number(match[1]),\n      volumeNumber: Number(match[2]),\n      questionNumber: Number(match[3]),\n      totalQuestions: 100\n    };\n  }\n\n  return null;\n}\n\nfunction satProgressFirstTime(item) {\n  const time = Date.parse(\n    item?.firstAt ||\n    item?.lastAt ||\n    ''\n  );\n\n  return Number.isFinite(time)\n    ? time\n    : Number.MAX_SAFE_INTEGER;\n}\n\nfunction satNormalizeProgressItem(item) {\n  const attempted = Boolean(item?.lastResult);\n  const storedLocked =\n    typeof item?.locked === 'boolean'\n      ? item.locked\n      : attempted;\n  const storedCorrectionAllowed =\n    item?.correctionAllowed === true;\n\n  return {\n    ...item,\n    attempts: Number(\n      item?.attempts || (attempted ? 1 : 0)\n    ),\n    storedLocked,\n    storedCorrectionAllowed,\n    locked: storedLocked,\n    correctionAllowed:\n      attempted &&\n      item.lastResult === 'incorrect' &&\n      (\n        !storedLocked ||\n        storedCorrectionAllowed\n      )\n  };\n}\n\nfunction satDecorateProgressItems(rawItems) {\n  const items = (rawItems || []).map(\n    satNormalizeProgressItem\n  );\n  const grouped = new Map();\n\n  for (const item of items) {\n    const position =\n      satMathQuestionPosition(item.questionId);\n\n    if (!position) continue;\n\n    if (!grouped.has(position.group)) {\n      grouped.set(position.group, {\n        position,\n        items: []\n      });\n    }\n\n    grouped.get(position.group).items.push(item);\n  }\n\n  const retryPolicy = {};\n\n  for (const [group, value] of grouped.entries()) {\n    const sorted = [...value.items].sort(\n      (left, right) => {\n        const timeDifference =\n          satProgressFirstTime(left) -\n          satProgressFirstTime(right);\n\n        if (timeDifference !== 0) {\n          return timeDifference;\n        }\n\n        const leftNumber =\n          satMathQuestionPosition(\n            left.questionId\n          )?.questionNumber || 999;\n        const rightNumber =\n          satMathQuestionPosition(\n            right.questionId\n          )?.questionNumber || 999;\n\n        return leftNumber - rightNumber;\n      }\n    );\n\n    const attempted = sorted.length;\n    const milestoneUnlocked = Math.min(\n      value.position.totalQuestions,\n      Math.floor(\n        attempted / SAT_RETRY_MILESTONE_SIZE\n      ) * SAT_RETRY_MILESTONE_SIZE\n    );\n    const nextMilestone =\n      attempted >= value.position.totalQuestions\n        ? value.position.totalQuestions\n        : Math.min(\n            value.position.totalQuestions,\n            milestoneUnlocked +\n              SAT_RETRY_MILESTONE_SIZE\n          );\n\n    let retryAvailable = 0;\n\n    sorted.forEach((item, index) => {\n      const attemptRank = index + 1;\n      const incorrect =\n        item.lastResult === 'incorrect';\n      const administratorAllowed =\n        incorrect &&\n        (\n          item.storedLocked === false ||\n          item.storedCorrectionAllowed === true\n        );\n      const autoCorrectionAvailable =\n        incorrect &&\n        item.attempts === 1 &&\n        attemptRank <= milestoneUnlocked;\n      const correctionAllowed =\n        administratorAllowed ||\n        autoCorrectionAvailable;\n\n      item.attemptRank = attemptRank;\n      item.milestoneUnlocked =\n        milestoneUnlocked;\n      item.nextMilestone = nextMilestone;\n      item.attemptsToNext = Math.max(\n        0,\n        nextMilestone - attempted\n      );\n      item.autoCorrectionAvailable =\n        autoCorrectionAvailable;\n      item.correctionAllowed =\n        correctionAllowed;\n      item.correctionSource =\n        administratorAllowed\n          ? 'administrator'\n          : autoCorrectionAvailable\n            ? 'milestone'\n            : null;\n      item.locked =\n        item.lastResult === 'correct'\n          ? true\n          : incorrect\n            ? !correctionAllowed\n            : false;\n\n      if (correctionAllowed) {\n        retryAvailable += 1;\n      }\n    });\n\n    retryPolicy[group] = {\n      setNumber: value.position.setNumber,\n      volumeNumber:\n        value.position.volumeNumber,\n      totalQuestions:\n        value.position.totalQuestions,\n      attempted,\n      milestoneUnlocked,\n      nextMilestone,\n      attemptsToNext: Math.max(\n        0,\n        nextMilestone - attempted\n      ),\n      retryAvailable\n    };\n  }\n\n  return {\n    items,\n    retryPolicy\n  };\n}\n\nasync function satQueryAllProgress(userId) {\n  const result = await ddb.send(\n    new QueryCommand({\n      TableName: TABLE,\n      KeyConditionExpression:\n        'userId = :userId',\n      ExpressionAttributeValues: {\n        ':userId': userId\n      },\n      ConsistentRead: true\n    })\n  );\n\n  return result.Items || [];\n}\n\nasync function satQueryVolumeProgress(\n  userId,\n  group\n) {\n  const result = await ddb.send(\n    new QueryCommand({\n      TableName: TABLE,\n      KeyConditionExpression:\n        'userId = :userId AND ' +\n        'begins_with(questionId, :group)',\n      ExpressionAttributeValues: {\n        ':userId': userId,\n        ':group': group\n      },\n      ConsistentRead: true\n    })\n  );\n\n  return result.Items || [];\n}\n\nasync function satGetProgressItem(\n  userId,\n  questionId\n) {\n  const result = await ddb.send(\n    new GetCommand({\n      TableName: TABLE,\n      Key: {\n        userId,\n        questionId\n      },\n      ConsistentRead: true\n    })\n  );\n\n  return result.Item || null;\n}\n\nasync function satIsAutomaticCorrectionAvailable(\n  userId,\n  questionId\n) {\n  const position =\n    satMathQuestionPosition(questionId);\n\n  if (!position) return false;\n\n  const rawItems =\n    await satQueryVolumeProgress(\n      userId,\n      position.group\n    );\n\n  const item =\n    satDecorateProgressItems(rawItems)\n      .items\n      .find(\n        candidate =>\n          candidate.questionId === questionId\n      );\n\n  return Boolean(\n    item?.autoCorrectionAvailable\n  );\n}\n\nasync function satDecorateSavedProgressItem(\n  userId,\n  savedItem\n) {\n  const position =\n    satMathQuestionPosition(\n      savedItem?.questionId\n    );\n\n  if (!position) {\n    return satNormalizeProgressItem(\n      savedItem\n    );\n  }\n\n  const rawItems =\n    await satQueryVolumeProgress(\n      userId,\n      position.group\n    );\n\n  return (\n    satDecorateProgressItems(rawItems)\n      .items\n      .find(\n        candidate =>\n          candidate.questionId ===\n          savedItem.questionId\n      ) ||\n    satNormalizeProgressItem(savedItem)\n  );\n}\n// END SHARED_PROGRESS_REPAIR_HELPERS\n"

RECORD_JS = "\nasync function recordAttempt({\n  userId,\n  questionId,\n  correct,\n  choice,\n  category\n}) {\n  const validQuestionId =\n    requireQuestionId(questionId);\n  const now = new Date().toISOString();\n  const existing =\n    await satGetProgressItem(\n      userId,\n      validQuestionId\n    );\n\n  let attemptMode = 'first';\n\n  if (existing) {\n    const attempts = Number(\n      existing.attempts || 1\n    );\n\n    if (\n      existing.lastResult === 'correct'\n    ) {\n      throw new HttpError(\n        409,\n        'QUESTION_LOCKED',\n        'This question has already been completed'\n      );\n    }\n\n    if (existing.locked === false) {\n      attemptMode = 'administrator';\n    } else if (\n      attempts === 1 &&\n      await satIsAutomaticCorrectionAvailable(\n        userId,\n        validQuestionId\n      )\n    ) {\n      attemptMode = 'milestone';\n    } else {\n      throw new HttpError(\n        409,\n        'QUESTION_LOCKED',\n        attempts > 1\n          ? 'The correction attempt is complete; administrator approval is required'\n          : 'This question is locked until its 20-question correction milestone'\n      );\n    }\n  }\n\n  const names = {\n    '#attempts': 'attempts',\n    '#correctCount': 'correctCount',\n    '#lastResult': 'lastResult',\n    '#lastChoice': 'lastChoice',\n    '#lastAt': 'lastAt',\n    '#category': 'category',\n    '#firstAt': 'firstAt',\n    '#locked': 'locked',\n    '#correctionAllowed':\n      'correctionAllowed',\n    '#lastAttemptType':\n      'lastAttemptType'\n  };\n\n  /*\n   * DynamoDB rejects unused ExpressionAttributeValues.\n   * First attempts do not use :zero or :incorrect, so add those\n   * values only for correction attempts.\n   */\n  const values = {\n    ':one': 1,\n    ':correctIncrement':\n      correct ? 1 : 0,\n    ':result':\n      correct ? 'correct' : 'incorrect',\n    ':choice': choice ?? null,\n    ':now': now,\n    ':category':\n      category ?? 'unknown',\n    ':true': true,\n    ':false': false,\n    ':attemptMode': attemptMode\n  };\n\n  if (attemptMode !== 'first') {\n    values[':zero'] = 0;\n    values[':incorrect'] = 'incorrect';\n  }\n\n  let updateExpression;\n  let conditionExpression;\n\n  if (attemptMode === 'first') {\n    updateExpression =\n      'ADD #attempts :one, ' +\n      '#correctCount :correctIncrement ' +\n      'SET #lastResult = :result, ' +\n      '#lastChoice = :choice, ' +\n      '#lastAt = :now, ' +\n      '#category = :category, ' +\n      '#firstAt = if_not_exists(' +\n      '#firstAt, :now), ' +\n      '#locked = :true, ' +\n      '#correctionAllowed = :false, ' +\n      '#lastAttemptType = :attemptMode';\n\n    conditionExpression =\n      'attribute_not_exists(#lastResult)';\n  } else {\n    updateExpression =\n      'SET #attempts = ' +\n      'if_not_exists(#attempts, :one) + :one, ' +\n      '#correctCount = ' +\n      'if_not_exists(#correctCount, :zero) + ' +\n      ':correctIncrement, ' +\n      '#lastResult = :result, ' +\n      '#lastChoice = :choice, ' +\n      '#lastAt = :now, ' +\n      '#category = :category, ' +\n      '#firstAt = if_not_exists(' +\n      '#firstAt, :now), ' +\n      '#locked = :true, ' +\n      '#correctionAllowed = :false, ' +\n      '#lastAttemptType = :attemptMode';\n\n    conditionExpression =\n      attemptMode === 'administrator'\n        ? '#lastResult = :incorrect AND ' +\n          '#locked = :false'\n        : '#lastResult = :incorrect AND ' +\n          '(attribute_not_exists(#attempts) ' +\n          'OR #attempts = :one)';\n  }\n\n  try {\n    const result = await ddb.send(\n      new UpdateCommand({\n        TableName: TABLE,\n        Key: {\n          userId,\n          questionId: validQuestionId\n        },\n        UpdateExpression:\n          updateExpression,\n        ConditionExpression:\n          conditionExpression,\n        ExpressionAttributeNames:\n          names,\n        ExpressionAttributeValues:\n          values,\n        ReturnValues: 'ALL_NEW'\n      })\n    );\n\n    return satDecorateSavedProgressItem(\n      userId,\n      result.Attributes\n    );\n  } catch (error) {\n    if (\n      error?.name ===\n      'ConditionalCheckFailedException'\n    ) {\n      throw new HttpError(\n        409,\n        'QUESTION_LOCKED',\n        'This question is no longer available for another attempt'\n      );\n    }\n\n    throw error;\n  }\n}\n"

GET_PROGRESS_JS = "\nasync function getProgress(userId) {\n  const rawItems =\n    await satQueryAllProgress(userId);\n  const decorated =\n    satDecorateProgressItems(rawItems);\n  const items = decorated.items;\n\n  const summary = items.reduce(\n    (value, item) => {\n      const everCorrect =\n        Number(\n          item.correctCount || 0\n        ) > 0;\n      const category =\n        item.category || 'unknown';\n\n      value.attempted += 1;\n      value.totalAttempts += Number(\n        item.attempts || 0\n      );\n      value.totalCorrect += Number(\n        item.correctCount || 0\n      );\n      value.mastered +=\n        everCorrect ? 1 : 0;\n      value.lockedIncorrect +=\n        item.lastResult === 'incorrect' &&\n        item.locked\n          ? 1\n          : 0;\n      value.retryAvailable +=\n        item.lastResult === 'incorrect' &&\n        item.correctionAllowed\n          ? 1\n          : 0;\n\n      value.byCategory[category] ||= {\n        attempted: 0,\n        mastered: 0\n      };\n\n      value.byCategory[\n        category\n      ].attempted += 1;\n\n      if (everCorrect) {\n        value.byCategory[\n          category\n        ].mastered += 1;\n      }\n\n      return value;\n    },\n    {\n      attempted: 0,\n      mastered: 0,\n      totalAttempts: 0,\n      totalCorrect: 0,\n      lockedIncorrect: 0,\n      retryAvailable: 0,\n      byCategory: {}\n    }\n  );\n\n  summary.accuracy =\n    summary.totalAttempts > 0\n      ? +(\n          summary.totalCorrect /\n          summary.totalAttempts\n        ).toFixed(3)\n      : 0;\n\n  return {\n    items,\n    summary,\n    retryPolicy:\n      decorated.retryPolicy,\n    retryBuild:\n      SHARED_PROGRESS_REPAIR_BUILD\n  };\n}\n"

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nRepair cancelled.", file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print()
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
