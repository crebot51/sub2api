#!/usr/bin/env bash
# Compare Docker Hub weishaw/sub2api:latest (linux/amd64) with local running image;
# pull+recreate only when digest differs (or FORCE=true).
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH}"

IMAGE_REPO="${SUB2API_IMAGE_REPO:-weishaw/sub2api}"
IMAGE_TAG="${SUB2API_IMAGE_TAG:-latest}"
PLATFORM_OS="${SUB2API_PLATFORM_OS:-linux}"
PLATFORM_ARCH="${SUB2API_PLATFORM_ARCH:-amd64}"
WORKDIR="${SUB2API_WORKDIR:-/root/sub2api}"
STATE_DIR="${SUB2API_STATE_DIR:-/root/sub2api/auto-update}"
LOG_FILE="${STATE_DIR}/auto-update.log"
LOCK_FILE="${STATE_DIR}/auto-update.lock"
FORCE="${FORCE:-false}"
HEALTH_URL="${SUB2API_HEALTH_URL:-http://127.0.0.1:8080/health}"
MAX_LOG_BYTES=1048576

mkdir -p "$STATE_DIR" "$WORKDIR"
touch "$LOG_FILE"

log() {
  local ts msg
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  msg="[$ts] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another auto-update is running, exit"
  exit 0
fi

if [ -f "$LOG_FILE" ] && [ "$(wc -c <"$LOG_FILE")" -gt "$MAX_LOG_BYTES" ]; then
  mv "$LOG_FILE" "${LOG_FILE}.1" || true
  : >"$LOG_FILE"
fi

log "check start image=${IMAGE_REPO}:${IMAGE_TAG} platform=${PLATFORM_OS}/${PLATFORM_ARCH} force=$FORCE"

CURRENT_DIGEST=""
if docker inspect sub2api >/dev/null 2>&1; then
  CURRENT_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' sub2api 2>/dev/null | sed -n 's/.*@//p' || true)"
  if [ -z "$CURRENT_DIGEST" ]; then
    CURRENT_DIGEST="$(docker inspect --format='{{.Image}}' sub2api 2>/dev/null || true)"
  fi
fi
# Prefer digest file
if [ -f "$STATE_DIR/current.digest" ]; then
  SAVED="$(tr -d ' \n' <"$STATE_DIR/current.digest")"
  [ -n "$SAVED" ] && CURRENT_DIGEST="$SAVED"
fi
log "current_digest=${CURRENT_DIGEST:-none}"

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
PY
)"

if [ -z "${REMOTE_DIGEST:-}" ]; then
  log "ERROR: failed to fetch remote digest"
  exit 2
fi
echo "$REMOTE_DIGEST" > "$STATE_DIR/remote.digest"
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/last_check"
log "remote_digest=$REMOTE_DIGEST"

need=0
if [ "$FORCE" = "true" ] || [ "$FORCE" = "1" ]; then
  log "reason=forced"
  need=1
elif [ -n "$CURRENT_DIGEST" ] && [ "$CURRENT_DIGEST" = "$REMOTE_DIGEST" ]; then
  log "up-to-date, no deploy"
  exit 0
else
  log "reason=digest-changed ${CURRENT_DIGEST:-none} -> $REMOTE_DIGEST"
  need=1
fi

if [ "$need" -ne 1 ]; then
  exit 0
fi

cd "$WORKDIR"
log "pulling ${IMAGE_REPO}:${IMAGE_TAG}"
docker compose pull sub2api
log "recreating sub2api"
docker compose up -d --no-deps sub2api

ok=0
code=000
for i in $(seq 1 24); do
  code="$(curl -s -o /tmp/sub2api_health_body -w '%{http_code}' -m 10 "$HEALTH_URL" || echo 000)"
  log "health attempt $i: HTTP $code"
  if [ "$code" = "200" ]; then
    ok=1
    break
  fi
  sleep 5
done

if [ "$ok" -ne 1 ]; then
  log "ERROR: update finished but health not 200 (last=$code)"
  docker compose logs --tail=50 sub2api || true
  exit 3
fi

echo "$REMOTE_DIGEST" > "$STATE_DIR/current.digest"
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/last_success"
log "SUCCESS health=ok digest=$REMOTE_DIGEST"
