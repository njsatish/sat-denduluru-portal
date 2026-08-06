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
import urllib.request
from pathlib import Path

PROFILE = "denduluru"
EXPECTED_ACCOUNT = "989174615155"
REGION = "us-east-1"
BUCKET = "sat-prep-josh"
SITE_ALIAS = "sat.denduluru.com"
PROGRESS_JS_KEY = "english/english-progress.js"
TEST_PAGE_KEY = "english/SAT_Words_26_50.html"
TEST_STUDENT = "josh"
STAMP = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
BUILD = f"20260804-english-identity-v7-{STAMP}"
BACKUP_PREFIX = f"backups/english-identity-v7-{STAMP}"
AWS_BASE = ["aws", "--profile", PROFILE, "--region", REGION]


class DeployError(RuntimeError):
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
        detail = result.stderr.strip() if capture else ""
        raise DeployError(
            f"Command failed ({result.returncode}): {' '.join(map(str, args))}"
            + (f"\n{detail}" if detail else "")
        )
    return result.stdout.strip() if capture else ""


def aws(*args, capture=False, check=True):
    return run(AWS_BASE + list(args), capture=capture, check=check)


def require_commands():
    missing = [name for name in ("aws", "node", "python3") if not shutil.which(name)]
    if missing:
        raise DeployError("Missing required command(s): " + ", ".join(missing))


def read_s3_text(key):
    return aws(
        "s3", "cp", f"s3://{BUCKET}/{key}", "-",
        "--only-show-errors", capture=True,
    )


def upload_s3(path, key, content_type):
    aws(
        "s3", "cp", str(path), f"s3://{BUCKET}/{key}",
        "--content-type", content_type,
        "--cache-control", "no-cache, no-store, must-revalidate",
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
            status = response.status
            text = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        text = error.read().decode("utf-8", errors="replace")
        raise DeployError(f"Progress API returned HTTP {error.code}: {text}") from error
    except OSError as error:
        raise DeployError(f"Progress API could not be reached: {error}") from error

    if not 200 <= status < 300:
        raise DeployError(f"Progress API returned HTTP {status}: {text}")
    try:
        return json.loads(text or "{}")
    except json.JSONDecodeError as error:
        raise DeployError(f"Progress API returned invalid JSON: {text}") from error


def extract_progress_api(text):
    patterns = [
        r"const\s+PROGRESS_API\s*=\s*['\"]([^'\"]+)['\"]",
        r"const\s+API\s*=\s*['\"](https://[^'\"]+\.lambda-url\.[^'\"]+\.on\.aws/?)['\"]",
        r"(https://[A-Za-z0-9-]+\.lambda-url\.[A-Za-z0-9-]+\.on\.aws/?)",
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            url = match.group(1)
            return url if url.endswith("/") else url + "/"
    raise DeployError("The English progress API URL was not found.")


def cloudfront_distribution():
    result = aws(
        "cloudfront", "list-distributions",
        "--query",
        f"DistributionList.Items[?Aliases.Quantity > `0` && contains(Aliases.Items, '{SITE_ALIAS}')].Id | [0]",
        "--output", "text",
        capture=True,
    )
    if not result or result == "None":
        raise DeployError(f"CloudFront distribution for {SITE_ALIAS} was not found.")
    return result


IDENTITY_START = "/* BEGIN SAT ENGLISH IDENTITY V7 */"
IDENTITY_END = "/* END SAT ENGLISH IDENTITY V7 */"
CLOUD_START = "/* BEGIN SAT ENGLISH CLOUD V7 */"
CLOUD_END = "/* END SAT ENGLISH CLOUD V7 */"

IDENTITY_JS = r'''/* BEGIN SAT ENGLISH IDENTITY V7 */
(() => {
  'use strict';

  if (window.SATEnglishIdentity?.build === '__BUILD__') return;

  const normalize = value => {
    const id = String(value || '').trim().toLowerCase();
    return /^[a-z0-9_-]{1,80}$/.test(id) ? id : '';
  };

  const decodeToken = token => {
    try {
      const part = String(token || '').split('.')[1];
      if (!part) return null;
      const base64 = part.replace(/-/g, '+').replace(/_/g, '/');
      const padded = base64 + '='.repeat((4 - base64.length % 4) % 4);
      const binary = atob(padded);
      const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
      return JSON.parse(new TextDecoder().decode(bytes));
    } catch (error) {
      console.warn('Unable to decode the SAT Cognito identity.', error);
      return null;
    }
  };

  const nativeGet = URLSearchParams.prototype.get;
  const tokenClaims = decodeToken(
    sessionStorage.getItem('sat_id_token') ||
    localStorage.getItem('sat_id_token')
  );
  const tokenStudent = normalize(
    window.SATAuth?.studentId ||
    window.SATAuth?.username ||
    tokenClaims?.['cognito:username'] ||
    tokenClaims?.username ||
    tokenClaims?.preferred_username
  );
  const storedStudent = normalize(localStorage.getItem('sat_user'));
  const pageParams = new URLSearchParams(location.search);
  const urlStudent = normalize(nativeGet.call(pageParams, 'student'));
  let studentId = tokenStudent || storedStudent || urlStudent;

  function resolveStudentId() {
    const claims = decodeToken(
      sessionStorage.getItem('sat_id_token') ||
      localStorage.getItem('sat_id_token')
    );
    const authenticated = normalize(
      window.SATAuth?.studentId ||
      window.SATAuth?.username ||
      claims?.['cognito:username'] ||
      claims?.username ||
      claims?.preferred_username
    );
    const stored = normalize(localStorage.getItem('sat_user'));
    studentId = authenticated || stored || studentId || urlStudent;
    if (studentId) localStorage.setItem('sat_user', studentId);
    return studentId;
  }

  if (!URLSearchParams.prototype.__satEnglishIdentityV7) {
    URLSearchParams.prototype.get = function(name) {
      const value = nativeGet.call(this, name);
      if (String(name) === 'student' && !normalize(value)) {
        return resolveStudentId() || value;
      }
      return value;
    };
    Object.defineProperty(URLSearchParams.prototype, '__satEnglishIdentityV7', {
      value: true,
      configurable: true
    });
  }

  function cleanStudentParameter(urlValue) {
    try {
      const url = new URL(urlValue, location.href);
      if (url.origin !== location.origin) return urlValue;
      url.searchParams.delete('student');
      return `${url.pathname}${url.search}${url.hash}`;
    } catch (_) {
      return urlValue;
    }
  }

  function cleanAddressBar() {
    const url = new URL(location.href);
    if (!url.searchParams.has('student')) return;
    url.searchParams.delete('student');
    history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
  }

  function cleanStudentLinks(root = document) {
    root.querySelectorAll?.('a[href]').forEach(anchor => {
      const href = anchor.getAttribute('href');
      if (!href || href.startsWith('#') || href.startsWith('mailto:') || href.startsWith('javascript:')) return;
      const cleaned = cleanStudentParameter(href);
      if (cleaned !== href) anchor.setAttribute('href', cleaned);
    });
  }

  resolveStudentId();
  cleanAddressBar();

  window.SATResolveStudentId = resolveStudentId;
  window.SATEnglishIdentity = {
    build: '__BUILD__',
    get studentId() { return resolveStudentId(); },
    source: tokenStudent ? 'cognito' : storedStudent ? 'storage' : urlStudent ? 'url' : 'missing',
    normalize,
    resolveStudentId,
    cleanStudentLinks
  };

  const ready = () => {
    cleanStudentLinks();
    setTimeout(cleanStudentLinks, 0);
    setTimeout(cleanStudentLinks, 150);
    setTimeout(cleanStudentLinks, 600);

    if (document.body && window.MutationObserver) {
      const observer = new MutationObserver(records => {
        for (const record of records) {
          record.addedNodes.forEach(node => {
            if (node.nodeType === 1) cleanStudentLinks(node);
          });
        }
      });
      observer.observe(document.body, {childList: true, subtree: true});
      setTimeout(() => observer.disconnect(), 5000);
    }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', ready, {once: true});
  } else {
    ready();
  }
})();
/* END SAT ENGLISH IDENTITY V7 */'''

CLOUD_JS = r'''/* BEGIN SAT ENGLISH CLOUD V7 */
(() => {
  'use strict';

  const API = __API__;
  const TOTAL = 375;
  const previous = window.SATEnglishCloud || {};
  const normalizeStudent = value => {
    const id = String(value || '').trim().toLowerCase();
    return /^[a-z0-9_-]{1,80}$/.test(id) ? id : '';
  };
  const studentId = normalizeStudent(
    window.SATResolveStudentId?.() ||
    window.SATEnglishIdentity?.studentId ||
    localStorage.getItem('sat_user') ||
    new URLSearchParams(location.search).get('student')
  );

  if (studentId) localStorage.setItem('sat_user', studentId);

  const storageKey = studentId
    ? `satEnglish300Progress:${studentId}`
    : 'sat300-nireekshan-progress-v1';

  const normalizeLearned = values => [...new Set(
    (Array.isArray(values) ? values : [])
      .map(Number)
      .filter(number => Number.isInteger(number) && number >= 1 && number <= TOTAL)
  )].sort((left, right) => left - right);

  function readLocal() {
    try {
      return normalizeLearned(
        JSON.parse(localStorage.getItem(storageKey) || '{}').learned
      );
    } catch (_) {
      return [];
    }
  }

  function writeLocal(learned) {
    localStorage.setItem(
      storageKey,
      JSON.stringify({learned: normalizeLearned(learned)})
    );
  }

  async function post(action, extra = {}) {
    if (!studentId) throw new Error('Student identity is missing. Please sign in once.');
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
    if (!response.ok) {
      throw new Error(`English progress API ${response.status}: ${text}`);
    }
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
    if (confirmed.length !== learned.length || confirmed.some((value, index) => value !== learned[index])) {
      throw new Error('The server did not confirm the learned-word list.');
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
      saveChain = saveChain
        .catch(() => {})
        .then(() => saveNow(learned))
        .catch(error => {
          lastError = error;
          console.error('SAT English progress did not save.', error);
          window.dispatchEvent(new CustomEvent('sat-english-progress-sync-error', {
            detail: {studentId, error: String(error)}
          }));
        });
    }, 120);
    return saveChain;
  }

  const ready = Promise.resolve(previous.ready)
    .catch(error => console.warn('Older English initialization failed.', error))
    .then(async () => {
      if (!studentId) return;
      const local = readLocal();
      const remotePayload = await post('englishProgress');
      const remote = normalizeLearned(remotePayload.learned);
      const merged = normalizeLearned([...remote, ...local]);
      writeLocal(merged);
      if (merged.length !== remote.length || merged.some((value, index) => value !== remote[index])) {
        await saveNow(merged);
      }
    })
    .catch(error => {
      lastError = error;
      console.error('SAT English cloud initialization failed; local progress remains available.', error);
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
/* END SAT ENGLISH CLOUD V7 */'''


def remove_marked_block(text, start, end):
    if start not in text or end not in text:
        return text
    return re.sub(
        re.escape(start) + r"[\s\S]*?" + re.escape(end),
        "",
        text,
        count=1,
    )


def patch_progress_js(source, progress_api):
    # Remove the old bridge that temporarily inserted ?student into the URL.
    source = re.sub(
        r"^/\* sat-english-progress-cognito-bridge-v3 \*/[\s\S]*?\n\}\)\(\);\s*",
        "",
        source,
        count=1,
    )
    for start, end in (
        (IDENTITY_START, IDENTITY_END),
        ("/* BEGIN SAT ENGLISH CLOUD V6 */", "/* END SAT ENGLISH CLOUD V6 */"),
        (CLOUD_START, CLOUD_END),
        ("/* BEGIN SAT ENGLISH VERIFIED WRITE BRIDGE V5 */", "/* END SAT ENGLISH VERIFIED WRITE BRIDGE V5 */"),
    ):
        source = remove_marked_block(source, start, end)

    identity = IDENTITY_JS.replace("__BUILD__", BUILD)
    cloud = CLOUD_JS.replace("__API__", json.dumps(progress_api))
    return identity + "\n\n" + source.strip() + "\n\n" + cloud + "\n"


def html_bootstrap():
    script = IDENTITY_JS.replace("__BUILD__", BUILD)
    return f'\n<script id="sat-english-identity-v7">\n{script}\n</script>\n'


def patch_html(text):
    # Replace an older v7 bootstrap if this command is rerun.
    text = re.sub(
        r"\s*<script\s+id=['\"]sat-english-identity-v7['\"][^>]*>[\s\S]*?</script>\s*",
        "\n",
        text,
        count=1,
        flags=re.IGNORECASE,
    )

    head = re.search(r"<head\b[^>]*>", text, flags=re.IGNORECASE)
    bootstrap = html_bootstrap()
    if head:
        text = text[:head.end()] + bootstrap + text[head.end():]
    else:
        text = bootstrap + text

    # Cache-bust the shared progress script wherever it is referenced.
    text = re.sub(
        r"(<script\b[^>]*\bsrc=['\"](?:\./)?english-progress\.js)(?:\?[^'\"]*)?(['\"][^>]*></script>)",
        rf"\1?v={BUILD}\2",
        text,
        flags=re.IGNORECASE,
    )
    return text


def validate_identity_js(root):
    print("4. Validating JavaScript and no-query identity resolution...")
    progress_path = root / "site" / PROGRESS_JS_KEY
    run(["node", "--check", str(progress_path)])

    identity = IDENTITY_JS.replace("__BUILD__", BUILD)
    harness = root / "identity-harness.js"
    harness.write_text(
        """
const vm = require('vm');
const assert = require('assert');
function store(values = {}) {
  const data = new Map(Object.entries(values));
  return {getItem:k=>data.has(k)?data.get(k):null,setItem:(k,v)=>data.set(k,String(v)),removeItem:k=>data.delete(k)};
}
function token(username) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({alg:'none'})}.${encode({'cognito:username':username})}.x`;
}
const document = {readyState:'loading',addEventListener(){},querySelectorAll(){return []},body:null};
const context = {
  console,
  URL,
  URLSearchParams,
  Uint8Array,
  TextDecoder,
  atob:value=>Buffer.from(value,'base64').toString('binary'),
  location:{href:'https://sat.denduluru.com/english/SAT_Words_26_50.html',origin:'https://sat.denduluru.com',pathname:'/english/SAT_Words_26_50.html',search:'',hash:''},
  history:{replaceState(){}},
  localStorage:store(),
  sessionStorage:store({sat_id_token:token('josh')}),
  document,
  MutationObserver:function(){},
  setTimeout(){},
  window:null
};
context.window = context;
vm.createContext(context);
vm.runInContext(%s, context);
assert.strictEqual(context.SATResolveStudentId(), 'josh');
assert.strictEqual(context.localStorage.getItem('sat_user'), 'josh');
assert.strictEqual(new context.URLSearchParams('').get('student'), 'josh');
assert.strictEqual(context.location.search, '');
console.log('identity harness passed');
""" % json.dumps(identity),
        encoding="utf-8",
    )
    run(["node", str(harness)])


def backup_key(key):
    aws(
        "s3", "cp", f"s3://{BUCKET}/{key}",
        f"s3://{BUCKET}/{BACKUP_PREFIX}/{key}",
        "--only-show-errors",
    )


def restore_keys(keys):
    for key in keys:
        aws(
            "s3", "cp", f"s3://{BUCKET}/{BACKUP_PREFIX}/{key}",
            f"s3://{BUCKET}/{key}",
            "--only-show-errors", check=False,
        )


def invalidate(distribution):
    invalidation = aws(
        "cloudfront", "create-invalidation",
        "--distribution-id", distribution,
        "--paths", "/english/*",
        "--query", "Invalidation.Id",
        "--output", "text",
        capture=True,
    )
    aws(
        "cloudfront", "wait", "invalidation-completed",
        "--distribution-id", distribution,
        "--id", invalidation,
    )


def main():
    require_commands()
    account = aws(
        "sts", "get-caller-identity", "--query", "Account", "--output", "text",
        capture=True,
    )
    if account != EXPECTED_ACCOUNT:
        raise DeployError(f"Expected AWS account {EXPECTED_ACCOUNT}, but found {account}.")

    distribution = cloudfront_distribution()
    print("=" * 72)
    print(" SAT English identity and no-query progress deployment v7")
    print("=" * 72)
    print(f"AWS account:   {account}")
    print(f"Distribution:  {distribution}")
    print(f"Backup:        s3://{BUCKET}/{BACKUP_PREFIX}/")
    print()

    with tempfile.TemporaryDirectory(prefix="sat-english-identity-v7-") as temp_name:
        root = Path(temp_name)
        site_root = root / "site"
        site_root.mkdir()

        print("1. Downloading the live English HTML and JavaScript...")
        aws(
            "s3", "sync", f"s3://{BUCKET}/english", str(site_root / "english"),
            "--exclude", "*", "--include", "*.html", "--include", "*.js",
            "--only-show-errors",
        )
        progress_path = site_root / PROGRESS_JS_KEY
        if not progress_path.exists():
            raise DeployError(f"{PROGRESS_JS_KEY} was not downloaded.")

        all_text = "\n".join(
            path.read_text(encoding="utf-8", errors="replace")
            for path in site_root.rglob("*")
            if path.is_file() and path.suffix.lower() in {".html", ".js"}
        )
        progress_api = extract_progress_api(all_text)
        print(f"   Progress API: {progress_api}")

        print("2. Confirming the working English progress API is unchanged...")
        progress = http_post(progress_api, {
            "action": "englishProgress",
            "userId": TEST_STUDENT,
            "studentId": TEST_STUDENT,
        })
        if not isinstance(progress.get("learned", []), list):
            raise DeployError(f"englishProgress returned an unexpected payload: {progress}")
        print(f"   PASS: {len(progress.get('learned', []))} saved word(s) returned for {TEST_STUDENT}.")

        print("3. Applying Cognito/storage/URL identity resolution...")
        changed = []
        original_progress = progress_path.read_text(encoding="utf-8")
        patched_progress = patch_progress_js(original_progress, progress_api)
        if patched_progress != original_progress:
            progress_path.write_text(patched_progress, encoding="utf-8")
            changed.append(PROGRESS_JS_KEY)

        html_count = 0
        for path in sorted((site_root / "english").rglob("*.html")):
            original = path.read_text(encoding="utf-8")
            updated = patch_html(original)
            html_count += 1
            if updated != original:
                path.write_text(updated, encoding="utf-8")
                changed.append(path.relative_to(site_root).as_posix())

        if not html_count:
            raise DeployError("No English HTML pages were found.")
        if not changed:
            raise DeployError("No files required an update; deployment was not performed.")
        print(f"   Prepared {len(changed)} changed file(s) across {html_count} English page(s).")

        validate_identity_js(root)

        print("5. Backing up and uploading the frontend changes...")
        for key in changed:
            backup_key(key)

        uploaded = []
        try:
            for key in changed:
                path = site_root / key
                content_type = (
                    "text/html; charset=utf-8"
                    if path.suffix.lower() == ".html"
                    else "application/javascript; charset=utf-8"
                )
                upload_s3(path, key, content_type)
                uploaded.append(key)

            print("6. Invalidating CloudFront...")
            invalidate(distribution)

            print("7. Verifying the deployed files...")
            deployed_js = read_s3_text(PROGRESS_JS_KEY)
            if IDENTITY_START not in deployed_js or CLOUD_START not in deployed_js:
                raise DeployError("The deployed progress script is missing the v7 markers.")
            if "sat-english-progress-cognito-bridge-v3" in deployed_js:
                raise DeployError("The old URL-forcing Cognito bridge is still present.")

            deployed_page = read_s3_text(TEST_PAGE_KEY)
            if 'id="sat-english-identity-v7"' not in deployed_page:
                raise DeployError("The no-query identity bootstrap is missing from the test page.")
            if f"english-progress.js?v={BUILD}" not in deployed_page:
                raise DeployError("The test page does not reference the v7 progress script version.")
        except Exception:
            if uploaded:
                print("\nDeployment verification failed. Restoring the previous frontend files...")
                restore_keys(changed)
                invalidate(distribution)
            raise

    print()
    print("=" * 72)
    print(" SAT ENGLISH IDENTITY V7 DEPLOYMENT PASSED")
    print("=" * 72)
    print("Implemented:")
    print("  - Cognito student identity is used first.")
    print("  - localStorage sat_user is the browser fallback.")
    print("  - ?student= is only an optional first-use fallback and is removed from the URL.")
    print("  - Legacy URL-only guards receive the resolved student without changing the address bar.")
    print("  - Existing English saved words and Lambda/DynamoDB logic were not replaced.")
    print()
    print("Close all SAT tabs and open:")
    print("https://sat.denduluru.com/english/SAT_Words_26_50.html")
    print("Then use Command+Shift+R once.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit("Cancelled.")
    except Exception as error:
        print(f"\nERROR: {error}")
        raise SystemExit(1)
