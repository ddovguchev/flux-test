#!/usr/bin/env bash
set -euo pipefail

# Sync all repos from all groups the user can access.
# Uses GitLab API + PAT (read_api) and clones/pulls via SSH URLs.

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing: $1"; exit 1; }; }
require_cmd git
require_cmd curl
require_cmd jq

GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
GITLAB_URL="${GITLAB_URL%/}"

if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  read -r -s -p "GitLab token: " GITLAB_TOKEN
  echo
fi
[[ -z "${GITLAB_TOKEN:-}" ]] && { echo "[ERROR] Set GITLAB_TOKEN"; exit 1; }

ROOT_DIR="${GITLAB_ROOT_DIR:-}"
if [[ -z "$ROOT_DIR" ]]; then
  read -r -p "Local root directory for repos: " ROOT_DIR
fi
[[ -z "$ROOT_DIR" ]] && { echo "[ERROR] Set GITLAB_ROOT_DIR"; exit 1; }

ROOT_DIR="$(realpath -m "$ROOT_DIR")"
mkdir -p "$ROOT_DIR"

echo "[INFO ] GitLab: $GITLAB_URL"
echo "[INFO ] Root:   $ROOT_DIR"

api_get() {
  local url="$1"
  local body status
  body="$(curl -sS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" -w '\n%{http_code}' "$url")" || return 1
  status="$(tail -n1 <<<"$body")"
  body="$(sed '$d' <<<"$body")"
  if [[ "$status" != "200" ]]; then
    echo "[ERROR] API $status: $url"
    [[ -n "$body" ]] && echo "$body"
    return 1
  fi
  printf '%s' "$body"
}

who="$(api_get "$GITLAB_URL/api/v4/user")"
user_id="$(jq -r '.id // empty' <<<"$who")"
user_name="$(jq -r '.username // empty' <<<"$who")"
[[ -z "$user_id" ]] && { echo "[ERROR] Invalid token or API unavailable"; exit 1; }
echo "[INFO ] Authenticated as: $user_name (id=$user_id)"

sync_repo() {
  local ssh_url="$1" path_ns="$2" dir="$ROOT_DIR/$path_ns"
  mkdir -p "$(dirname "$dir")"
  if [[ -d "$dir/.git" ]]; then
    echo "[PULL ] $path_ns"
    git -C "$dir" pull --ff-only || echo "[WARN ] Pull failed: $path_ns"
  elif [[ -d "$dir" ]]; then
    echo "[SKIP ] $path_ns (exists, not git)"
  else
    echo "[CLONE] $path_ns"
    git clone "$ssh_url" "$dir" || echo "[WARN ] Clone failed: $path_ns"
  fi
}

declare -A SEEN_GROUPS=()
declare -A SEEN_PROJECTS=()
count=0
per_page=100

# 1) groups directly from user
page=1
while :; do
  resp="$(api_get "$GITLAB_URL/api/v4/users/$user_id/groups?per_page=$per_page&page=$page" || true)"
  [[ -z "$resp" ]] && break
  [[ "$(jq 'length' <<<"$resp" 2>/dev/null || echo 0)" -eq 0 ]] && break
  while IFS= read -r gid; do
    [[ -z "$gid" ]] && continue
    SEEN_GROUPS["$gid"]=1
  done < <(jq -r '.[].id' <<<"$resp")
  page=$((page + 1))
done

# 2) fallback group listing (some instances return extra memberships here)
page=1
while :; do
  resp="$(api_get "$GITLAB_URL/api/v4/groups?min_access_level=10&all_available=true&per_page=$per_page&page=$page" || true)"
  [[ -z "$resp" ]] && break
  [[ "$(jq 'length' <<<"$resp" 2>/dev/null || echo 0)" -eq 0 ]] && break
  while IFS= read -r gid; do
    [[ -z "$gid" ]] && continue
    SEEN_GROUPS["$gid"]=1
  done < <(jq -r '.[].id' <<<"$resp")
  page=$((page + 1))
done

echo "[INFO ] Groups discovered: ${#SEEN_GROUPS[@]}"

# 3) pull projects from each group (with subgroups)
for gid in "${!SEEN_GROUPS[@]}"; do
  page=1
  while :; do
    url="$GITLAB_URL/api/v4/groups/$gid/projects?include_subgroups=true&with_shared=true&simple=true&per_page=$per_page&page=$page"
    resp="$(api_get "$url" || true)"
    [[ -z "$resp" ]] && break
    [[ "$(jq 'length' <<<"$resp" 2>/dev/null || echo 0)" -eq 0 ]] && break
    while IFS=$'\t' read -r ssh_url path_ns; do
      [[ -z "$ssh_url" || -z "$path_ns" ]] && continue
      if [[ -n "${SEEN_PROJECTS[$path_ns]:-}" ]]; then
        continue
      fi
      SEEN_PROJECTS["$path_ns"]=1
      sync_repo "$ssh_url" "$path_ns"
      count=$((count + 1))
    done < <(jq -r '.[] | [.ssh_url_to_repo, .path_with_namespace] | @tsv' <<<"$resp")
    page=$((page + 1))
  done
done

# 4) owned projects fallback
page=1
while :; do
  resp="$(api_get "$GITLAB_URL/api/v4/users/$user_id/projects?owned=true&simple=true&per_page=$per_page&page=$page" || true)"
  [[ -z "$resp" ]] && break
  [[ "$(jq 'length' <<<"$resp" 2>/dev/null || echo 0)" -eq 0 ]] && break
  while IFS=$'\t' read -r ssh_url path_ns; do
    [[ -z "$ssh_url" || -z "$path_ns" ]] && continue
    [[ -n "${SEEN_PROJECTS[$path_ns]:-}" ]] && continue
    SEEN_PROJECTS["$path_ns"]=1
    sync_repo "$ssh_url" "$path_ns"
    count=$((count + 1))
  done < <(jq -r '.[] | [.ssh_url_to_repo, .path_with_namespace] | @tsv' <<<"$resp")
  page=$((page + 1))
done

echo "[DONE ] Repositories processed: $count"
if [[ "$count" -eq 0 ]]; then
  echo "[HINT ] Token is valid but no repositories were returned."
  echo "       Check group/project membership and PAT scope read_api."
fi
