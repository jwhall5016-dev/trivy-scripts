#!/usr/bin/env bash
#
# Copy a snapshot of the default branch from a source Git repo into an SBIR
# (or other) target repo on a branch forked from target/main, so GitHub can
# open a PR (shared history). Optionally preserves target's .github/CODEOWNERS
# and .github/pull_request_template.md when they exist on the target default
# branch before the replace.
#
# Requires: git, rsync (git-lfs optional; without it, LFS repos clone with pointer stubs)
#
# Examples:
#   ./scripts/sbir_repo_snapshot.sh \
#     --source https://github.com/slingshot-aerospace-inc/simulation-connector.git \
#     --target https://github.com/slingshot-aerospace-inc/SBIR-simulation-connector.git
#
#   ./scripts/sbir_repo_snapshot.sh --manifest ./scripts/sbir_repo_snapshot.manifest.example
#

set -euo pipefail

SOURCE_URL=""
TARGET_URL=""
MANIFEST=""
SOURCE_REF="main"
TARGET_REF="main"
SNAPSHOT_BRANCH=""
DRY_RUN=0
NO_PUSH=0
PRESERVE_GITHUB=1
KEEP_WORKDIR=0

usage() {
  cat <<'EOF'
sbir_repo_snapshot — copy a source repo tree onto a target repo branch forked from target/main (for PRs).

Usage:
  sbir_repo_snapshot.sh --source <git-url> --target <git-url> [options]
  sbir_repo_snapshot.sh --manifest <file> [options]

Options:
  --source URL       Upstream repo (HTTPS or SSH) to snapshot.
  --target URL       Destination repo; receives a force-pushed snapshot branch.
  --manifest PATH    CSV file: source_url,target_url[,snapshot_branch] per line.
                     Lines starting with # and blank lines are ignored.
  --source-ref REF   Branch or tag to copy from source (default: main).
  --target-ref REF   Branch on target to branch from (default: main).
  --snapshot-branch  Name of branch to create/update on target (default:
                     snapshot-<source-repo-basename>).
  --dry-run          Print actions only; no clone/push.
  --no-push          Clone and commit locally under a temp dir, but do not push.
  --no-preserve-github
                     Allow replacing .github/CODEOWNERS and
                     pull_request_template.md from the source tree.
  --keep-workdir     Keep the temp clone directory (prints path); default is delete.

EOF
}

die() { echo "error: $*" >&2; exit 1; }

cleanup_snap_workspace() {
  local w="$1"
  trap - EXIT 2>/dev/null || true
  if [[ "$KEEP_WORKDIR" -eq 1 ]]; then
    echo "kept workdir: $w" >&2
    return 0
  fi
  rm -rf "$w"
}

repo_slug_from_git_url() {
  local u="$1"
  u="${u%.git}"
  u="${u%/}"
  echo "${u##*/}"
}

default_snapshot_branch() {
  echo "snapshot-$(repo_slug_from_git_url "$1")"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE_URL="$2"; shift 2 ;;
    --target) TARGET_URL="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --source-ref) SOURCE_REF="$2"; shift 2 ;;
    --target-ref) TARGET_REF="$2"; shift 2 ;;
    --snapshot-branch) SNAPSHOT_BRANCH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-push) NO_PUSH=1; shift ;;
    --no-preserve-github) PRESERVE_GITHUB=0; shift ;;
    --keep-workdir) KEEP_WORKDIR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

run_snapshot() {
  local src_url="$1"
  local tgt_url="$2"
  local snap_branch="${3:-}"

  [[ -n "$src_url" ]] || die "missing source URL"
  [[ -n "$tgt_url" ]] || die "missing target URL"
  if [[ -z "$snap_branch" ]]; then
    snap_branch="$(default_snapshot_branch "$src_url")"
  fi

  local slug
  slug="$(repo_slug_from_git_url "$src_url")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would snapshot $src_url ($SOURCE_REF) -> $tgt_url branch $snap_branch (from $TARGET_REF)"
    return 0
  fi

  local work preserve
  work="$(mktemp -d "${TMPDIR:-/tmp}/sbir-snapshot.XXXXXX")"
  preserve="$work/preserve-github"
  mkdir -p "$preserve"

  if [[ "$KEEP_WORKDIR" -eq 0 ]]; then
    trap 'rm -rf "$work"' EXIT
  fi

  # macOS bash + set -u: empty "${array[@]}" is an error; avoid optional-prefix arrays.
  local have_git_lfs=1
  command -v git-lfs >/dev/null 2>&1 || have_git_lfs=0
  if [[ "$have_git_lfs" -eq 0 ]]; then
    echo "warning: git-lfs not in PATH; cloning with GIT_LFS_SKIP_SMUDGE=1 (LFS files stay as pointer text)." >&2
    echo "         For real LFS blobs: brew install git-lfs && git lfs install" >&2
  fi

  echo "==> cloning source: $slug ($SOURCE_REF)"
  if [[ "$have_git_lfs" -eq 0 ]]; then
    GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --single-branch -b "$SOURCE_REF" "$src_url" "$work/source"
  else
    git clone --depth 1 --single-branch -b "$SOURCE_REF" "$src_url" "$work/source"
  fi

  echo "==> cloning target (for $TARGET_REF + push)"
  if [[ "$have_git_lfs" -eq 0 ]]; then
    GIT_LFS_SKIP_SMUDGE=1 git clone --single-branch -b "$TARGET_REF" "$tgt_url" "$work/target"
  else
    git clone --single-branch -b "$TARGET_REF" "$tgt_url" "$work/target"
  fi

  cd "$work/target"
  git pull origin "$TARGET_REF"

  if [[ "$PRESERVE_GITHUB" -eq 1 ]]; then
    [[ -f .github/CODEOWNERS ]] && cp .github/CODEOWNERS "$preserve/CODEOWNERS"
    [[ -f .github/pull_request_template.md ]] && cp .github/pull_request_template.md "$preserve/pull_request_template.md"
  fi

  git checkout -B "$snap_branch"
  git rm -rf . >/dev/null

  rsync -a "$work/source/" "$work/target/" --exclude .git

  if [[ "$PRESERVE_GITHUB" -eq 1 ]]; then
    [[ -f "$preserve/CODEOWNERS" ]] && mkdir -p .github && cp "$preserve/CODEOWNERS" .github/CODEOWNERS
    [[ -f "$preserve/pull_request_template.md" ]] && mkdir -p .github && cp "$preserve/pull_request_template.md" .github/pull_request_template.md
  fi

  git add -A
  git commit -m "Snapshot: replace tree with ${slug} ${SOURCE_REF}

Upstream: ${src_url}
Preserve target .github/CODEOWNERS and pull_request_template.md when present: $(
    [[ "$PRESERVE_GITHUB" -eq 1 ]] && echo yes || echo no
)"

  if [[ "$NO_PUSH" -eq 1 ]]; then
    echo "==> --no-push: commit created in $work/target (branch $snap_branch)"
    cleanup_snap_workspace "$work"
    return 0
  fi

  echo "==> pushing $snap_branch to origin (force)"
  git push -u -f origin "$snap_branch"
  echo "==> done: open a PR on the target repo: $snap_branch -> $TARGET_REF"
  cleanup_snap_workspace "$work"
}

run_manifest() {
  local f="$1"
  [[ -f "$f" ]] || die "manifest not found: $f"

  local line n src tgt branch lineno
  n=0
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue

    src="$(trim "${line%%,*}")"
    local rest="${line#*,}"
    if [[ "$rest" == "$line" ]]; then
      die "manifest line $lineno: expected source,target[,snapshot_branch] (comma-separated)"
    fi
    if [[ "$rest" == *","* ]]; then
      tgt="$(trim "${rest%%,*}")"
      branch="$(trim "${rest#*,}")"
    else
      tgt="$(trim "$rest")"
      branch=""
    fi
    [[ -n "$src" && -n "$tgt" ]] || die "manifest line $lineno: empty source or target"

    n=$((n + 1))
    echo ""
    echo "######## manifest entry $n ########"
    run_snapshot "$src" "$tgt" "${SNAPSHOT_BRANCH:-$branch}"
  done <"$f"

  echo ""
  echo "processed $n manifest entries"
}

if [[ -n "$MANIFEST" ]]; then
  [[ -z "$SOURCE_URL" && -z "$TARGET_URL" ]] || die "use either --manifest or --source/--target, not both"
  if [[ -n "$SNAPSHOT_BRANCH" ]]; then
    die "--snapshot-branch is not supported with --manifest (set per-line optional third column instead)"
  fi
  run_manifest "$MANIFEST"
elif [[ -n "$SOURCE_URL" && -n "$TARGET_URL" ]]; then
  run_snapshot "$SOURCE_URL" "$TARGET_URL" "$SNAPSHOT_BRANCH"
else
  die "provide --source and --target, or --manifest (see --help)"
fi
