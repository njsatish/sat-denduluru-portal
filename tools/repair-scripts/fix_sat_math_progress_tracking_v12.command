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
import urllib.request
from pathlib import Path

PROFILE = "denduluru"
EXPECTED_ACCOUNT = "989174615155"
REGION = "us-east-1"
BUCKET = "sat-prep-josh"
SITE_ALIAS = "sat.denduluru.com"
SITE_ORIGIN = "https://sat.denduluru.com"
APP_KEY = "math/app.js"
TABLE_NAME = "sat-progress"
PROBE_STUDENT = "josh"
TEST_USER = f"mathtrack{int(time.time())}{os.getpid()}"
TEST_QUESTION = "v1q001"

STAMP = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
BUILD = f"20260805-math-progress-v12-{STAMP}"
BACKUP_PREFIX = f"backups/math-progress-v12-{STAMP}"
AWS_BASE = ["aws", "--profile", PROFILE, "--region", REGION]

IDENTITY_START = "/* BEGIN SAT MATH IDENTITY V12 */"
IDENTITY_END = "/* END SAT MATH IDENTITY V12 */"


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
        details = (result.stderr or "").strip()
        raise RepairError(
            f"Command failed ({result.returncode}): {' '.join(map(str, args))}"
            + (f"\n{details}" if details else "")
        )
    return (result.stdout or "").strip() if capture else ""


def aws(*args, capture=False, check=True):
    return run(AWS_BASE + list(args), capture=capture, check=check)


def require_commands():
    missing = [name for name in ("aws", "python3", "node") if not shutil.which(name)]
    if missing:
        raise RepairError("Missing required command(s): " + ", ".join(missing))


def normalize_url(value):
    value = str(value or "").strip()
    if not value or value in {"None", "null"}:
        return ""
    return value if value.endswith("/") else value + "/"


def read_s3_text(key):
    return aws(
        "s3", "cp", f"s3://{BUCKET}/{key}", "-",
        "--only-show-errors", capture=True,
    )


def extract_math_url(text):
    match = re.search(
        r"""const\s+PROGRESS_API\s*=\s*['\"]([^'\"]+)['\"]""",
        text,
    )
    if not match:
        raise RepairError("PROGRESS_API was not found in live math/app.js.")
    return normalize_url(match.group(1))


def extract_function_urls(text):
    return list(dict.fromkeys(
        normalize_url(value)
        for value in re.findall(
            r"https://[A-Za-z0-9-]+\.lambda-url\.[A-Za-z0-9-]+\.on\.aws/?",
            text,
        )
        if normalize_url(value)
    ))


def cloudfront_distribution():
    value = aws(
        "cloudfront", "list-distributions",
        "--query",
        f"DistributionList.Items[?Aliases.Quantity > `0` && contains(Aliases.Items, '{SITE_ALIAS}')].Id | [0]",
        "--output", "text",
        capture=True,
    )
    if not value or value == "None":
        raise RepairError(f"CloudFront distribution for {SITE_ALIAS} was not found.")
    return value


def get_url_config(function_name, qualifier=None):
    args = [
        "lambda", "get-function-url-config",
        "--function-name", function_name,
        "--output", "json",
    ]
    if qualifier:
        args.extend(["--qualifier", qualifier])
    raw = aws(*args, capture=True, check=False)
    if not raw:
        return None
    try:
        config = json.loads(raw)
    except json.JSONDecodeError:
        return None
    url = normalize_url(config.get("FunctionUrl"))
    if not url:
        return None
    return {
        "function_name": function_name,
        "qualifier": qualifier,
        "url": url,
        "config": config,
    }


def enumerate_function_urls():
    raw = aws(
        "lambda", "list-functions",
        "--output", "json",
        capture=True,
    )
    functions = json.loads(raw).get("Functions", [])
    targets = []

    for item in functions:
        name = item.get("FunctionName")
        if not name:
            continue

        base = get_url_config(name)
        if base:
            targets.append(base)

        aliases_raw = aws(
            "lambda", "list-aliases",
            "--function-name", name,
            "--output", "json",
            capture=True,
            check=False,
        )
        if not aliases_raw:
            continue
        try:
            aliases = json.loads(aliases_raw).get("Aliases", [])
        except json.JSONDecodeError:
            aliases = []

        for alias in aliases:
            qualifier = alias.get("Name")
            if not qualifier:
                continue
            target = get_url_config(name, qualifier)
            if target:
                targets.append(target)

    unique = []
    seen = set()
    for target in targets:
        key = (
            target["function_name"],
            target.get("qualifier") or "",
            target["url"],
        )
        if key not in seen:
            seen.add(key)
            unique.append(target)
    return unique


def target_label(target):
    qualifier = target.get("qualifier")
    return target["function_name"] + (f":{qualifier}" if qualifier else "")


def target_args(target):
    args = ["--function-name", target["function_name"]]
    if target.get("qualifier"):
        args.extend(["--qualifier", target["qualifier"]])
    return args


def request(url, *, method, headers=None, payload=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers=headers or {},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return (
                response.status,
                dict(response.headers.items()),
                response.read().decode("utf-8", errors="replace"),
            )
    except urllib.error.HTTPError as error:
        return (
            error.code,
            dict(error.headers.items()),
            error.read().decode("utf-8", errors="replace"),
        )
    except OSError as error:
        return 0, {}, str(error)


def parse_json(body):
    try:
        return json.loads(body or "{}")
    except json.JSONDecodeError:
        return None


def direct_post(url, payload):
    return request(
        url,
        method="POST",
        headers={"Content-Type": "application/json"},
        payload=payload,
    )


def probe_math_actions(url):
    status, _headers, body = direct_post(
        url,
        {"action": "getStudent", "userId": PROBE_STUDENT},
    )
    student_payload = parse_json(body)
    if status != 200 or not isinstance(student_payload, dict):
        return False, f"getStudent HTTP {status}: {body[:180]}"
    if not student_payload.get("student"):
        return False, f"getStudent returned no student: {body[:180]}"

    status, _headers, body = direct_post(
        url,
        {"action": "progress", "userId": PROBE_STUDENT},
    )
    progress_payload = parse_json(body)
    if status != 200 or not isinstance(progress_payload, dict):
        return False, f"progress HTTP {status}: {body[:180]}"
    if not isinstance(progress_payload.get("items", []), list):
        return False, f"progress returned unexpected JSON: {body[:180]}"

    return True, "getStudent and progress are supported"


def candidate_urls_from_site(math_url):
    urls = [math_url]
    for key in (
        "english/english-progress.js",
        "english/english-student.js",
        "english/SAT_Words_101_125.html",
    ):
        try:
            text = read_s3_text(key)
        except RepairError:
            continue
        urls.extend(extract_function_urls(text))
    return list(dict.fromkeys(urls))


def select_math_target(math_url, targets):
    by_url = {}
    for target in targets:
        by_url.setdefault(target["url"], []).append(target)

    preferred_urls = candidate_urls_from_site(math_url)
    ordered_targets = []
    seen = set()

    for url in preferred_urls:
        for target in by_url.get(url, []):
            key = (target["function_name"], target.get("qualifier") or "")
            if key not in seen:
                seen.add(key)
                ordered_targets.append(target)

    for target in targets:
        key = (target["function_name"], target.get("qualifier") or "")
        if key not in seen:
            seen.add(key)
            ordered_targets.append(target)

    failures = []
    for target in ordered_targets:
        print(f"   Probing {target_label(target)} → {target['url']}")
        ok, detail = probe_math_actions(target["url"])
        if ok:
            print(f"   PASS: {detail}.")
            return target
        failures.append(f"{target_label(target)}: {detail}")
        print(f"   SKIP: {detail}")

    detail = "\n".join(failures[:12])
    raise RepairError(
        "No account-owned Function URL supports the required Math actions."
        + (f"\n{detail}" if detail else "")
    )


def get_function_configuration(target):
    args = [
        "lambda", "get-function-configuration",
        *target_args(target),
        "--output", "json",
    ]
    return json.loads(aws(*args, capture=True))


def get_policy(target):
    args = ["lambda", "get-policy", *target_args(target), "--output", "json"]
    raw = aws(*args, capture=True, check=False)
    if not raw:
        return {"Version": "2012-10-17", "Statement": []}
    outer = json.loads(raw)
    policy = outer.get("Policy")
    return json.loads(policy) if isinstance(policy, str) else (policy or {})


def principal_is_public(principal):
    if principal == "*":
        return True
    if isinstance(principal, dict):
        for value in principal.values():
            if value == "*" or (isinstance(value, list) and "*" in value):
                return True
    return False


def statement_actions(statement):
    actions = statement.get("Action", [])
    return [actions] if isinstance(actions, str) else list(actions)


def statement_applies_to(statement, target_arn):
    resource = statement.get("Resource")
    if resource == "*" or resource == target_arn:
        return True
    if isinstance(resource, list):
        return "*" in resource or target_arn in resource
    return False


def has_public_permission(policy, action, target_arn, condition_marker):
    for statement in policy.get("Statement", []):
        if statement.get("Effect") != "Allow":
            continue
        if not principal_is_public(statement.get("Principal")):
            continue
        actions = statement_actions(statement)
        if action not in actions and "lambda:*" not in actions and "*" not in actions:
            continue
        if not statement_applies_to(statement, target_arn):
            continue
        condition_text = json.dumps(statement.get("Condition", {})).lower()
        if condition_marker.lower() in condition_text or not statement.get("Condition"):
            return True
    return False


def add_missing_permissions(target, target_arn):
    added = []
    policy = get_policy(target)
    checks = (
        (
            "lambda:InvokeFunctionUrl",
            "functionurlauthtype",
            ["--function-url-auth-type", "NONE"],
            "SatMathPublicUrlV10",
        ),
        (
            "lambda:InvokeFunction",
            "invokedviafunctionurl",
            ["--invoked-via-function-url"],
            "SatMathPublicInvokeV10",
        ),
    )

    for action, marker, extras, prefix in checks:
        if has_public_permission(policy, action, target_arn, marker):
            print(f"   PASS: {action} permission already exists.")
            continue

        sid = f"{prefix}{int(time.time())}{len(added)}"
        args = [
            "lambda", "add-permission",
            *target_args(target),
            "--statement-id", sid,
            "--action", action,
            "--principal", "*",
            *extras,
            "--output", "json",
        ]
        aws(*args, capture=True)
        added.append(sid)
        print(f"   Added {action} permission.")
        policy = get_policy(target)

    return added


def remove_permissions(target, statement_ids):
    for sid in statement_ids:
        aws(
            "lambda", "remove-permission",
            *target_args(target),
            "--statement-id", sid,
            check=False,
        )


def header(headers, name):
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return ""


def verify_preflight(url):
    status, headers, body = request(
        url,
        method="OPTIONS",
        headers={
            "Origin": SITE_ORIGIN,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type,cache-control,pragma",
        },
    )
    allow_origin = header(headers, "Access-Control-Allow-Origin")
    allow_methods = header(headers, "Access-Control-Allow-Methods").upper()
    allow_headers = header(headers, "Access-Control-Allow-Headers").lower()

    if status not in (200, 204):
        raise RepairError(f"Math CORS preflight returned HTTP {status}: {body}")
    if allow_origin not in (SITE_ORIGIN, "*"):
        raise RepairError(f"Math CORS origin is invalid: {allow_origin!r}")
    if "POST" not in allow_methods and "*" not in allow_methods:
        raise RepairError(f"Math CORS does not allow POST: {allow_methods!r}")
    for required in ("content-type", "cache-control", "pragma"):
        if required not in allow_headers and "*" not in allow_headers:
            raise RepairError(
                f"Math CORS does not allow {required}: {allow_headers!r}"
            )


def browser_post(url, payload, expected=(200, 201)):
    status, headers, body = request(
        url,
        method="POST",
        headers={
            "Origin": SITE_ORIGIN,
            "Content-Type": "application/json",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
        payload=payload,
    )
    allow_origin = header(headers, "Access-Control-Allow-Origin")
    if allow_origin not in (SITE_ORIGIN, "*"):
        raise RepairError(
            "Math POST response is missing the website CORS origin. "
            f"HTTP {status}; origin={allow_origin!r}; body={body}"
        )
    if status not in expected:
        raise RepairError(f"Math API returned HTTP {status}: {body}")
    payload_json = parse_json(body)
    if not isinstance(payload_json, dict):
        raise RepairError(f"Math API returned invalid JSON: {body}")
    return payload_json


def cleanup_test_records():
    requests = [
        {
            "DeleteRequest": {
                "Key": {
                    "userId": {"S": TEST_USER},
                    "questionId": {"S": TEST_QUESTION},
                }
            }
        },
        {
            "DeleteRequest": {
                "Key": {
                    "userId": {"S": "__students__"},
                    "questionId": {"S": f"student#{TEST_USER}"},
                }
            }
        },
    ]

    with tempfile.NamedTemporaryFile(
        "w", suffix=".json", delete=False, encoding="utf-8"
    ) as file:
        json.dump({TABLE_NAME: requests}, file)
        request_path = file.name

    try:
        aws(
            "dynamodb", "batch-write-item",
            "--request-items", f"file://{request_path}",
            capture=True,
            check=False,
        )
    finally:
        Path(request_path).unlink(missing_ok=True)


def test_real_math_tracking(url, admin_password):
    cleanup_test_records()

    browser_post(
        url,
        {
            "action": "createStudent",
            "adminPassword": admin_password,
            "displayName": "Math Tracking Verification",
            "requestedStudentId": TEST_USER,
        },
    )

    student = browser_post(
        url,
        {"action": "getStudent", "userId": TEST_USER},
    )
    if not student.get("student"):
        raise RepairError(f"getStudent did not return the temporary student: {student}")

    saved = browser_post(
        url,
        {
            "action": "record",
            "userId": TEST_USER,
            "questionId": TEST_QUESTION,
            "correct": True,
            "choice": "tracking-test-answer",
            "category": "math-tracking-verification",
        },
    )
    if saved.get("questionId") != TEST_QUESTION:
        raise RepairError(f"record did not confirm {TEST_QUESTION}: {saved}")
    if saved.get("lastResult") != "correct":
        raise RepairError(f"record did not confirm a correct result: {saved}")

    progress = browser_post(
        url,
        {"action": "progress", "userId": TEST_USER},
    )
    item = next(
        (
            value
            for value in progress.get("items", [])
            if value.get("questionId") == TEST_QUESTION
        ),
        None,
    )
    if not item:
        raise RepairError("The saved Math answer was not returned by progress.")
    if item.get("lastResult") != "correct":
        raise RepairError(f"The read-back result was not correct: {item}")
    if item.get("lastChoice") != "tracking-test-answer":
        raise RepairError(f"The read-back choice was not preserved: {item}")

    cleanup_test_records()


IDENTITY_JS = r'''/* BEGIN SAT MATH IDENTITY V12 */
const SAT_MATH_IDENTITY_BUILD = '__BUILD__';

function decodeSatMathTokenV12(token) {
  try {
    const part = String(token || '').split('.')[1];
    if (!part) return null;
    const base64 = part.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64 + '='.repeat((4 - base64.length % 4) % 4);
    const binary = atob(padded);
    const bytes = Uint8Array.from(
      binary,
      character => character.charCodeAt(0)
    );
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch (error) {
    console.warn('Unable to decode SAT Math identity.', error);
    return null;
  }
}

function resolveMathStudentId(primaryStudentId = '') {
  const params = new URLSearchParams(location.search);
  const tokenClaims = decodeSatMathTokenV12(
    sessionStorage.getItem('sat_id_token') ||
    localStorage.getItem('sat_id_token')
  );

  const primary = normalizeStudentId(primaryStudentId);
  const authenticated = normalizeStudentId(
    window.SATAuth?.studentId ||
    window.SATAuth?.username ||
    tokenClaims?.['cognito:username'] ||
    tokenClaims?.username ||
    tokenClaims?.preferred_username
  );
  const fromUrl = normalizeStudentId(params.get('student'));
  const stored = normalizeStudentId(localStorage.getItem('sat_user'));
  const studentId = primary || authenticated || fromUrl || stored;

  if (studentId) localStorage.setItem('sat_user', studentId);
  return studentId;
}
/* END SAT MATH IDENTITY V12 */'''



def remove_marked_block(text, start, end):
    if start not in text or end not in text:
        return text
    return re.sub(
        re.escape(start) + r"[\s\S]*?" + re.escape(end) + r"\s*",
        "",
        text,
        count=1,
    )


def find_declared_function_span(text, function_name):
    pattern = re.compile(
        rf"(?:async\s+)?function\s+{re.escape(function_name)}\s*\([^)]*\)\s*\{{"
    )
    match = pattern.search(text)
    if not match:
        return None

    opening = text.find("{", match.start(), match.end())
    if opening < 0:
        return None

    depth = 0
    quote = None
    escaped = False
    line_comment = False
    block_comment = False
    index = opening

    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""

        if line_comment:
            if char in "\r\n":
                line_comment = False
            index += 1
            continue

        if block_comment:
            if char == "*" and next_char == "/":
                block_comment = False
                index += 2
            else:
                index += 1
            continue

        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue

        if char == "/" and next_char == "/":
            line_comment = True
            index += 2
            continue
        if char == "/" and next_char == "*":
            block_comment = True
            index += 2
            continue
        if char in ("'", '"', "`"):
            quote = char
            index += 1
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return match.start(), index + 1
        index += 1

    return None


def patch_math_app(text, selected_url):
    for start, end in (
        (IDENTITY_START, IDENTITY_END),
        ("/* BEGIN SAT MATH IDENTITY V11 */", "/* END SAT MATH IDENTITY V11 */"),
        ("/* BEGIN SAT MATH IDENTITY V10 */", "/* END SAT MATH IDENTITY V10 */"),
        ("/* BEGIN SAT MATH IDENTITY V9 */", "/* END SAT MATH IDENTITY V9 */"),
    ):
        text = remove_marked_block(text, start, end)

    text, api_count = re.subn(
        r"""const\s+PROGRESS_API\s*=\s*['\"][^'\"]+['\"]\s*;""",
        f"const PROGRESS_API = {json.dumps(selected_url)};",
        text,
        count=1,
    )
    if api_count != 1:
        raise RepairError("The Math PROGRESS_API constant could not be updated.")

    normalize_span = find_declared_function_span(text, "normalizeStudentId")
    if not normalize_span:
        raise RepairError("normalizeStudentId was not found in live math/app.js.")

    identity = IDENTITY_JS.replace("__BUILD__", BUILD)
    insertion_point = normalize_span[1]
    text = (
        text[:insertion_point]
        + "\n\n"
        + identity
        + text[insertion_point:]
    )

    # Patch only inside prepareStudentPage so helper-local studentId variables
    # cannot be mistaken for the page's actual initialization.
    prepare_span = find_declared_function_span(text, "prepareStudentPage")
    if not prepare_span:
        raise RepairError("prepareStudentPage was not found in live math/app.js.")

    prepare_start, prepare_end = prepare_span
    prepare_text = text[prepare_start:prepare_end]
    assignment_pattern = re.compile(
        r"(?P<prefix>\b(?:const|let|var)\s+studentId\s*=\s*)"
        r"(?P<rhs>[^;]+)"
        r"(?P<suffix>\s*;)"
    )
    assignment_match = assignment_pattern.search(prepare_text)

    if not assignment_match:
        diagnostic = " | ".join(
            line.strip()
            for line in prepare_text.splitlines()
            if "student" in line.lower()
        )[:1200]
        raise RepairError(
            "The studentId assignment inside prepareStudentPage was not found. "
            f"Live-code diagnostic: {diagnostic or 'no student-related lines found'}"
        )

    original_rhs = assignment_match.group("rhs").strip()
    if "resolveMathStudentId" not in original_rhs:
        replacement = (
            assignment_match.group("prefix")
            + f"resolveMathStudentId({original_rhs})"
            + assignment_match.group("suffix")
        )
        prepare_text = (
            prepare_text[:assignment_match.start()]
            + replacement
            + prepare_text[assignment_match.end():]
        )
        text = text[:prepare_start] + prepare_text + text[prepare_end:]

    if (
        "console.warn('cloud sync failed', error);" in text
        and "sat-math-progress-sync-error" not in text
    ):
        text = text.replace(
            "console.warn('cloud sync failed', error);",
            """console.warn('cloud sync failed', error);
    window.dispatchEvent(new CustomEvent('sat-math-progress-sync-error', {
      detail: {
        studentId: getUser(),
        error: String(error?.message || error)
      }
    }));""",
            1,
        )

    updated_prepare_span = find_declared_function_span(text, "prepareStudentPage")
    updated_prepare = (
        text[updated_prepare_span[0]:updated_prepare_span[1]]
        if updated_prepare_span
        else ""
    )

    for marker in (
        IDENTITY_START,
        "resolveMathStudentId",
        selected_url,
    ):
        if marker not in text:
            raise RepairError(f"Patched math/app.js is missing: {marker}")

    if not re.search(
        r"\b(?:const|let|var)\s+studentId\s*=\s*"
        r"resolveMathStudentId\s*\(",
        updated_prepare,
    ):
        raise RepairError(
            "prepareStudentPage does not use the Math identity resolver after patching."
        )

    return text

def patch_html(text):
    text, count = re.subn(
        r"""(<script\b[^>]*\bsrc=['\"](?:\./)?app\.js)(?:\?[^'\"]*)?(['\"][^>]*></script>)""",
        rf"\1?v={BUILD}\2",
        text,
        count=1,
        flags=re.IGNORECASE,
    )
    if count != 1:
        raise RepairError("An app.js reference was not found in a Math HTML page.")
    return text


def backup_key(key):
    aws(
        "s3", "cp",
        f"s3://{BUCKET}/{key}",
        f"s3://{BUCKET}/{BACKUP_PREFIX}/{key}",
        "--only-show-errors",
    )


def restore_keys(keys):
    for key in keys:
        aws(
            "s3", "cp",
            f"s3://{BUCKET}/{BACKUP_PREFIX}/{key}",
            f"s3://{BUCKET}/{key}",
            "--only-show-errors",
            check=False,
        )


def invalidate(distribution):
    invalidation_id = aws(
        "cloudfront", "create-invalidation",
        "--distribution-id", distribution,
        "--paths", "/math/*",
        "--query", "Invalidation.Id",
        "--output", "text",
        capture=True,
    )
    aws(
        "cloudfront", "wait", "invalidation-completed",
        "--distribution-id", distribution,
        "--id", invalidation_id,
    )


def restore_url_config(target, original_config):
    args = [
        "lambda", "update-function-url-config",
        *target_args(target),
        "--auth-type", original_config.get("AuthType", "NONE"),
    ]
    if "Cors" in original_config:
        args.extend([
            "--cors",
            json.dumps(original_config["Cors"], separators=(",", ":")),
        ])
    aws(*args, capture=True, check=False)


def main():
    require_commands()

    account = aws(
        "sts", "get-caller-identity",
        "--query", "Account",
        "--output", "text",
        capture=True,
    )
    if account != EXPECTED_ACCOUNT:
        raise RepairError(
            f"Expected AWS account {EXPECTED_ACCOUNT}, but found {account}."
        )

    distribution = cloudfront_distribution()

    print("=" * 72)
    print(" SAT Math progress tracking repair v12")
    print("=" * 72)
    print(f"AWS account:   {account}")
    print(f"Distribution:  {distribution}")
    print(f"Build:         {BUILD}")
    print()

    selected_target = None
    original_url_config = None
    added_permissions = []
    uploaded_keys = []
    frontend_started = False

    try:
        with tempfile.TemporaryDirectory(prefix="sat-math-progress-v12-") as temp_name:
            root = Path(temp_name)
            live_root = root / "live"
            patched_root = root / "patched"
            (live_root / "math").mkdir(parents=True)
            (patched_root / "math").mkdir(parents=True)

            print("1. Downloading live Math files...")
            aws(
                "s3", "sync",
                f"s3://{BUCKET}/math",
                str(live_root / "math"),
                "--exclude", "*",
                "--include", "*.html",
                "--include", "app.js",
                "--only-show-errors",
            )

            app_path = live_root / APP_KEY
            if not app_path.exists():
                raise RepairError("math/app.js was not downloaded.")
            html_paths = sorted((live_root / "math").glob("*.html"))
            if not html_paths:
                raise RepairError("No Math HTML pages were downloaded.")

            live_app = app_path.read_text(encoding="utf-8")
            old_math_url = extract_math_url(live_app)
            print(f"   Current Math API: {old_math_url}")
            print(f"   Math HTML pages:  {len(html_paths)}")

            print("2. Enumerating base and alias Lambda Function URLs...")
            targets = enumerate_function_urls()
            if not targets:
                raise RepairError("No Lambda Function URLs were found in the AWS account.")
            print(f"   Found {len(targets)} Function URL configuration(s).")

            exact_matches = [
                target for target in targets
                if target["url"] == old_math_url
            ]
            if exact_matches:
                print(
                    "   Current URL belongs to: "
                    + ", ".join(target_label(target) for target in exact_matches)
                )
            else:
                print("   WARNING: the current Math URL is stale or no longer account-owned.")

            print("3. Selecting an account-owned API that supports Math tracking...")
            selected_target = select_math_target(old_math_url, targets)
            selected_url = selected_target["url"]
            print(f"   Selected Lambda: {target_label(selected_target)}")
            print(f"   Selected URL:    {selected_url}")
            if selected_url != old_math_url:
                print("   Math will be switched from the stale URL to this verified shared API.")

            configuration = get_function_configuration(selected_target)
            target_arn = configuration.get("FunctionArn")
            if not target_arn:
                raise RepairError("The selected Lambda FunctionArn was not returned.")
            admin_password = (
                configuration
                .get("Environment", {})
                .get("Variables", {})
                .get("ADMIN_PASSWORD")
            )
            if not admin_password:
                raise RepairError("ADMIN_PASSWORD is not configured on the selected Lambda.")

            original_url_config = selected_target["config"]
            config_backup = root / "selected-function-url-before.json"
            config_backup.write_text(
                json.dumps(original_url_config, indent=2) + "\n",
                encoding="utf-8",
            )
            aws(
                "s3", "cp",
                str(config_backup),
                f"s3://{BUCKET}/{BACKUP_PREFIX}/selected-function-url-before.json",
                "--only-show-errors",
            )

            print("4. Configuring and testing browser access...")
            cors = {
                "AllowCredentials": False,
                "AllowHeaders": [
                    "content-type",
                    "authorization",
                    "cache-control",
                    "pragma",
                ],
                "AllowMethods": ["POST", "GET"],
                "AllowOrigins": [SITE_ORIGIN],
                "ExposeHeaders": ["content-type"],
                "MaxAge": 86400,
            }
            aws(
                "lambda", "update-function-url-config",
                *target_args(selected_target),
                "--auth-type", "NONE",
                "--cors", json.dumps(cors, separators=(",", ":")),
                "--output", "json",
                capture=True,
            )
            added_permissions = add_missing_permissions(
                selected_target,
                target_arn,
            )
            time.sleep(2)
            verify_preflight(selected_url)
            print("   PASS: browser OPTIONS preflight succeeds.")

            print("5. Testing a real Math answer write and read-back...")
            test_real_math_tracking(selected_url, admin_password)
            print("   PASS: record → DynamoDB → progress read-back succeeds.")

            print("6. Updating Math API and student identity resolution...")
            patched_app_path = patched_root / APP_KEY
            patched_app_path.parent.mkdir(parents=True, exist_ok=True)
            patched_app_path.write_text(
                patch_math_app(live_app, selected_url),
                encoding="utf-8",
            )
            run(["node", "--check", str(patched_app_path)])
            print("   PASS: patched math/app.js syntax is valid.")

            for source in html_paths:
                relative = source.relative_to(live_root)
                destination = patched_root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(
                    patch_html(source.read_text(encoding="utf-8")),
                    encoding="utf-8",
                )

            changed_keys = [APP_KEY] + [
                path.relative_to(live_root).as_posix()
                for path in html_paths
            ]

            print(f"7. Backing up and deploying {len(changed_keys)} Math files...")
            for key in changed_keys:
                backup_key(key)

            frontend_started = True
            for key in changed_keys:
                source = patched_root / key
                content_type = (
                    "application/javascript; charset=utf-8"
                    if source.suffix.lower() == ".js"
                    else "text/html; charset=utf-8"
                )
                aws(
                    "s3", "cp",
                    str(source),
                    f"s3://{BUCKET}/{key}",
                    "--content-type", content_type,
                    "--cache-control", "no-cache, no-store, must-revalidate",
                    "--only-show-errors",
                )
                uploaded_keys.append(key)

            print("8. Invalidating CloudFront and verifying deployment...")
            invalidate(distribution)

            deployed_app = read_s3_text(APP_KEY)
            if IDENTITY_START not in deployed_app:
                raise RepairError("The deployed Math identity patch is missing.")
            if selected_url not in deployed_app:
                raise RepairError("The deployed Math API URL was not updated.")
            if not (
                "return resolveMathStudentId();" in deployed_app
                or re.search(
                    r"\b(?:const|let|var)\s+studentId\s*=\s*"
                    r"resolveMathStudentId\s*\(\s*\)",
                    deployed_app,
                )
            ):
                raise RepairError("The deployed Math student resolver is missing.")

            sample_key = html_paths[0].relative_to(live_root).as_posix()
            deployed_html = read_s3_text(sample_key)
            if f"app.js?v={BUILD}" not in deployed_html:
                raise RepairError(
                    f"The cache-busted app.js reference is missing from {sample_key}."
                )

            print("9. Re-testing Math tracking after frontend deployment...")
            test_real_math_tracking(selected_url, admin_password)
            print("   PASS: post-deployment Math tracking succeeds.")

    except Exception:
        cleanup_test_records()

        if frontend_started and uploaded_keys:
            print()
            print("Verification failed. Restoring the previous Math frontend...")
            restore_keys(uploaded_keys)
            invalidate(distribution)

        if selected_target and original_url_config:
            print("Restoring the selected Function URL configuration...")
            restore_url_config(selected_target, original_url_config)

        if selected_target and added_permissions:
            remove_permissions(selected_target, added_permissions)

        raise
    finally:
        cleanup_test_records()

    print()
    print("=" * 72)
    print(" SAT MATH PROGRESS TRACKING REPAIR V12 PASSED")
    print("=" * 72)
    print()
    print("Verified:")
    print("  - Stale Function URL detection and alias-aware Lambda discovery.")
    print("  - The selected account-owned API supports Math actions.")
    print("  - A real Math answer saves and is returned by progress.")
    print("  - Math uses sign-in, URL, or stored student identity.")
    print("  - Existing Lambda code and student records were not replaced.")
    print()
    print("Close every sat.denduluru.com tab.")
    print("Open a new tab, sign in, and press Command+Shift+R once.")
    print("Answer one new Math question, refresh, and confirm it remains completed.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nRepair cancelled.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as error:
        print(f"\nERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
