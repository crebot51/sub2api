#!/usr/bin/env bash
# Compare Docker Hub weishaw/sub2api:latest (linux/amd64) with Fly app image;
# deploy only when digest differs (or FORCE_DEPLOY=true).
set -euo pipefail

APP="${APP:-sub2api-wkwcpg}"
IMAGE_REPO="${IMAGE_REPO:-weishaw/sub2api}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
PLATFORM_OS="${PLATFORM_OS:-linux}"
PLATFORM_ARCH="${PLATFORM_ARCH:-amd64}"
FLY_TOML="${FLY_TOML:-deploy/fly/fly.toml}"
FORCE_DEPLOY="${FORCE_DEPLOY:-false}"

if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo "ERROR: FLY_API_TOKEN not set"
  exit 1
fi
export FLY_API_TOKEN

echo "check start app=$APP image=${IMAGE_REPO}:${IMAGE_TAG} platform=${PLATFORM_OS}/${PLATFORM_ARCH} force=$FORCE_DEPLOY"

CURRENT_DIGEST="$(
  flyctl image show -a "$APP" 2>/dev/null | python3 -c 'import sys,re; ms=re.findall(r"sha256:[a-f0-9]{64}", sys.stdin.read()); print(ms[0] if ms else "")' || true
)"
if [ -z "$CURRENT_DIGEST" ]; then
  CURRENT_DIGEST="$(
    flyctl machines list -a "$APP" -j 2>/dev/null | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit
for m in data or []:
    ref = m.get("image_ref") or {}
    dig = ref.get("digest") or ""
    if dig:
        print(dig)
        raise SystemExit
    img = (m.get("config") or {}).get("image") or ""
    if "@sha256:" in img:
        print("sha256:" + img.split("@sha256:")[-1])
        raise SystemExit
print("")
' || true
  )"
fi
echo "current_digest=${CURRENT_DIGEST:-none}"

REMOTE_DIGEST="$(
  IMAGE_REPO="$IMAGE_REPO" IMAGE_TAG="$IMAGE_TAG" \
  PLATFORM_OS="$PLATFORM_OS" PLATFORM_ARCH="$PLATFORM_ARCH" python3 - <<'PY'
import json, os, urllib.request, sys

repo = os.environ["IMAGE_REPO"]
tag = os.environ["IMAGE_TAG"]
want_os = os.environ.get("PLATFORM_OS", "linux")
want_arch = os.environ.get("PLATFORM_ARCH", "amd64")

def get_token():
    url = f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
    return json.load(urllib.request.urlopen(url, timeout=30))["token"]

def get_manifest(token, reference):
    req = urllib.request.Request(
        f"https://registry-1.docker.io/v2/{repo}/manifests/{reference}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": ",".join([
                "application/vnd.docker.distribution.manifest.list.v2+json",
                "application/vnd.oci.image.index.v1+json",
                "application/vnd.docker.distribution.manifest.v2+json",
                "application/vnd.oci.image.manifest.v1+json",
            ]),
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        digest = (resp.headers.get("Docker-Content-Digest") or "").strip()
        body = resp.read()
        ctype = resp.headers.get("Content-Type") or ""
    return digest, ctype, body

try:
    token = get_token()
    top_digest, ctype, body = get_manifest(token, tag)
    data = json.loads(body)
    media = (data.get("mediaType") or ctype or "").lower()
    if "manifest.list" in media or "image.index" in media or "manifests" in data:
        chosen = ""
        for item in data.get("manifests") or []:
            platform = item.get("platform") or {}
            if platform.get("os") == want_os and platform.get("architecture") == want_arch:
                chosen = item.get("digest") or ""
                break
        if not chosen:
            for item in data.get("manifests") or []:
                platform = item.get("platform") or {}
                if platform.get("os") == want_os:
                    chosen = item.get("digest") or ""
                    break
        print(chosen or top_digest)
    else:
        print(top_digest)
except Exception as exc:
    print(f"fetch_error: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
)"

if [ -z "${REMOTE_DIGEST:-}" ]; then
  echo "ERROR: failed to fetch remote digest"
  exit 2
fi
echo "remote_digest=$REMOTE_DIGEST"

need_deploy=0
if [ "$FORCE_DEPLOY" = "true" ] || [ "$FORCE_DEPLOY" = "True" ] || [ "$FORCE_DEPLOY" = "1" ]; then
  echo "reason=forced"
  need_deploy=1
elif [ -n "$CURRENT_DIGEST" ] && [ "$CURRENT_DIGEST" = "$REMOTE_DIGEST" ]; then
  echo "up-to-date, no deploy"
  exit 0
else
  echo "reason=digest-changed ${CURRENT_DIGEST:-none} -> $REMOTE_DIGEST"
  need_deploy=1
fi

if [ "$need_deploy" -ne 1 ]; then
  exit 0
fi

if [ ! -f "$FLY_TOML" ]; then
  echo "ERROR: missing $FLY_TOML"
  exit 1
fi

echo "deploying ${IMAGE_REPO}:${IMAGE_TAG} to $APP"
flyctl deploy \
  -a "$APP" \
  --config "$FLY_TOML" \
  --image "${IMAGE_REPO}:${IMAGE_TAG}" \
  --remote-only \
  --yes

ok=0
code=000
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  code="$(curl -s -o /tmp/sub2api_health_body -w '%{http_code}' -m 15 "https://${APP}.fly.dev/health" || echo 000)"
  echo "health attempt $i: HTTP $code"
  if [ "$code" = "200" ]; then
    ok=1
    cat /tmp/sub2api_health_body || true
    echo
    break
  fi
  sleep 5
done

if [ "$ok" -ne 1 ]; then
  echo "ERROR: deploy finished but /health not 200 (last=$code)"
  exit 3
fi

echo "SUCCESS health=ok"
flyctl image show -a "$APP" || true
flyctl status -a "$APP" || true
