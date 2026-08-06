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

STAMP = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
BUILD = f"20260801-shared-api-repair-{STAMP}"
EMERGENCY_PREFIX = f"backups/shared-api-repair-{STAMP}"
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


def choose_clean_pre_retry_backup(root, handler_setting):
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

        if all(value in source for value in required) and not any(
            value in source for value in forbidden
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


def find_function_span(text, function_name):
    match = re.search(
        rf"\basync\s+function\s+{re.escape(function_name)}\s*\(",
        text,
    )

    if not match:
        match = re.search(
            rf"\bfunction\s+{re.escape(function_name)}\s*\(",
            text,
        )

    if not match:
        raise RepairError(
            f"Function {function_name} was not found."
        )

    brace_start = text.find("{", match.end())

    if brace_start < 0:
        raise RepairError(
            f"Opening brace for {function_name} was not found."
        )

    depth = 0
    index = brace_start

    while index < len(text):
        if (
            text.startswith("//", index)
            or text.startswith("/*", index)
            or text[index] in ("'", '"', "`")
        ):
            index = skip_string_or_comment(text, index)
            continue

        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                while end < len(text) and text[end] in " \t":
                    end += 1
                if end < len(text) and text[end] == ";":
                    end += 1
                while end < len(text) and text[end] in "\r\n":
                    end += 1
                return match.start(), end

        index += 1

    raise RepairError(
        f"Closing brace for {function_name} was not found."
    )


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
    requests = [
        {
            "DeleteRequest": {
                "Key": {
                    "userId": {"S": TEST_USER},
                    "questionId": {"S": f"v3q{number:03d}"},
                }
            }
        }
        for number in range(1, 21)
    ]

    requests.append(
        {
            "DeleteRequest": {
                "Key": {
                    "userId": {"S": "__students__"},
                    "questionId": {"S": f"student#{TEST_USER}"},
                }
            }
        }
    )

    with tempfile.NamedTemporaryFile(
        "w",
        suffix=".json",
        delete=False,
        encoding="utf-8",
    ) as file:
        json.dump({TABLE_NAME: requests}, file)
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


def validate_english(progress_api, actions, admin_password):
    print(f"   Testing English API for student '{ENGLISH_TEST_STUDENT}'...")

    progress_ok = False

    for action in actions:
        payload = {
            "action": action,
            "userId": ENGLISH_TEST_STUDENT,
            "studentId": ENGLISH_TEST_STUDENT,
            "student": ENGLISH_TEST_STUDENT,
            "adminPassword": admin_password,
        }

        try:
            http_post(progress_api, payload)
            print(f"   PASS: {action}")
            if action == "progress":
                progress_ok = True
        except RepairError:
            if action == "progress":
                raise
            print(f"   INFO: {action} needs a different page-specific payload.")

    if not progress_ok:
        raise RepairError(
            "Tim's English progress request did not succeed."
        )


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
    print(" Repair shared English/Math student-progress API")
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
        actions = detect_read_actions(english_html, script_texts)

        print(f"   Progress API: {progress_api}")
        print("   Read actions: " + ", ".join(actions))

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
        ) = choose_clean_pre_retry_backup(root, handler_setting)

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

            print("7. Testing Tim's English progress request...")
            validate_english(progress_api, actions, admin_password)

            print("8. Testing the 20-question Math correction...")
            run_math_retry_test(progress_api, admin_password)

            tests_passed = True

        except Exception:
            if deployed and not tests_passed:
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
    print(" SHARED ENGLISH/MATH API REPAIR PASSED")
    print("=" * 68)
    print()
    print("Verified:")
    print("  - Tim's English progress request is reachable.")
    print("  - Original English/student Lambda functions are preserved.")
    print("  - Math corrections still unlock after 20 unique attempts.")
    print("  - A corrected Math answer is saved as attempt 2.")
    print()
    print("No English HTML files or student progress records were changed.")
    print("Close the English tab completely and reopen the same Tim link.")


HELPERS_JS = "\n// BEGIN SHARED_PROGRESS_REPAIR_HELPERS\nconst SHARED_PROGRESS_REPAIR_BUILD = '__BUILD__';\nconst SAT_RETRY_MILESTONE_SIZE = 20;\n\nfunction satMathQuestionPosition(questionId) {\n  const id = String(questionId || '').trim();\n\n  let match = id.match(/^v([1-3])q(\\d{3})$/i);\n  if (match) {\n    return {\n      group: `v${match[1]}q`,\n      setNumber: 1,\n      volumeNumber: Number(match[1]),\n      questionNumber: Number(match[2]),\n      totalQuestions: 100\n    };\n  }\n\n  match = id.match(/^s(\\d+)v([1-3])q(\\d{3})$/i);\n  if (match) {\n    return {\n      group: `s${match[1]}v${match[2]}q`,\n      setNumber: Number(match[1]),\n      volumeNumber: Number(match[2]),\n      questionNumber: Number(match[3]),\n      totalQuestions: 100\n    };\n  }\n\n  return null;\n}\n\nfunction satProgressFirstTime(item) {\n  const time = Date.parse(\n    item?.firstAt ||\n    item?.lastAt ||\n    ''\n  );\n\n  return Number.isFinite(time)\n    ? time\n    : Number.MAX_SAFE_INTEGER;\n}\n\nfunction satNormalizeProgressItem(item) {\n  const attempted = Boolean(item?.lastResult);\n  const storedLocked =\n    typeof item?.locked === 'boolean'\n      ? item.locked\n      : attempted;\n  const storedCorrectionAllowed =\n    item?.correctionAllowed === true;\n\n  return {\n    ...item,\n    attempts: Number(\n      item?.attempts || (attempted ? 1 : 0)\n    ),\n    storedLocked,\n    storedCorrectionAllowed,\n    locked: storedLocked,\n    correctionAllowed:\n      attempted &&\n      item.lastResult === 'incorrect' &&\n      (\n        !storedLocked ||\n        storedCorrectionAllowed\n      )\n  };\n}\n\nfunction satDecorateProgressItems(rawItems) {\n  const items = (rawItems || []).map(\n    satNormalizeProgressItem\n  );\n  const grouped = new Map();\n\n  for (const item of items) {\n    const position =\n      satMathQuestionPosition(item.questionId);\n\n    if (!position) continue;\n\n    if (!grouped.has(position.group)) {\n      grouped.set(position.group, {\n        position,\n        items: []\n      });\n    }\n\n    grouped.get(position.group).items.push(item);\n  }\n\n  const retryPolicy = {};\n\n  for (const [group, value] of grouped.entries()) {\n    const sorted = [...value.items].sort(\n      (left, right) => {\n        const timeDifference =\n          satProgressFirstTime(left) -\n          satProgressFirstTime(right);\n\n        if (timeDifference !== 0) {\n          return timeDifference;\n        }\n\n        const leftNumber =\n          satMathQuestionPosition(\n            left.questionId\n          )?.questionNumber || 999;\n        const rightNumber =\n          satMathQuestionPosition(\n            right.questionId\n          )?.questionNumber || 999;\n\n        return leftNumber - rightNumber;\n      }\n    );\n\n    const attempted = sorted.length;\n    const milestoneUnlocked = Math.min(\n      value.position.totalQuestions,\n      Math.floor(\n        attempted / SAT_RETRY_MILESTONE_SIZE\n      ) * SAT_RETRY_MILESTONE_SIZE\n    );\n    const nextMilestone =\n      attempted >= value.position.totalQuestions\n        ? value.position.totalQuestions\n        : Math.min(\n            value.position.totalQuestions,\n            milestoneUnlocked +\n              SAT_RETRY_MILESTONE_SIZE\n          );\n\n    let retryAvailable = 0;\n\n    sorted.forEach((item, index) => {\n      const attemptRank = index + 1;\n      const incorrect =\n        item.lastResult === 'incorrect';\n      const administratorAllowed =\n        incorrect &&\n        (\n          item.storedLocked === false ||\n          item.storedCorrectionAllowed === true\n        );\n      const autoCorrectionAvailable =\n        incorrect &&\n        item.attempts === 1 &&\n        attemptRank <= milestoneUnlocked;\n      const correctionAllowed =\n        administratorAllowed ||\n        autoCorrectionAvailable;\n\n      item.attemptRank = attemptRank;\n      item.milestoneUnlocked =\n        milestoneUnlocked;\n      item.nextMilestone = nextMilestone;\n      item.attemptsToNext = Math.max(\n        0,\n        nextMilestone - attempted\n      );\n      item.autoCorrectionAvailable =\n        autoCorrectionAvailable;\n      item.correctionAllowed =\n        correctionAllowed;\n      item.correctionSource =\n        administratorAllowed\n          ? 'administrator'\n          : autoCorrectionAvailable\n            ? 'milestone'\n            : null;\n      item.locked =\n        item.lastResult === 'correct'\n          ? true\n          : incorrect\n            ? !correctionAllowed\n            : false;\n\n      if (correctionAllowed) {\n        retryAvailable += 1;\n      }\n    });\n\n    retryPolicy[group] = {\n      setNumber: value.position.setNumber,\n      volumeNumber:\n        value.position.volumeNumber,\n      totalQuestions:\n        value.position.totalQuestions,\n      attempted,\n      milestoneUnlocked,\n      nextMilestone,\n      attemptsToNext: Math.max(\n        0,\n        nextMilestone - attempted\n      ),\n      retryAvailable\n    };\n  }\n\n  return {\n    items,\n    retryPolicy\n  };\n}\n\nasync function satQueryAllProgress(userId) {\n  const result = await ddb.send(\n    new QueryCommand({\n      TableName: TABLE,\n      KeyConditionExpression:\n        'userId = :userId',\n      ExpressionAttributeValues: {\n        ':userId': userId\n      },\n      ConsistentRead: true\n    })\n  );\n\n  return result.Items || [];\n}\n\nasync function satQueryVolumeProgress(\n  userId,\n  group\n) {\n  const result = await ddb.send(\n    new QueryCommand({\n      TableName: TABLE,\n      KeyConditionExpression:\n        'userId = :userId AND ' +\n        'begins_with(questionId, :group)',\n      ExpressionAttributeValues: {\n        ':userId': userId,\n        ':group': group\n      },\n      ConsistentRead: true\n    })\n  );\n\n  return result.Items || [];\n}\n\nasync function satGetProgressItem(\n  userId,\n  questionId\n) {\n  const result = await ddb.send(\n    new GetCommand({\n      TableName: TABLE,\n      Key: {\n        userId,\n        questionId\n      },\n      ConsistentRead: true\n    })\n  );\n\n  return result.Item || null;\n}\n\nasync function satIsAutomaticCorrectionAvailable(\n  userId,\n  questionId\n) {\n  const position =\n    satMathQuestionPosition(questionId);\n\n  if (!position) return false;\n\n  const rawItems =\n    await satQueryVolumeProgress(\n      userId,\n      position.group\n    );\n\n  const item =\n    satDecorateProgressItems(rawItems)\n      .items\n      .find(\n        candidate =>\n          candidate.questionId === questionId\n      );\n\n  return Boolean(\n    item?.autoCorrectionAvailable\n  );\n}\n\nasync function satDecorateSavedProgressItem(\n  userId,\n  savedItem\n) {\n  const position =\n    satMathQuestionPosition(\n      savedItem?.questionId\n    );\n\n  if (!position) {\n    return satNormalizeProgressItem(\n      savedItem\n    );\n  }\n\n  const rawItems =\n    await satQueryVolumeProgress(\n      userId,\n      position.group\n    );\n\n  return (\n    satDecorateProgressItems(rawItems)\n      .items\n      .find(\n        candidate =>\n          candidate.questionId ===\n          savedItem.questionId\n      ) ||\n    satNormalizeProgressItem(savedItem)\n  );\n}\n// END SHARED_PROGRESS_REPAIR_HELPERS\n"

RECORD_JS = "\nasync function recordAttempt({\n  userId,\n  questionId,\n  correct,\n  choice,\n  category\n}) {\n  const validQuestionId =\n    requireQuestionId(questionId);\n  const now = new Date().toISOString();\n  const existing =\n    await satGetProgressItem(\n      userId,\n      validQuestionId\n    );\n\n  let attemptMode = 'first';\n\n  if (existing) {\n    const attempts = Number(\n      existing.attempts || 1\n    );\n\n    if (\n      existing.lastResult === 'correct'\n    ) {\n      throw new HttpError(\n        409,\n        'QUESTION_LOCKED',\n        'This question has already been completed'\n      );\n    }\n\n    if (existing.locked === false) {\n      attemptMode = 'administrator';\n    } else if (\n      attempts === 1 &&\n      await satIsAutomaticCorrectionAvailable(\n        userId,\n        validQuestionId\n      )\n    ) {\n      attemptMode = 'milestone';\n    } else {\n      throw new HttpError(\n        409,\n        'QUESTION_LOCKED',\n        attempts > 1\n          ? 'The correction attempt is complete; administrator approval is required'\n          : 'This question is locked until its 20-question correction milestone'\n      );\n    }\n  }\n\n  const names = {\n    '#attempts': 'attempts',\n    '#correctCount': 'correctCount',\n    '#lastResult': 'lastResult',\n    '#lastChoice': 'lastChoice',\n    '#lastAt': 'lastAt',\n    '#category': 'category',\n    '#firstAt': 'firstAt',\n    '#locked': 'locked',\n    '#correctionAllowed':\n      'correctionAllowed',\n    '#lastAttemptType':\n      'lastAttemptType'\n  };\n\n  const values = {\n    ':zero': 0,\n    ':one': 1,\n    ':correctIncrement':\n      correct ? 1 : 0,\n    ':result':\n      correct ? 'correct' : 'incorrect',\n    ':incorrect': 'incorrect',\n    ':choice': choice ?? null,\n    ':now': now,\n    ':category':\n      category ?? 'unknown',\n    ':true': true,\n    ':false': false,\n    ':attemptMode': attemptMode\n  };\n\n  let updateExpression;\n  let conditionExpression;\n\n  if (attemptMode === 'first') {\n    updateExpression =\n      'ADD #attempts :one, ' +\n      '#correctCount :correctIncrement ' +\n      'SET #lastResult = :result, ' +\n      '#lastChoice = :choice, ' +\n      '#lastAt = :now, ' +\n      '#category = :category, ' +\n      '#firstAt = if_not_exists(' +\n      '#firstAt, :now), ' +\n      '#locked = :true, ' +\n      '#correctionAllowed = :false, ' +\n      '#lastAttemptType = :attemptMode';\n\n    conditionExpression =\n      'attribute_not_exists(#lastResult)';\n  } else {\n    updateExpression =\n      'SET #attempts = ' +\n      'if_not_exists(#attempts, :one) + :one, ' +\n      '#correctCount = ' +\n      'if_not_exists(#correctCount, :zero) + ' +\n      ':correctIncrement, ' +\n      '#lastResult = :result, ' +\n      '#lastChoice = :choice, ' +\n      '#lastAt = :now, ' +\n      '#category = :category, ' +\n      '#firstAt = if_not_exists(' +\n      '#firstAt, :now), ' +\n      '#locked = :true, ' +\n      '#correctionAllowed = :false, ' +\n      '#lastAttemptType = :attemptMode';\n\n    conditionExpression =\n      attemptMode === 'administrator'\n        ? '#lastResult = :incorrect AND ' +\n          '#locked = :false'\n        : '#lastResult = :incorrect AND ' +\n          '(attribute_not_exists(#attempts) ' +\n          'OR #attempts = :one)';\n  }\n\n  try {\n    const result = await ddb.send(\n      new UpdateCommand({\n        TableName: TABLE,\n        Key: {\n          userId,\n          questionId: validQuestionId\n        },\n        UpdateExpression:\n          updateExpression,\n        ConditionExpression:\n          conditionExpression,\n        ExpressionAttributeNames:\n          names,\n        ExpressionAttributeValues:\n          values,\n        ReturnValues: 'ALL_NEW'\n      })\n    );\n\n    return satDecorateSavedProgressItem(\n      userId,\n      result.Attributes\n    );\n  } catch (error) {\n    if (\n      error?.name ===\n      'ConditionalCheckFailedException'\n    ) {\n      throw new HttpError(\n        409,\n        'QUESTION_LOCKED',\n        'This question is no longer available for another attempt'\n      );\n    }\n\n    throw error;\n  }\n}\n"

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
