#!/bin/bash
# in: final package.json diffs  out: PR markdown

bump_priority() {
  case "$1" in
    *Major*) echo 0 ;;
    *Minor*) echo 1 ;;
    *Patch*) echo 2 ;;
    *) echo 3 ;;
  esac
}

semver_bump_label() {
  local om oi op nm ni np
  part() { echo "$1" | sed -E 's/^v?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/'; }
  read -r om oi op < <(part "$1")
  read -r nm ni np < <(part "$2")
  if [[ "$nm" -gt "$om" ]]; then echo "🔴 Major"
  elif [[ "$ni" -gt "$oi" ]]; then echo "⚠️ Minor"
  elif [[ "$np" -gt "$op" ]]; then echo "✅ Patch"
  else echo "—"
  fi
}

publish_date_human() {
  local pkg=$1 version=$2 stamp
  stamp=$(npm view "$pkg" time --json | jq -r --arg v "$version" '.[$v] | split(".")[0]')
  date -j -f "%Y-%m-%dT%H:%M:%S" "$stamp" "+%B %-d" 2>/dev/null \
    || date -u -d "${stamp}Z" "+%B %d" 2>/dev/null \
    || echo "$stamp"
}

resolve_compare_tags() {
  local pkg=$1 old_ver=$2 new_ver=$3 owner_repo=$4 prefix candidate_old candidate_new
  for prefix in "v" "${pkg}@"; do
    candidate_old="${prefix}${old_ver}"
    candidate_new="${prefix}${new_ver}"
    if gh api "repos/${owner_repo}/git/ref/tags/${candidate_old}" --jq .ref >/dev/null 2>&1 \
      && gh api "repos/${owner_repo}/git/ref/tags/${candidate_new}" --jq .ref >/dev/null 2>&1; then
      printf '%s\t%s\n' "$candidate_old" "$candidate_new"
      return 0
    fi
  done
  return 1
}

stack_release_notes() {
  local owner_repo=$1 pkg=$2 old=$3 new=$4 tag_fallback=$5
  local tmpdir line tag ver n page oldest_in_page first release_json url
  tmpdir=$(mktemp -d)

  version_from_tag() {
    case "$1" in
      v*) echo "${1#v}" ;;
      "${pkg}"@*) echo "${1#${pkg}@}" ;;
    esac
  }

  release_in_range() {
    local v=$1
    [[ -z "$v" || "$v" == "$old" ]] && return 1
    [[ "$(printf '%s\n' "$old" "$v" | sort -V | tail -1)" == "$v" ]] \
      && [[ "$(printf '%s\n' "$v" "$new" | sort -V | tail -1)" == "$new" ]]
  }

  fetch_release() {
    gh release view "$2" --repo "$1" --json body,url 2>/dev/null \
      || gh api "repos/$1/releases/tags/$2" --jq '{body: .body, url: .html_url}'
  }

  emit_version_details() {
    local ver=$1 url=$2
    cat <<EOF
<details>
<summary>${ver}</summary>

[Source](${url})

$(cat "$tmpdir/$ver.body")

</details>
EOF
  }

  page=1
  while true; do
    n=0
    oldest_in_page=
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      n=$((n + 1))
      tag=$(echo "$line" | jq -r '.tag_name')
      ver=$(version_from_tag "$tag")
      if [[ -n "$ver" ]]; then
        oldest_in_page=$(printf '%s\n%s\n' "${oldest_in_page:-$ver}" "$ver" | sort -V | head -1)
      fi
      release_in_range "$ver" || continue
      echo "$line" | jq -r '.html_url' > "$tmpdir/$ver.url"
      echo "$line" | jq -r '.body' > "$tmpdir/$ver.body"
      echo "$ver" >> "$tmpdir/versions"
    done < <(gh api "repos/${owner_repo}/releases?per_page=100&page=${page}" -q '.[] | {tag_name, html_url, body}' 2>/dev/null)

    [[ $n -eq 0 ]] && break
    [[ $n -lt 100 ]] && break
    [[ -n "$oldest_in_page" ]] && [[ "$(printf '%s\n' "$oldest_in_page" "$old" | sort -V | head -1)" == "$oldest_in_page" ]] && break
    page=$((page + 1))
  done

  if [[ ! -f "$tmpdir/versions" ]]; then
    release_json=$(fetch_release "$owner_repo" "$tag_fallback")
    url=$(echo "$release_json" | jq -r '.url')
    echo "$release_json" | jq -r '.body' > "$tmpdir/$new.body"
    emit_version_details "$new" "$url"
    rm -rf "$tmpdir"
    return 0
  fi

  first=1
  while read -r ver; do
    [[ -f "$tmpdir/$ver.body" ]] || continue
    [[ -z "$first" ]] && echo ""
    first=
    emit_version_details "$ver" "$(cat "$tmpdir/$ver.url")"
  done < <(sort -V -r "$tmpdir/versions")
  rm -rf "$tmpdir"
}

TABLE_ROWS=()
RELEASE_BLOCKS=()
SORT_KEYS=()
PKG_NAMES=()
OLD_VERSIONS=()
NEW_VERSIONS=()
i=0

changed_versions() {
  python3 <<'PY'
import json
import re
import subprocess

VERSION = re.compile(r"^[~^]?v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
SECTIONS = ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies", "catalog")
BASE = subprocess.check_output(
    "git merge-base HEAD origin/main 2>/dev/null || git rev-parse HEAD^",
    shell=True,
    text=True,
).strip()

def concrete(value):
    return isinstance(value, str) and VERSION.match(value)

def clean(value):
    return value.lstrip("^~v")

files = subprocess.check_output(
    ["git", "diff", "--name-only", BASE, "--", "package.json", "*/package.json"],
    text=True,
).splitlines()

seen = set()
for path in files:
    try:
        old = json.loads(subprocess.check_output(["git", "show", f"{BASE}:{path}"], text=True))
        with open(path) as f:
            new = json.load(f)
    except Exception:
        continue

    for section in SECTIONS:
        old_deps = old.get(section, {})
        new_deps = new.get(section, {})
        if not isinstance(old_deps, dict) or not isinstance(new_deps, dict):
            continue
        for package in sorted(set(old_deps) | set(new_deps)):
            old_version = old_deps.get(package)
            new_version = new_deps.get(package)
            key = (package, clean(str(old_version)), clean(str(new_version)))
            if old_version == new_version or not concrete(old_version) or not concrete(new_version) or key in seen:
                continue
            seen.add(key)
            print("\t".join(key))
PY
}

while IFS=$'\t' read -r pkg old new; do
  [[ -n "$pkg" ]] || continue

  owner_repo=$(npm view "$pkg" repository.url | sed -E 's#.*github.com[:/]([^/]+/[^/.]+)\.git.*#\1#')
  homepage=$(npm view "$pkg" homepage)
  source_url="https://github.com/${owner_repo}"
  release_date=$(publish_date_human "$pkg" "$new")
  bump=$(semver_bump_label "$old" "$new")
  bump_emoji=${bump%% *}

  IFS=$'\t' read -r tag_old tag_new < <(resolve_compare_tags "$pkg" "$old" "$new" "$owner_repo")
  compare="https://github.com/${owner_repo}/compare/${tag_old}...${tag_new}"

  release_notes=$(stack_release_notes "$owner_repo" "$pkg" "$old" "$new" "$tag_new")

  TABLE_ROWS[$i]="| [${pkg}](${homepage}) ([source](${source_url})) | [\`${old}\` → \`${new}\`](${compare}) | ${bump} | ${release_date} |"
  PKG_NAMES[$i]=$pkg
  OLD_VERSIONS[$i]=$old
  NEW_VERSIONS[$i]=$new
  RELEASE_BLOCKS[$i]="$(cat <<EOF
#### ${bump_emoji} ${pkg} (${owner_repo})

- _Summary generating..._

<details>
<summary>Release Notes</summary>

${release_notes}

</details>
EOF
)"
  SORT_KEYS+=("$(bump_priority "$bump")	${pkg}	${i}")
  i=$((i + 1))
done < <(changed_versions)

if [[ $i -eq 0 ]]; then
  echo "No package.json version diffs found." >&2
  exit 1
fi

echo "| Package | Change | Bump | Release Date |"
echo "|---|---|---|---|"
while IFS=$'\t' read -r _ _ idx; do
  echo "${TABLE_ROWS[$idx]}"
done < <(printf '%s\n' "${SORT_KEYS[@]}" | LC_ALL=C sort -t$'\t' -k1,1n -k2,2)

echo ""
echo "---"
echo ""
echo "### Summary"
echo ""
while IFS=$'\t' read -r _ _ idx; do
  pkg=${PKG_NAMES[$idx]}
  echo "- **${pkg}**: _Summary generating..._"
done < <(printf '%s\n' "${SORT_KEYS[@]}" | LC_ALL=C sort -t$'\t' -k1,1n -k2,2)
echo ""
echo "---"
echo ""
echo "### Release Notes"
echo ""
while IFS=$'\t' read -r _ _ idx; do
  echo "${RELEASE_BLOCKS[$idx]}"
  echo ""
done < <(printf '%s\n' "${SORT_KEYS[@]}" | LC_ALL=C sort -t$'\t' -k1,1n -k2,2)

echo ""
echo "---"
echo ""
echo "### Project Impact"
echo ""
echo "#### Breaking Changes"
echo ""
echo "- Breaking changes generating."
echo ""
echo "#### Opportunities"
echo ""
echo "- Opportunities generating."
echo ""
