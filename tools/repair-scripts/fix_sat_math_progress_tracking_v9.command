#!/usr/bin/env python3
from __future__ import annotations

import json, os, re, shutil, subprocess, sys, tempfile, time
import urllib.error, urllib.request
from pathlib import Path

PROFILE="denduluru"
ACCOUNT="989174615155"
REGION="us-east-1"
BUCKET="sat-prep-josh"
ORIGIN="https://sat.denduluru.com"
ALIAS="sat.denduluru.com"
APP_KEY="math/app.js"
TABLE="sat-progress"
STAMP=time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
BUILD=f"20260805-math-progress-v9-{STAMP}"
BACKUP=f"backups/math-progress-v9-{STAMP}"
TEST_USER=f"mathtrack{int(time.time())}{os.getpid()}"
TEST_Q="v1q001"
AWS=["aws","--profile",PROFILE,"--region",REGION]

class Error(RuntimeError):
    pass

def run(args, capture=False, check=True):
    p=subprocess.run([str(x) for x in args], text=True,
                     stdout=subprocess.PIPE if capture else None,
                     stderr=subprocess.PIPE if capture else None)
    if check and p.returncode:
        raise Error(f"Command failed ({p.returncode}): {' '.join(map(str,args))}\n{(p.stderr or '').strip()}")
    return (p.stdout or "").strip() if capture else ""

def aws(*args, capture=False, check=True):
    return run(AWS+list(args), capture, check)

def s3read(key):
    return aws("s3","cp",f"s3://{BUCKET}/{key}","-","--only-show-errors",capture=True)

def find_url(text):
    m=re.search(r"""const\s+PROGRESS_API\s*=\s*['\"]([^'\"]+)['\"]""",text)
    if not m:
        raise Error("PROGRESS_API was not found in live math/app.js")
    return m.group(1) if m.group(1).endswith("/") else m.group(1)+"/"

def find_lambda(url):
    names=aws("lambda","list-functions","--query","Functions[].FunctionName","--output","text",capture=True)
    for name in re.split(r"\s+",names):
        if not name:
            continue
        found=aws("lambda","get-function-url-config","--function-name",name,
                  "--query","FunctionUrl","--output","text",capture=True,check=False)
        if found==url:
            return name
    raise Error(f"No Lambda Function URL matches {url}")

def distribution():
    value=aws("cloudfront","list-distributions","--query",
              f"DistributionList.Items[?Aliases.Quantity > `0` && contains(Aliases.Items, '{ALIAS}')].Id | [0]",
              "--output","text",capture=True)
    if not value or value=="None":
        raise Error("CloudFront distribution was not found")
    return value

def req(url, method, headers=None, payload=None):
    data=None if payload is None else json.dumps(payload).encode()
    r=urllib.request.Request(url,data=data,headers=headers or {},method=method)
    try:
        with urllib.request.urlopen(r,timeout=30) as x:
            return x.status,dict(x.headers.items()),x.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code,dict(e.headers.items()),e.read().decode(errors="replace")
    except OSError as e:
        raise Error(f"Could not reach Math progress API: {e}") from e

def h(headers,name):
    for k,v in headers.items():
        if k.lower()==name.lower():
            return v
    return ""

def post(url,payload,expected=(200,201)):
    status,headers,body=req(url,"POST",{
        "Origin":ORIGIN,
        "Content-Type":"application/json",
        "Cache-Control":"no-cache",
        "Pragma":"no-cache",
    },payload)
    if h(headers,"Access-Control-Allow-Origin") not in (ORIGIN,"*"):
        raise Error(f"POST missing CORS origin; HTTP {status}; body={body}")
    if status not in expected:
        raise Error(f"API HTTP {status}: {body}")
    try:
        return json.loads(body or "{}")
    except Exception:
        raise Error(f"API returned invalid JSON: {body}")

def preflight(url):
    status,headers,body=req(url,"OPTIONS",{
        "Origin":ORIGIN,
        "Access-Control-Request-Method":"POST",
        "Access-Control-Request-Headers":"content-type,cache-control,pragma",
    })
    ao=h(headers,"Access-Control-Allow-Origin")
    am=h(headers,"Access-Control-Allow-Methods").upper()
    ah=h(headers,"Access-Control-Allow-Headers").lower()
    if status not in (200,204):
        raise Error(f"OPTIONS HTTP {status}: {body}")
    if ao not in (ORIGIN,"*"):
        raise Error(f"OPTIONS origin invalid: {ao!r}")
    if "POST" not in am and "*" not in am:
        raise Error(f"OPTIONS does not allow POST: {am!r}")
    for x in ("content-type","cache-control","pragma"):
        if x not in ah and "*" not in ah:
            raise Error(f"OPTIONS does not allow {x}: {ah!r}")

def cleanup():
    requests=[
      {"DeleteRequest":{"Key":{"userId":{"S":TEST_USER},"questionId":{"S":TEST_Q}}}},
      {"DeleteRequest":{"Key":{"userId":{"S":"__students__"},"questionId":{"S":f"student#{TEST_USER}"}}}},
    ]
    with tempfile.NamedTemporaryFile("w",suffix=".json",delete=False) as f:
        json.dump({TABLE:requests},f)
        p=f.name
    try:
        aws("dynamodb","batch-write-item","--request-items",f"file://{p}",capture=True,check=False)
    finally:
        Path(p).unlink(missing_ok=True)

def test_tracking(url,password):
    post(url,{"action":"createStudent","adminPassword":password,
              "displayName":"Math Tracking Test","requestedStudentId":TEST_USER})
    got=post(url,{"action":"getStudent","userId":TEST_USER})
    if not got.get("student"):
        raise Error(f"getStudent failed: {got}")
    saved=post(url,{"action":"record","userId":TEST_USER,"questionId":TEST_Q,
                    "correct":True,"choice":"tracking-test","category":"tracking-test"})
    if saved.get("questionId")!=TEST_Q or saved.get("lastResult")!="correct":
        raise Error(f"record did not confirm save: {saved}")
    progress=post(url,{"action":"progress","userId":TEST_USER})
    item=next((x for x in progress.get("items",[]) if x.get("questionId")==TEST_Q),None)
    if not item or item.get("lastResult")!="correct" or item.get("lastChoice")!="tracking-test":
        raise Error(f"progress did not return saved answer: {item}")

IDENTITY_START="/* BEGIN SAT MATH IDENTITY V9 */"
IDENTITY_END="/* END SAT MATH IDENTITY V9 */"
IDENTITY=r'''/* BEGIN SAT MATH IDENTITY V9 */
const SAT_MATH_IDENTITY_BUILD = "__BUILD__";

function decodeSatMathToken(token) {
  try {
    const part = String(token || "").split(".")[1];
    if (!part) return null;
    const base64 = part.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - base64.length % 4) % 4);
    const binary = atob(padded);
    const bytes = Uint8Array.from(binary, c => c.charCodeAt(0));
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch (error) {
    console.warn("Unable to decode SAT identity.", error);
    return null;
  }
}

function resolveMathStudentId() {
  const params = new URLSearchParams(location.search);
  const fromUrl = normalizeStudentId(params.get("student"));
  const claims = decodeSatMathToken(
    sessionStorage.getItem("sat_id_token") ||
    localStorage.getItem("sat_id_token")
  );
  const signedIn = normalizeStudentId(
    window.SATAuth?.studentId ||
    window.SATAuth?.username ||
    claims?.["cognito:username"] ||
    claims?.username ||
    claims?.preferred_username
  );
  const stored = normalizeStudentId(localStorage.getItem("sat_user"));
  const studentId = signedIn || fromUrl || stored;
  if (studentId) localStorage.setItem("sat_user", studentId);
  return studentId;
}
/* END SAT MATH IDENTITY V9 */'''

def patch_app(text):
    text=re.sub(re.escape(IDENTITY_START)+r"[\s\S]*?"+re.escape(IDENTITY_END)+r"\s*","",text,count=1)
    m=re.search(r"function\s+normalizeStudentId\s*\([^)]*\)\s*\{[\s\S]*?\n\}",text)
    if not m:
        raise Error("normalizeStudentId was not found")
    block=IDENTITY.replace("__BUILD__",BUILD)
    text=text[:m.end()]+"\n\n"+block+text[m.end():]
    text,n=re.subn(r"function\s+getStudentFromUrl\s*\(\)\s*\{[\s\S]*?\n\}",
                   "function getStudentFromUrl() {\n  return resolveMathStudentId();\n}",text,count=1)
    if n!=1:
        raise Error("getStudentFromUrl could not be patched")
    if "console.warn('cloud sync failed', error);" in text and "sat-math-progress-sync-error" not in text:
        text=text.replace("console.warn('cloud sync failed', error);",
          """console.warn('cloud sync failed', error);
    window.dispatchEvent(new CustomEvent('sat-math-progress-sync-error', {
      detail: { studentId: getUser(), error: String(error?.message || error) }
    }));""",1)
    for marker in (IDENTITY_START,"resolveMathStudentId","return resolveMathStudentId();"):
        if marker not in text:
            raise Error(f"Patched app missing {marker}")
    return text

def patch_html(text):
    text,n=re.subn(r"""(<script\b[^>]*\bsrc=['\"](?:\./)?app\.js)(?:\?[^'\"]*)?(['\"][^>]*></script>)""",
                   rf"\1?v={BUILD}\2",text,count=1,flags=re.I)
    if n!=1:
        raise Error("app.js reference not found in a Math HTML page")
    return text

def invalidate(dist):
    iid=aws("cloudfront","create-invalidation","--distribution-id",dist,
            "--paths","/math/*","--query","Invalidation.Id","--output","text",capture=True)
    aws("cloudfront","wait","invalidation-completed","--distribution-id",dist,"--id",iid)

def add_permissions(fn):
    for sid,action,extra in (
      ("SatMathPublicUrlV9","lambda:InvokeFunctionUrl",["--function-url-auth-type","NONE"]),
      ("SatMathPublicInvokeV9","lambda:InvokeFunction",["--invoked-via-function-url"]),
    ):
        aws("lambda","add-permission","--function-name",fn,"--statement-id",sid,
            "--action",action,"--principal","*",*extra,capture=True,check=False)

def main():
    for cmd in ("aws","python3","node"):
        if not shutil.which(cmd):
            raise Error(f"{cmd} is required")
    acct=aws("sts","get-caller-identity","--query","Account","--output","text",capture=True)
    if acct!=ACCOUNT:
        raise Error(f"Expected account {ACCOUNT}, found {acct}")
    dist=distribution()
    print("="*70)
    print(" SAT Math progress tracking repair v9")
    print("="*70)
    print(f"AWS account: {acct}\nDistribution: {dist}\nBuild: {BUILD}\n")

    uploaded=[]
    fn=""
    original_config=None
    with tempfile.TemporaryDirectory(prefix="sat-math-v9-") as td:
        root=Path(td)
        live=root/"live"
        patched=root/"patched"
        (live/"math").mkdir(parents=True)
        (patched/"math").mkdir(parents=True)

        print("1. Downloading live Math files...")
        aws("s3","sync",f"s3://{BUCKET}/math",str(live/"math"),
            "--exclude","*","--include","*.html","--include","app.js","--only-show-errors")
        app=live/APP_KEY
        if not app.exists():
            raise Error("math/app.js was not downloaded")
        htmls=sorted((live/"math").glob("*.html"))
        if not htmls:
            raise Error("No Math HTML pages were downloaded")
        original_app=app.read_text(encoding="utf-8")
        url=find_url(original_app)
        print(f"   Math API: {url}")
        fn=find_lambda(url)
        print(f"   Lambda:   {fn}")

        original_config=json.loads(aws("lambda","get-function-url-config","--function-name",fn,
                                       "--output","json",capture=True))
        config=json.loads(aws("lambda","get-function-configuration","--function-name",fn,
                              "--output","json",capture=True))
        password=config.get("Environment",{}).get("Variables",{}).get("ADMIN_PASSWORD")
        if not password:
            raise Error("ADMIN_PASSWORD is not configured")

        backup_cfg=root/"function-url-before.json"
        backup_cfg.write_text(json.dumps(original_config,indent=2)+"\n")
        aws("s3","cp",str(backup_cfg),f"s3://{BUCKET}/{BACKUP}/function-url-before.json",
            "--only-show-errors")

        try:
            print("2. Repairing browser access for the exact Math API...")
            cors={"AllowCredentials":False,
                  "AllowHeaders":["content-type","authorization","cache-control","pragma"],
                  "AllowMethods":["POST","GET"],
                  "AllowOrigins":[ORIGIN],
                  "ExposeHeaders":["content-type"],"MaxAge":86400}
            aws("lambda","update-function-url-config","--function-name",fn,"--auth-type","NONE",
                "--cors",json.dumps(cors,separators=(",",":")),"--output","json",capture=True)
            add_permissions(fn)
            time.sleep(2)
            preflight(url)
            print("   PASS: browser preflight succeeds.")

            print("3. Testing a real Math answer save and read-back...")
            cleanup()
            test_tracking(url,password)
            cleanup()
            print("   PASS: Math answer save/read-back succeeds.")

            print("4. Adding signed-in/stored student fallback to Math...")
            out=patched/APP_KEY
            out.parent.mkdir(parents=True,exist_ok=True)
            out.write_text(patch_app(original_app),encoding="utf-8")
            run(["node","--check",str(out)])
            for src in htmls:
                rel=src.relative_to(live)
                dst=patched/rel
                dst.parent.mkdir(parents=True,exist_ok=True)
                dst.write_text(patch_html(src.read_text(encoding="utf-8")),encoding="utf-8")

            keys=[APP_KEY]+[x.relative_to(live).as_posix() for x in htmls]
            print(f"5. Backing up and deploying {len(keys)} Math files...")
            for key in keys:
                aws("s3","cp",f"s3://{BUCKET}/{key}",f"s3://{BUCKET}/{BACKUP}/{key}",
                    "--only-show-errors")
            for key in keys:
                src=patched/key
                ctype="application/javascript; charset=utf-8" if src.suffix==".js" else "text/html; charset=utf-8"
                aws("s3","cp",str(src),f"s3://{BUCKET}/{key}","--content-type",ctype,
                    "--cache-control","no-cache, no-store, must-revalidate","--only-show-errors")
                uploaded.append(key)

            print("6. Invalidating CloudFront and verifying...")
            invalidate(dist)
            deployed=s3read(APP_KEY)
            if IDENTITY_START not in deployed or "return resolveMathStudentId();" not in deployed:
                raise Error("Deployed Math identity patch was not found")
            sample=htmls[0].relative_to(live).as_posix()
            if f"app.js?v={BUILD}" not in s3read(sample):
                raise Error("Deployed Math cache-busting was not found")

            print("7. Re-testing Math tracking after frontend deployment...")
            cleanup()
            test_tracking(url,password)
            cleanup()
            print("   PASS: post-deployment Math tracking succeeds.")
        except Exception:
            cleanup()
            if uploaded:
                print("\nVerification failed. Restoring previous Math frontend...")
                for key in uploaded:
                    aws("s3","cp",f"s3://{BUCKET}/{BACKUP}/{key}",f"s3://{BUCKET}/{key}",
                        "--only-show-errors",check=False)
                invalidate(dist)
            if original_config:
                args=["lambda","update-function-url-config","--function-name",fn,
                      "--auth-type",original_config.get("AuthType","NONE")]
                if "Cors" in original_config:
                    args+=["--cors",json.dumps(original_config["Cors"],separators=(",",":"))]
                aws(*args,capture=True,check=False)
            raise

    print("\n"+"="*70)
    print(" SAT MATH PROGRESS TRACKING REPAIR PASSED")
    print("="*70)
    print("Verified: browser access, real answer write/read-back, and no-query student identity.")
    print("Close all SAT tabs, reopen the site, and press Command+Shift+R once.")

if __name__=="__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit("Cancelled.")
    except Exception as e:
        print(f"\nERROR: {e}",file=sys.stderr)
        raise SystemExit(1)
