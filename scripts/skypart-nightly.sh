#!/usr/bin/env bash
# Nightly: merge upstream main into skypart/mobile (upstream + Skypart's phone
# fixes) and ship it to the "cmux connect" TestFlight when the phone app changed.
#
#   scripts/skypart-nightly.sh            # normal run (launchd, 03:00)
#   FORCE=1 scripts/skypart-nightly.sh    # ship even if upstream's phone code did not change
#   DRY_RUN=1 scripts/skypart-nightly.sh  # merge + test, no push, no ship
#
# A merge conflict, or upstream touching a file our own commits touch, goes to
# a headless Claude run that decides per fix: keep ours, or take upstream's when
# it covers the same problem. If it cannot decide, nothing ships.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH=skypart/mobile
LOG_DIR="$HOME/Library/Logs/cmux-skypart-nightly"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/$STAMP.log"
CMUX=/Applications/cmux.app/Contents/Resources/bin/cmux
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.3.0.app/Contents/Developer}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Upstream paths that end up in the iOS app.
PHONE_PATHS=(ios Packages/iOS Packages/Shared ghostty vendor/bonsplit)

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

notify() {
  "$CMUX" notify --title "cmux nightly" --body "$1" >/dev/null 2>&1 \
    || osascript -e "display notification \"${1//\"/}\" with title \"cmux nightly\"" || true
}
fail() { echo "FAIL: $1"; notify "ล้มเหลว: $1 (log: $LOG)"; exit 1; }

LOCK="$LOG_DIR/.lock"
mkdir "$LOCK" 2>/dev/null || { echo "another run holds $LOCK"; exit 0; }
trap 'rmdir "$LOCK"' EXIT

cd "$REPO"
echo "== $STAMP nightly in $REPO"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || fail "worktree is not on $BRANCH"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "worktree has uncommitted changes"

git fetch -q origin main
git fetch -q fork
PREV_UP="$(git merge-base HEAD origin/main)"
UP="$(git rev-parse origin/main)"
OURS_BEFORE="$(git rev-parse HEAD)"

if git diff --quiet "$PREV_UP" "$UP" -- "${PHONE_PATHS[@]}" && [[ -z "${FORCE:-}" ]]; then
  echo "upstream phone code unchanged since ${PREV_UP:0:11}; nothing to ship"
  exit 0
fi

UP_LOG="$(git log --no-merges --format='- %s' "$PREV_UP..$UP" -- "${PHONE_PATHS[@]}" | head -15)"
OURS_FILES="$(git diff --name-only "$PREV_UP" HEAD | grep -v '^scripts/' || true)"
UP_FILES="$(git diff --name-only "$PREV_UP" "$UP")"
OVERLAP="$(comm -12 <(sort <<<"$OURS_FILES") <(sort <<<"$UP_FILES") || true)"

echo "== merge origin/main ${UP:0:11} (was ${PREV_UP:0:11})"
CONFLICT=""
git merge --no-edit -q "$UP" || CONFLICT=1

if [[ -n "$CONFLICT" || -n "$OVERLAP" ]]; then
  echo "== conflict=${CONFLICT:-0}; overlapping files:"; echo "$OVERLAP"
  DECISION="$LOG_DIR/$STAMP-decision.md"
  PROMPT="You are maintaining Skypart's fork branch $BRANCH of manaflow-ai/cmux in $REPO.
It is upstream main plus Skypart's own iOS fixes, shipped to his own TestFlight.
Upstream main ${UP:0:11} was just merged (merge state: $([[ -n "$CONFLICT" ]] && echo 'CONFLICTED, in progress' || echo 'clean, committed')).
Our own fixes are the non-merge commits in: git log --no-merges $PREV_UP..$OURS_BEFORE -- . ':!scripts'
Files both sides changed: ${OVERLAP:-none (textual conflict only)}

For each of our fixes that upstream touched:
- Read our commit and upstream's commits on the same files (git log $PREV_UP..$UP -- <file>).
- If upstream now fixes the same problem as well or better, take upstream's code and drop ours
  (also drop our tests for it). Skypart's Mac runs the stable cmux in /Applications/cmux.app
  (check its version); a fix that needs a newer Mac than that does not count yet.
- Otherwise keep ours, adapted to upstream's code.
Then run: (cd Packages/iOS/CmuxMobileShellModel && swift test) and
(cd Packages/iOS/CmuxMobileShell && swift test --filter 'TerminalFillScreenClaimTests|ComposerSendReconnectWaitTests').
Both must pass. Commit the result (no Co-Authored-By trailer). Never push, never touch other branches.
Write a short Thai summary of each decision and why to $DECISION.
If you cannot decide with confidence, run 'git merge --abort' (or 'git reset --hard $OURS_BEFORE' if already committed), write why to $DECISION, and exit."
  claude -p "$PROMPT" --dangerously-skip-permissions || true
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "Claude left the merge unfinished"
  [[ "$(git rev-parse HEAD)" != "$OURS_BEFORE" ]] || fail "merge abandoned; see $DECISION"
  git merge-base --is-ancestor "$UP" HEAD || fail "upstream ${UP:0:11} is not in HEAD after resolution"
fi

echo "== focused tests"
(cd Packages/iOS/CmuxMobileShellModel && swift test) >"$LOG_DIR/$STAMP-model.txt" 2>&1 \
  || { git reset -q --hard "$OURS_BEFORE"; fail "model tests failed"; }
(cd Packages/iOS/CmuxMobileShell && swift test --filter 'TerminalFillScreenClaimTests|ComposerSendReconnectWaitTests') \
  >"$LOG_DIR/$STAMP-shell.txt" 2>&1 \
  || { git reset -q --hard "$OURS_BEFORE"; fail "shell tests failed"; }

if [[ -n "${DRY_RUN:-}" ]]; then
  echo "DRY_RUN: merged and tested at $(git rev-parse --short HEAD); not pushing or shipping"
  exit 0
fi
git push -q fork "$BRANCH"

LAST="$(python3 scripts/skypart-asc-notes.py --list | awk '{print $1}' | sort -n | tail -1)"
BUILD=$((LAST + 1))
OURS_LOG="$(git log --no-merges --format='- %s' "$UP..HEAD" -- . ':!scripts' | grep -E '^- (fix|feat)' | head -8)"
NOTES="Nightly: ของต้นทาง (main ${UP:0:11}) + ที่เราแก้
${UP_LOG:+
ใหม่จากต้นทาง:
$UP_LOG
}
ที่เราแก้:
${OURS_LOG:-- (ไม่มี)}
$([[ -f "${DECISION:-/nonexistent}" ]] && printf '\nเลือกระหว่างของเรากับต้นทาง:\n%s\n' "$(head -c 800 "$DECISION")")
ลองดู: ใช้งานตามปกติ ถ้าอะไรพังกว่า build ก่อน บอก Koki พร้อมภาพหน้าจอ"
NOTES="${NOTES:0:3900}"

echo "== ship build $BUILD"
bash scripts/ship-skypart-testflight.sh "$BUILD" "$NOTES" || fail "ship of build $BUILD failed"
notify "build $BUILD ขึ้น TestFlight แล้ว (main ${UP:0:11})"
