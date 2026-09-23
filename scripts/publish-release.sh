#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Publish a release that `just release <version>` has already cut: push the tag
# and create the GitHub Release with the assets the manifest describes.
#
#   ./scripts/publish-release.sh <version> [--dry-run]
#
# Refuses unless the tag points at HEAD, the worktree is clean, the manifest
# was written at HEAD from a clean tree, and every asset's SHA-256 equals the
# manifest's. That last check is what makes "attach exactly what the release
# built" enforceable: consumers verify downloads against the manifest's
# digests, so the attached bytes must be the ones that were hashed. (A DPM
# rebuild of unchanged sources on the same toolchain reproduced identical
# bytes when this was checked; the guard does not rely on that.) --dry-run
# performs every check and prints the commands without pushing or creating
# anything.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

version="${1:-}"; dry_run=0
[[ -n "$version" ]] || { echo "usage: $0 <version> [--dry-run]" >&2; exit 2; }
[[ "${2:-}" == "--dry-run" ]] && dry_run=1
tag="v$version"
notes="docs/release-notes/$tag.md"
manifest="conditional-lock-release.json"
fail() { echo "publish-release: $*" >&2; exit 1; }

[[ -f "$notes" ]] || fail "$notes does not exist; write the release notes first"
[[ -f "$manifest" ]] || fail "$manifest does not exist; run 'just release $version' first"
[[ -z "$(git status --porcelain)" ]] || fail "worktree is dirty; the tag and manifest must describe committed bytes"

head_sha="$(git rev-parse HEAD)"
if git rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null; then
  tag_sha="$(git rev-parse "$tag^{commit}")"
  [[ "$tag_sha" == "$head_sha" ]] || fail "tag $tag points at ${tag_sha:0:12}, HEAD is ${head_sha:0:12}; check out the tagged commit"
else
  if [[ "$dry_run" -eq 1 ]]; then echo "publish-release: (dry run) tag $tag does not exist yet; 'just release $version' creates it"
  else fail "tag $tag does not exist; run 'just release $version' first"; fi
fi

# The manifest must be the real one, written at HEAD from a clean tree.
python3 - "$manifest" "$version" "$head_sha" <<'PY'
import json, sys
manifest, version, head = sys.argv[1:4]
m = json.load(open(manifest))
if m.get("dry_run"):
    raise SystemExit(f"publish-release: {manifest} is a dry-run manifest; run 'just release {version}'")
if m.get("release") not in (version, f"v{version}"):
    raise SystemExit(f"publish-release: {manifest} is for {m.get('release')!r}, not {version}")
if m.get("git_commit") != head:
    raise SystemExit(f"publish-release: {manifest} was written at {str(m.get('git_commit'))[:12]}, HEAD is {head[:12]}; rerun 'just release {version}'")
PY

# Every attached asset must have the digest the manifest recorded. The list is
# read first so a malformed manifest fails here instead of yielding no assets.
attached_list="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
rows = [p for p in m["packages"] if p.get("attached")]
if not rows:
    raise SystemExit("no attached packages in the manifest")
for p in rows:
    print(p["file"] + "\t" + p["dar_sha256"])
' "$manifest")" || fail "cannot read the attached packages from $manifest"
assets=()
while IFS=$'\t' read -r file expected; do
  [[ -n "$file" ]] || continue
  path="$(find packages -path "*/.daml/dist/$file" -type f | head -1)"
  [[ -n "$path" ]] || fail "$file is in the manifest but not under packages/*/.daml/dist; rerun 'just release $version'"
  actual="$(shasum -a 256 "$path" | cut -d' ' -f1)"
  [[ "$actual" == "$expected" ]] || fail "$file has SHA-256 ${actual:0:12}..., the manifest says ${expected:0:12}...; the DAR was rebuilt after the manifest, rerun 'just release $version'"
  assets+=("$path")
done <<< "$attached_list"
[[ "${#assets[@]}" -eq 3 ]] || fail "expected 3 attached DARs, the manifest lists ${#assets[@]}"
hv_expected="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hash_vectors_sha256"])' "$manifest")"
hv_actual="$(shasum -a 256 fixtures/hash-vectors.json | cut -d' ' -f1)"
[[ "$hv_actual" == "$hv_expected" ]] || fail "fixtures/hash-vectors.json digest does not match the manifest"
echo "publish-release: ${#assets[@]} DAR asset(s) match the manifest"

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"
if gh release view "$tag" >/dev/null 2>&1; then fail "GitHub Release $tag already exists"; fi

cmd_push=(git push origin "$tag")
cmd_release=(gh release create "$tag" --verify-tag --title "conditional-holding-lock $tag" --notes-file "$notes" "${assets[@]}" "$manifest" fixtures/hash-vectors.json)
if [[ "$dry_run" -eq 1 ]]; then
  echo "publish-release: (dry run) would run:"
  printf '  %q ' "${cmd_push[@]}"; echo
  printf '  %q ' "${cmd_release[@]}"; echo
  exit 0
fi
"${cmd_push[@]}"
"${cmd_release[@]}"
echo "publish-release: published $tag"
