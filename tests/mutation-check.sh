#!/usr/bin/env bash
# tests/mutation-check.sh — prove the sandbox suite actually fails when a guard is removed.
#
# A green suite is only worth something if it can go red. Each round copies the repo,
# deletes one guard from artcraftctl, runs the *whole* suite, and requires that a
# specific named case fails. Prints one line per mutation and exits 1 if any mutation
# went unnoticed.
#
#   bash tests/mutation-check.sh
#
# Dev-only: it deliberately breaks a copy of the script, so it is not a CI gate.

# The mutation anchors passed to mutate() are literal source fragments of artcraftctl, not
# expansions, so single quotes are correct and SC2016 does not apply here.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
COPY="$WORK/copy"
mkdir -p "$COPY/tests"
cp "$ROOT/artcraftctl" "$COPY/artcraftctl"
cp "$ROOT/tests/run.sh" "$COPY/tests/run.sh"
chmod +x "$COPY/artcraftctl" "$COPY/tests/run.sh"
PRISTINE="$WORK/pristine"
cp "$ROOT/artcraftctl" "$PRISTINE"

CAUGHT=0
MISSED=0

# mutate LABEL EXPECTED-CASE OLD NEW
mutate() {
  local label="$1" expect="$2" old="$3" new="$4"
  cp "$PRISTINE" "$COPY/artcraftctl"

  # awk with index() rather than a regex: the anchors are full of $, [, ] and *.
  if ! awk -v old="$old" -v new="$new" '
        !done && (i = index($0, old)) {
          $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); done = 1
        }
        { print }
        END { exit(done ? 0 : 3) }
      ' "$PRISTINE" > "$COPY/artcraftctl"; then
    printf 'BROKEN  %s — anchor not found in artcraftctl (did the code move?)\n' "$label"
    MISSED=$((MISSED + 1))
    return 1
  fi
  chmod +x "$COPY/artcraftctl"

  local out
  out="$( cd "$COPY" && bash tests/run.sh 2>&1 )"
  if printf '%s\n' "$out" | grep -qF "FAIL $expect"; then
    printf 'caught  %s -> %s\n' "$label" "$expect"
    CAUGHT=$((CAUGHT + 1))
  else
    printf 'MISSED  %s -> %s did not fail\n' "$label" "$expect"
    printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/          /'
    MISSED=$((MISSED + 1))
  fi
}

mutate "checksum verification removed" install_refuses_bad_checksum \
  'sha256sum -c - >/dev/null )' 'true )'

mutate "orphan pruning removed" upgrade_replaces_and_prunes_orphans \
  'if [[ -e "$rel" ]]; then rm -f "$rel" && orphans+=("$rel"); fi' ': # mutation'

mutate "remove-placed rollback loop removed" upgrade_rolls_back_after_the_first_half_landed \
  'for (( i = ${#placed[@]} - 1; i >= 0; i-- )); do rm -f "${placed[i]}"; done' ': # mutation'

mutate "restore-from-backup loop removed" upgrade_rolls_back_after_the_first_half_landed \
  'mkdir -p "$(dirname "$dst")" && mv -f "$backup/$rel" "$dst" || true' ': # mutation'

printf '\n%s caught, %s missed\n' "$CAUGHT" "$MISSED"
[[ $MISSED -eq 0 ]] || exit 1
