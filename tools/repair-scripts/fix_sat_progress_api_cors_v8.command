#!/usr/bin/env python3
from __future__ import annotations

import json
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
SITE_ORIGIN = "https://sat.denduluru.com"
TEST_STUDENT = "josh"

STAMP = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
BACKUP_PREFIX = f"backups/progress-api-cors-v8-{STAMP}"
AWS_BASE = ["aws", "--profile", PROFILE, "--region", REGION]


class RepairError(RuntimeError):
    pass


def run(args, *, capture=False, check=True):
    result = subprocess.run(
        [str(value) for value in args],
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode != 0:
        detail = (result.stderr or "").strip()
        raise RepairError(
            f"Command failed ({result.returncode}): {' '.join(map(str, args))}"
            + (f"\n{detail}" if detail else "")
        )
    return (result.stdout or "").strip() if capture else ""


def aws(*args, capture=False, check=True):
    return run(AWS_BASE + list(args), capture=capture, check=check)


def require_commands():
    missing = [name for name in ("aws", "python3") if not shutil.which(name)]
    if missing:
        raise RepairError("Missing required command(s): " + ", ".join(missing))


def read_s3_text(key):
    return aws(
        "s3", "cp", f"s3://{BUCKET}/{key}", "-",
        "--only-show-errors", capture=True,
    )


def extract_urls(text):
    return list(dict.fromkeys(re.findall(
        r"https://[A-Za-z0-9-]+\.lambda-url\.[A-Za-z0-9-]+\.on\.aws/?",
        text,
    )))


def discover_progress_url():
    keys = [
        "english/english-progress.js",
        "english/english-student.js",
        "english/SAT_Words_26_50.html",
        "english/SAT_Words_101_125.html",
    ]
    candidates = []
    for key in keys:
        try:
            text = read_s3_text(key)
        except RepairError:
            continue
        for url in extract_urls(text):
            normalized = url if url.endswith("/") else url + "/"
            if normalized not in candidates:
                candidates.append(normalized)

    if not candidates:
        raise RepairError("No Lambda Function URL was found in the live English files.")

    # Prefer the URL referenced by the shared progress script.
    try:
        shared = read_s3_text("english/english-progress.js")
        shared_urls = extract_urls(shared)
        if shared_urls:
            url = shared_urls[0]
            return url if url.endswith("/") else url + "/"
    except RepairError:
        pass

    return candidates[0]


def find_lambda_for_url(function_url):
    raw = aws(
        "lambda", "list-functions",
        "--query", "Functions[].FunctionName",
        "--output", "text",
        capture=True,
    )
    for name in re.split(r"\s+", raw):
        if not name:
            continue
        value = aws(
            "lambda", "get-function-url-config",
            "--function-name", name,
            "--query", "FunctionUrl",
            "--output", "text",
            capture=True,
            check=False,
        )
        if value == function_url:
            return name
    raise RepairError(f"No Lambda function URL configuration matches {function_url}")


def get_policy(function_name):
    raw = aws(
        "lambda", "get-policy",
        "--function-name", function_name,
        "--output", "json",
        capture=True,
        check=False,
    )
    if not raw:
        return {"Version": "2012-10-17", "Statement": []}
    outer = json.loads(raw)
    policy = outer.get("Policy")
    return json.loads(policy) if isinstance(policy, str) else (policy or {})


def principal_is_public(principal):
    if principal == "*":
        return True
    if isinstance(principal, dict):
        return any(value == "*" or (isinstance(value, list) and "*" in value)
                   for value in principal.values())
    return False


def action_contains(statement, required):
    actions = statement.get("Action", [])
    if isinstance(actions, str):
        actions = [actions]
    return required in actions or "*" in actions or "lambda:*" in actions


def has_public_url_permission(policy):
    for statement in policy.get("Statement", []):
        if (
            statement.get("Effect") == "Allow"
            and principal_is_public(statement.get("Principal"))
            and action_contains(statement, "lambda:InvokeFunctionUrl")
        ):
            return True
    return False


def has_public_function_permission(policy):
    for statement in policy.get("Statement", []):
        if (
            statement.get("Effect") == "Allow"
            and principal_is_public(statement.get("Principal"))
            and action_contains(statement, "lambda:InvokeFunction")
        ):
            condition = statement.get("Condition", {})
            encoded = json.dumps(condition).lower()
            # A function-URL-only condition is preferred. A broader existing
            # public permission also permits the URL, so do not duplicate it.
            if "invokedviafunctionurl" in encoded or not condition:
                return True
    return False


def add_missing_permissions(function_name):
    policy = get_policy(function_name)
    added = []

    if not has_public_url_permission(policy):
        sid = f"SatUrlPublic{int(time.time())}"
        aws(
            "lambda", "add-permission",
            "--function-name", function_name,
            "--statement-id", sid,
            "--action", "lambda:InvokeFunctionUrl",
            "--principal", "*",
            "--function-url-auth-type", "NONE",
            capture=True,
        )
        added.append(sid)
        print("   Added lambda:InvokeFunctionUrl public permission.")
    else:
        print("   PASS: lambda:InvokeFunctionUrl public permission already exists.")

    policy = get_policy(function_name)
    if not has_public_function_permission(policy):
        sid = f"SatInvokeViaUrl{int(time.time())}"
        aws(
            "lambda", "add-permission",
            "--function-name", function_name,
            "--statement-id", sid,
            "--action", "lambda:InvokeFunction",
            "--principal", "*",
            "--invoked-via-function-url",
            capture=True,
        )
        added.append(sid)
        print("   Added lambda:InvokeFunction permission restricted to Function URL calls.")
    else:
        print("   PASS: lambda:InvokeFunction Function-URL permission already exists.")

    return added


def request(url, *, method, headers=None, body=None):
    req = urllib.request.Request(
        url,
        data=body,
        headers=headers or {},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, dict(response.headers.items()), response.read().decode(
                "utf-8", errors="replace"
            )
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers.items()), error.read().decode(
            "utf-8", errors="replace"
        )
    except OSError as error:
        raise RepairError(f"Could not reach the Function URL: {error}") from error


def header(headers, name):
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return ""


def verify_preflight(function_url):
    print("5. Testing the browser OPTIONS preflight...")
    status, headers, body = request(
        function_url,
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
        raise RepairError(f"CORS preflight returned HTTP {status}: {body}")
    if allow_origin not in (SITE_ORIGIN, "*"):
        raise RepairError(
            "CORS preflight did not allow sat.denduluru.com. "
            f"Access-Control-Allow-Origin={allow_origin!r}"
        )
    if "POST" not in allow_methods and "*" not in allow_methods:
        raise RepairError(
            f"CORS preflight did not allow POST. Header={allow_methods!r}"
        )
    for required in ("content-type", "cache-control", "pragma"):
        if required not in allow_headers and "*" not in allow_headers:
            raise RepairError(
                f"CORS preflight did not allow {required}. Header={allow_headers!r}"
            )

    print(f"   PASS: OPTIONS returned HTTP {status} with valid CORS headers.")


def browser_post(function_url, payload):
    status, headers, body = request(
        function_url,
        method="POST",
        headers={
            "Origin": SITE_ORIGIN,
            "Content-Type": "application/json",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
        body=json.dumps(payload).encode("utf-8"),
    )
    allow_origin = header(headers, "Access-Control-Allow-Origin")
    if allow_origin not in (SITE_ORIGIN, "*"):
        raise RepairError(
            "The POST response is missing the browser CORS origin header. "
            f"HTTP {status}; Access-Control-Allow-Origin={allow_origin!r}; body={body}"
        )
    if not 200 <= status < 300:
        raise RepairError(f"Browser-style POST returned HTTP {status}: {body}")
    try:
        return json.loads(body or "{}")
    except json.JSONDecodeError as error:
        raise RepairError(f"Browser-style POST returned invalid JSON: {body}") from error


def verify_browser_calls(function_url):
    print("6. Testing browser-style getStudent...")
    student = browser_post(function_url, {
        "action": "getStudent",
        "userId": TEST_STUDENT,
        "studentId": TEST_STUDENT,
        "student": TEST_STUDENT,
    })
    if not isinstance(student, dict):
        raise RepairError(f"getStudent returned an unexpected payload: {student!r}")
    print("   PASS: getStudent is reachable from the website origin.")

    print("7. Testing browser-style englishProgress...")
    progress = browser_post(function_url, {
        "action": "englishProgress",
        "userId": TEST_STUDENT,
        "studentId": TEST_STUDENT,
        "student": TEST_STUDENT,
    })
    learned = progress.get("learned")
    if not isinstance(learned, list):
        raise RepairError(f"englishProgress returned an unexpected payload: {progress}")
    print(f"   PASS: englishProgress returned {len(learned)} learned word(s).")


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

    print("=" * 72)
    print(" SAT progress API browser/CORS repair v8")
    print("=" * 72)
    print(f"AWS account: {account}")
    print(f"Website:     {SITE_ORIGIN}")
    print()

    print("1. Discovering the live progress Function URL...")
    function_url = discover_progress_url()
    print(f"   Function URL: {function_url}")

    print("2. Finding the Lambda function...")
    function_name = find_lambda_for_url(function_url)
    print(f"   Lambda: {function_name}")

    original_config_raw = aws(
        "lambda", "get-function-url-config",
        "--function-name", function_name,
        "--output", "json",
        capture=True,
    )
    original_policy_raw = aws(
        "lambda", "get-policy",
        "--function-name", function_name,
        "--output", "json",
        capture=True,
        check=False,
    )

    with tempfile.TemporaryDirectory(prefix="sat-cors-v8-") as temp_name:
        root = Path(temp_name)
        config_path = root / "function-url-before.json"
        policy_path = root / "lambda-policy-before.json"
        config_path.write_text(original_config_raw + "\n", encoding="utf-8")
        policy_path.write_text((original_policy_raw or "{}") + "\n", encoding="utf-8")

        aws(
            "s3", "cp", str(config_path),
            f"s3://{BUCKET}/{BACKUP_PREFIX}/function-url-before.json",
            "--only-show-errors",
        )
        aws(
            "s3", "cp", str(policy_path),
            f"s3://{BUCKET}/{BACKUP_PREFIX}/lambda-policy-before.json",
            "--only-show-errors",
        )

    print(f"   Backup: s3://{BUCKET}/{BACKUP_PREFIX}/")

    print("3. Configuring the Function URL for browser POST requests...")
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
    updated_raw = aws(
        "lambda", "update-function-url-config",
        "--function-name", function_name,
        "--auth-type", "NONE",
        "--cors", json.dumps(cors, separators=(",", ":")),
        "--output", "json",
        capture=True,
    )
    updated = json.loads(updated_raw)
    if updated.get("AuthType") != "NONE":
        raise RepairError(f"Function URL AuthType was not changed to NONE: {updated}")
    print("   PASS: AuthType is NONE and exact-origin CORS is configured.")

    print("4. Verifying the two required Function URL permissions...")
    add_missing_permissions(function_name)

    # Give the Function URL configuration a brief moment to propagate.
    time.sleep(2)
    verify_preflight(function_url)
    verify_browser_calls(function_url)

    print()
    print("=" * 72)
    print(" SAT PROGRESS API BROWSER/CORS REPAIR PASSED")
    print("=" * 72)
    print()
    print("Verified:")
    print("  - The Function URL accepts public website calls.")
    print("  - The browser OPTIONS preflight succeeds.")
    print("  - POST responses allow https://sat.denduluru.com.")
    print("  - getStudent works from the website origin.")
    print("  - englishProgress works from the website origin.")
    print()
    print("Close every sat.denduluru.com tab.")
    print("Open a new tab, sign in, and use Command+Shift+R once.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nRepair cancelled.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as error:
        print(f"\nERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
