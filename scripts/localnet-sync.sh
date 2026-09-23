#!/usr/bin/env bash
# Copyright (c) 2026 Long Run Advisory. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# localnet-sync.sh [<splice-tag>] [--check]
#
# Materializes localnet-overrides/splice-<tag>/ from the Splice release
# tag's cluster/compose/localnet/ tree, so the repo's localnet stack always
# equals the Splice version live on Canton Mainnet.
#
# With no positional argument, the tag is discovered by reading
# fixtures/runtime-versions.json's mainnet.info_url, curling it, and taking
# .sv.version. Passing a tag explicitly uses it verbatim and skips that
# lookup.
#
# The tag's commit SHA is resolved authoritatively against the GitHub API
# (via `gh`, falling back to a plain curl+python3 parse of the same
# endpoint). If SPLICE_SRC (default: ../splice relative to the repo root)
# is a local git checkout that has the tag, its tree is archived directly
# and its commit is checked against the GitHub-resolved SHA (mismatch is a
# hard error). Otherwise the tag's tarball is downloaded from GitHub and
# only cluster/compose/localnet/ is extracted from it.
#
# Every run (including the idempotent "nothing to do" case below) repins
# .env.localnet.example's IMAGE_TAG/LOCALNET_DIR, and, when the tag itself
# has actually changed, mechanically updates the tag/commit references
# hardcoded in README.md, NOTICE, and localnet-overrides/README.md.
#
# IDEMPOTENCY: if localnet-overrides/splice-<tag>/SOURCE.json already
# exists with the same tag, commit, and tree_sha256, and a freshly
# materialized copy of the tree is byte-identical to the existing one
# (diff -r, excluding SOURCE.json), the script leaves the directory and
# SOURCE.json untouched, prints a "nothing to do" line, and exits 0. This
# is deliberate: SOURCE.json carries a synced_at timestamp that would
# otherwise change on every run even when nothing else did. The pin/doc
# rewrite step above still runs on this path.
#
# --check: materialize to a temp dir outside the repo and diff -r
# (excluding SOURCE.json) against the current on-disk tree. Exits 0 if
# identical, 1 with the diff otherwise. Never modifies the repo.
#
# Env:
#   SPLICE_SRC  path to a local Splice git checkout (default: ../splice
#               relative to the repo root). Never written to.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERRIDES_DIR="$ROOT/localnet-overrides"
SPLICE_SRC="${SPLICE_SRC:-$ROOT/../splice}"
REPO="canton-network/splice"
CHECK_COMPAT="$ROOT/scripts/check-compatibility.py"

CHECK_MODE=0
TAG_ARG=""
for arg in "$@"; do
  case "$arg" in
    --check)
      CHECK_MODE=1
      ;;
    *)
      if [[ -n "$TAG_ARG" ]]; then
        echo "localnet-sync: unexpected extra argument: $arg" >&2
        exit 2
      fi
      TAG_ARG="$arg"
      ;;
  esac
done

die() {
  echo "localnet-sync: $*" >&2
  exit 1
}

# Compute the tree_sha256 digest via check-compatibility.py's tree_sha256()
# (also used by that script's localnet_row()), so the digest logic lives in
# exactly one place.
tree_digest() {
  python3 "$CHECK_COMPAT" --tree-digest "$1"
}

# Repin .env.localnet.example's IMAGE_TAG and LOCALNET_DIR to $TAG. Warns to
# stderr (rather than silently doing nothing) if a line to update cannot be
# found, and reports on stdout if the file actually changed.
rewrite_env_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "localnet-sync: warning: $file not found, cannot repin IMAGE_TAG/LOCALNET_DIR" >&2
    return
  fi
  local before after
  before="$(cat "$file")"
  if grep -qE '^IMAGE_TAG=' "$file"; then
    sed -i.bak -E "s#^IMAGE_TAG=.*#IMAGE_TAG=$TAG#" "$file"
    rm -f "$file.bak"
  else
    echo "localnet-sync: warning: $file has no IMAGE_TAG= line to update" >&2
  fi
  if grep -qE '^LOCALNET_DIR=\./localnet-overrides/splice-' "$file"; then
    sed -i.bak -E "s#^(LOCALNET_DIR=\./localnet-overrides/)splice-[^/[:space:]]*#\1splice-$TAG#" "$file"
    rm -f "$file.bak"
  else
    echo "localnet-sync: warning: $file has no LOCALNET_DIR=./localnet-overrides/splice-<tag> line to update" >&2
  fi
  after="$(cat "$file")"
  if [[ "$before" != "$after" ]]; then
    echo "localnet-sync: updated $file"
  fi
}

# Mechanically repin the tag/commit references hardcoded in doc files. Only
# called when the tag has actually changed. Exact string/regex replacements
# in python3, not sed, so they cannot partially match. Reports each file it
# actually changes.
rewrite_docs_files() {
  local old_tag="$1" new_tag="$2" old_commit="$3" new_commit="$4"
  shift 4
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    python3 - "$f" "$old_tag" "$new_tag" "$old_commit" "$new_commit" <<'PY'
import re
import sys

path, old_tag, new_tag, old_commit, new_commit = sys.argv[1:6]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
original = text

# localnet-overrides/splice-<old> and bare splice-<old> -> splice-<new>
text = text.replace(f"splice-{old_tag}", f"splice-{new_tag}")

# tag `<old>` and tag <old> -> tag `<new>` / tag <new>
text = re.sub(r"tag `" + re.escape(old_tag) + r"`", f"tag `{new_tag}`", text)
text = re.sub(r"\btag " + re.escape(old_tag) + r"\b", f"tag {new_tag}", text)

# the old 40-hex commit SHA -> the new SHA
if old_commit and re.fullmatch(r"[0-9a-f]{40}", old_commit):
    text = re.sub(re.escape(old_commit), new_commit, text)

if text != original:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"localnet-sync: updated {path}")
PY
  done
}

TMP_DIRS=()
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    rm -rf "$d"
  done
}
trap cleanup EXIT

mainnet_splice_observed="null"
if [[ -n "$TAG_ARG" ]]; then
  TAG="$TAG_ARG"
else
  RUNTIME_VERSIONS_FILE="$ROOT/fixtures/runtime-versions.json"
  [[ -f "$RUNTIME_VERSIONS_FILE" ]] || die "cannot find $RUNTIME_VERSIONS_FILE"
  INFO_URL="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data["mainnet"]["info_url"])
' "$RUNTIME_VERSIONS_FILE")"
  [[ -n "$INFO_URL" ]] || die "mainnet.info_url missing from $RUNTIME_VERSIONS_FILE"
  INFO_JSON="$(curl -fsS "$INFO_URL")" || die "failed to fetch $INFO_URL"
  TAG="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
print(data["sv"]["version"])
' "$INFO_JSON")"
  [[ -n "$TAG" ]] || die "could not read .sv.version from $INFO_URL"
  mainnet_splice_observed="\"$TAG\""
fi

[[ -n "$TAG" ]] || die "no Splice tag determined"

# --- Resolve the tag's commit SHA authoritatively against GitHub. ---
resolve_sha() {
  local ref_json type sha
  if command -v gh >/dev/null 2>&1 && ref_json="$(gh api "repos/$REPO/git/ref/tags/$TAG" 2>/dev/null)"; then
    type="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["object"]["type"])' "$ref_json")"
    sha="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["object"]["sha"])' "$ref_json")"
    if [[ "$type" == "tag" ]]; then
      sha="$(gh api "repos/$REPO/git/tags/$sha" --jq '.object.sha')"
    fi
    echo "$sha"
    return 0
  fi

  ref_json="$(curl -fsS "https://api.github.com/repos/$REPO/git/ref/tags/$TAG")" || return 1
  type="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["object"]["type"])' "$ref_json")"
  sha="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["object"]["sha"])' "$ref_json")"
  if [[ "$type" == "tag" ]]; then
    local tag_json
    tag_json="$(curl -fsS "https://api.github.com/repos/$REPO/git/tags/$sha")" || return 1
    sha="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["object"]["sha"])' "$tag_json")"
  fi
  echo "$sha"
}

GH_SHA="$(resolve_sha)" || die "could not resolve commit for tag $TAG via GitHub API"
[[ -n "$GH_SHA" ]] || die "could not resolve commit for tag $TAG via GitHub API"

# --- Materialize the tree into a fresh temp dir outside the repo. ---
WORK_BASE="${TMPDIR:-/tmp}"
WORK_PREFIX="localnet-sync"
if [[ "$CHECK_MODE" -eq 1 ]]; then
  WORK_PREFIX="localnet-sync-check"
fi
mkdir -p "$OVERRIDES_DIR"
WORK_DIR="$(mktemp -d "${WORK_BASE%/}/${WORK_PREFIX}.XXXXXXXX")"
TMP_DIRS+=("$WORK_DIR")
STAGE_DIR="$WORK_DIR/tree"
mkdir -p "$STAGE_DIR"

SOURCE_KIND=""
COMMIT="$GH_SHA"

if [[ -d "$SPLICE_SRC/.git" ]] && LOCAL_SHA="$(git -C "$SPLICE_SRC" rev-parse -q --verify "${TAG}^{commit}" 2>/dev/null)"; then
  if [[ "$LOCAL_SHA" != "$GH_SHA" ]]; then
    die "local checkout tag $TAG resolves to $LOCAL_SHA but GitHub resolves it to $GH_SHA"
  fi
  git -C "$SPLICE_SRC" archive "$TAG" cluster/compose/localnet | tar -x --strip-components=3 -C "$STAGE_DIR"
  SOURCE_KIND="local-checkout"
else
  TARBALL="$WORK_DIR/splice-$TAG.tar.gz"
  curl -fsS -L "https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz" -o "$TARBALL" \
    || die "failed to download tarball for tag $TAG"
  tar -xzf "$TARBALL" --strip-components=4 -C "$STAGE_DIR" "splice-${TAG}/cluster/compose/localnet" \
    || die "failed to extract cluster/compose/localnet from tarball"
  SOURCE_KIND="github-tarball"
fi

STAGE_TREE_SHA="$(tree_digest "$STAGE_DIR")"

TARGET_DIR="$OVERRIDES_DIR/splice-$TAG"
SYNCED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_source_json() {
  local dest="$1"
  python3 -c '
import json, sys
repository, tag, commit, source, path, synced_at, mainnet_observed, tree_sha256 = sys.argv[1:9]
mainnet_observed = None if mainnet_observed == "null" else mainnet_observed
doc = {
    "repository": repository,
    "tag": tag,
    "commit": commit,
    "source": source,
    "path": path,
    "synced_at": synced_at,
    "mainnet_splice_version_observed": mainnet_observed,
    "tree_sha256": tree_sha256,
}
with open(sys.argv[9], "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
' "$REPO" "$TAG" "$COMMIT" "$SOURCE_KIND" "cluster/compose/localnet" "$SYNCED_AT" \
  "$(python3 -c 'import sys; s=sys.argv[1]; print("null" if s=="null" else s.strip("\""))' "$mainnet_splice_observed")" \
  "$STAGE_TREE_SHA" \
  "$dest"
}

if [[ "$CHECK_MODE" -eq 1 ]]; then
  if [[ -d "$TARGET_DIR" ]]; then
    if diff -r -x SOURCE.json "$TARGET_DIR" "$STAGE_DIR" >"$WORK_DIR/diff.txt" 2>&1; then
      echo "localnet-sync: --check OK, $TARGET_DIR matches tag $TAG ($COMMIT)"
      exit 0
    else
      cat "$WORK_DIR/diff.txt"
      exit 1
    fi
  else
    echo "localnet-sync: --check FAILED, $TARGET_DIR does not exist" >&2
    exit 1
  fi
fi

# --- Determine the previously-synced tag/commit (if any) for the doc rewrite
#     step below, before anything on disk is touched. ---
OLD_TAG=""
OLD_COMMIT=""
for d in "$OVERRIDES_DIR"/splice-*; do
  [[ -d "$d" ]] || continue
  [[ -f "$d/SOURCE.json" ]] || continue
  t="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag",""))' "$d/SOURCE.json" 2>/dev/null || true)"
  if [[ -n "$t" && "$t" != "$TAG" ]]; then
    OLD_TAG="$t"
    OLD_COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit",""))' "$d/SOURCE.json" 2>/dev/null || true)"
    break
  fi
done

# --- Idempotency check. ---
NOTHING_TO_DO=0
if [[ -f "$TARGET_DIR/SOURCE.json" ]]; then
  EXISTING_TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tag",""))' "$TARGET_DIR/SOURCE.json" 2>/dev/null || true)"
  EXISTING_COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit",""))' "$TARGET_DIR/SOURCE.json" 2>/dev/null || true)"
  EXISTING_TREE_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("tree_sha256",""))' "$TARGET_DIR/SOURCE.json" 2>/dev/null || true)"
  if [[ "$EXISTING_TAG" == "$TAG" && "$EXISTING_COMMIT" == "$COMMIT" && "$EXISTING_TREE_SHA" == "$STAGE_TREE_SHA" ]]; then
    if diff -r -x SOURCE.json "$TARGET_DIR" "$STAGE_DIR" >/dev/null 2>&1; then
      NOTHING_TO_DO=1
    fi
  fi
fi

if [[ "$NOTHING_TO_DO" -eq 1 ]]; then
  SHORT_SHA="${COMMIT:0:7}"
  rewrite_env_file "$ROOT/.env.localnet.example"
  echo "localnet-sync: localnet-overrides/splice-$TAG already at $TAG ($SHORT_SHA); nothing to do"
  exit 0
fi

# --- Replace the target directory. ---
case "$TARGET_DIR" in
  "$OVERRIDES_DIR"/splice-*) ;;
  *) die "refusing to replace unexpected path: $TARGET_DIR" ;;
esac
write_source_json "$STAGE_DIR/SOURCE.json"
rm -rf "$TARGET_DIR"
mv "$STAGE_DIR" "$TARGET_DIR"

# --- Remove any other localnet-overrides/splice-*/ directories. ---
for d in "$OVERRIDES_DIR"/splice-*; do
  [[ -d "$d" ]] || continue
  [[ "$d" != "$TARGET_DIR" ]] || continue
  case "$d" in
    "$OVERRIDES_DIR"/splice-*) rm -rf "$d" ;;
    *) die "refusing to remove unexpected path: $d" ;;
  esac
done

# --- Update .env.localnet.example in place. ---
rewrite_env_file "$ROOT/.env.localnet.example"

# --- Repin doc files, only when the tag actually changed. ---
if [[ -n "$OLD_TAG" && "$OLD_TAG" != "$TAG" ]]; then
  rewrite_docs_files "$OLD_TAG" "$TAG" "$OLD_COMMIT" "$COMMIT" \
    "$ROOT/README.md" "$ROOT/NOTICE" "$ROOT/localnet-overrides/README.md"
fi

echo "localnet-sync: synced localnet-overrides/splice-$TAG to tag $TAG ($COMMIT) via $SOURCE_KIND"
