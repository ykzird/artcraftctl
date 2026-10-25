#!/usr/bin/env bash
# tests/run.sh — offline sandbox suite for artcraftctl.
#
# Drives the real ./artcraftctl entrypoint against a stubbed `gh` and a throwaway
# prefix. No network, no GitHub token, no writes outside the sandbox. Every case
# gets a fresh prefix, so a failure cannot leak state into the next one.
#
#   bash tests/run.sh            # whole suite
#   bash tests/run.sh rollback   # only cases whose name matches the pattern
#
# Exit 0 when every case passed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL="$ROOT/artcraftctl"
ORIG_PATH="$PATH"
ARCH="linux-$(uname -m)"
FILTER="${1:-}"

if [[ -t 1 ]]; then C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_OFF=$'\033[0m'
else C_RED=; C_GRN=; C_OFF=; fi

PASS=0
FAIL=0
FAILED=()
CASE=""
SB=""
FIX=""
RC=0
STATE=""
BASE=0

ok()   { PASS=$((PASS + 1)); printf '%sok%s   %s\n' "$C_GRN" "$C_OFF" "$CASE"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$CASE: $*")
         printf '%sFAIL%s %s — %s\n' "$C_RED" "$C_OFF" "$CASE" "$*"; }
end()  { [[ $FAIL -eq $BASE ]] && ok; return 0; }

assert_rc()      { [[ "$RC" == "$1" ]] || bad "expected exit $1, got $RC"; }
assert_file()    { [[ -f "$1" ]] || bad "expected file: $1"; }
assert_dir()     { [[ -d "$1" ]] || bad "expected dir: $1"; }
assert_no_file() { [[ ! -e "$1" ]] || bad "expected absent: $1"; }
assert_exec()    { [[ -x "$1" ]] || bad "expected executable: $1"; }
assert_grep()    { grep -qF -- "$1" "$SB/out.log" || bad "output missing: $1"; }
assert_contains(){ grep -qF -- "$2" "$1" || bad "$1 missing: $2"; }
assert_eq()      { [[ "$1" == "$2" ]] || bad "expected '$2', got '$1'"; }
assert_lines()   { local n; n="$(grep -c . "$1" 2>/dev/null || true)"
                   [[ "$n" == "$2" ]] || bad "expected $2 lines in $(basename "$1"), got $n"; }

# ------------------------------------------------------------------ fixture --

# The stub serves a release directory. Everything it can answer lives in $FIX.
write_stub() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
# gh stub for tests/run.sh — answers from $FIXTURE_DIR, never touches the network.
set -uo pipefail
FIX="${FIXTURE_DIR:?FIXTURE_DIR not set}"
cmd="${1:-}"; shift || true
case "$cmd" in
  api)
    ref="${1:-}"
    case "$ref" in
      */releases/latest) cat "$FIX/current_tag" ;;
      repos/*)           printf '%s\n' "${ref#repos/}" ;;
      *)                 printf 'gh-stub: unsupported api path %s\n' "$ref" >&2; exit 1 ;;
    esac
    ;;
  release)
    sub="${1:-}"; shift || true
    case "$sub" in
      view)
        tag="${1:-}"
        [[ -d "$FIX/$tag" ]] || { printf 'gh-stub: no release %s\n' "$tag" >&2; exit 1; }
        ( cd "$FIX/$tag" && ls -1 )
        ;;
      download)
        tag="${1:-}"; shift || true
        pat=""; dir=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -p) pat="${2:-}"; shift 2 ;;
            -D) dir="${2:-}"; shift 2 ;;
            -R) shift 2 ;;
            *)  shift ;;
          esac
        done
        src="$FIX/$tag/$pat"
        [[ -f "$src" ]] || { printf 'gh-stub: no asset %s in %s\n' "$pat" "$tag" >&2; exit 1; }
        cp "$src" "$dir/"
        ;;
      *) printf 'gh-stub: unsupported release subcommand %s\n' "$sub" >&2; exit 1 ;;
    esac
    ;;
  auth) exit 0 ;;
  *)    printf 'gh-stub: unsupported command %s\n' "$cmd" >&2; exit 1 ;;
esac
STUB
  chmod +x "$1"
}

# mk_release TAG VERSION [helper|nohelper] [good|missing|bad] [extra-bin-file]
mk_release() {
  local tag="$1" ver="$2" helper="${3:-helper}" sha="${4:-good}" extra="${5:-}"
  local d="$FIX/$tag" top="fakeapp-$ver"
  mkdir -p "$d" "$SB/work/$top/bin" "$SB/work/$top/share/applications"
  printf '#!/bin/sh\necho "fakeapp %s"\n' "$ver" > "$SB/work/$top/bin/fakeapp"
  chmod +x "$SB/work/$top/bin/fakeapp"
  if [[ "$helper" == helper ]]; then
    printf '#!/bin/sh\necho "helper %s"\n' "$ver" > "$SB/work/$top/bin/fakeapp-helper"
    chmod +x "$SB/work/$top/bin/fakeapp-helper"
  fi
  if [[ -n "$extra" ]]; then
    printf '#!/bin/sh\necho "%s %s"\n' "$extra" "$ver" > "$SB/work/$top/bin/$extra"
    chmod +x "$SB/work/$top/bin/$extra"
  fi
  printf '[Desktop Entry]\nName=FakeApp %s\nType=Application\n' "$ver" \
    > "$SB/work/$top/share/applications/fakeapp.desktop"
  tar czf "$d/fakeapp-$ver-$ARCH.tar.gz" -C "$SB/work" "$top"
  case "$sha" in
    good)    ( cd "$d" && sha256sum "fakeapp-$ver-$ARCH.tar.gz" > SHA256SUMS.txt ) ;;
    missing) : ;;
    bad)     printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" \
               "fakeapp-$ver-$ARCH.tar.gz" > "$d/SHA256SUMS.txt" ;;
  esac
  rm -rf "$SB/work/$top"
  printf '%s\n' "$tag" > "$FIX/current_tag"
}

new_sandbox() {
  SB="$(mktemp -d)"
  FIX="$SB/fixture"
  export ARTCRAFT_CONFIG_DIR="$SB/config"
  export ARTCRAFT_DATA_DIR="$SB/data"
  export ARTCRAFT_BIN_DIR="$SB/bin"
  export ARTCRAFT_SHARE_DIR="$SB/share"
  export FIXTURE_DIR="$FIX"
  mkdir -p "$ARTCRAFT_CONFIG_DIR" "$ARTCRAFT_DATA_DIR" "$SB/stub" "$SB/work" "$FIX"
  printf 'storytold/fakeapp\n' > "$ARTCRAFT_CONFIG_DIR/config"
  write_stub "$SB/stub/gh"
  export PATH="$SB/stub:$ORIG_PATH"
  STATE="$ARTCRAFT_DATA_DIR/state"
}

drop_sandbox() {
  [[ -n "$SB" ]] || return 0
  chmod -R u+w "$SB" 2>/dev/null || true
  rm -rf "$SB"
  SB=""
}


# setsid keeps the run off the controlling terminal, so the script's prompts
# return immediately instead of waiting on /dev/tty.
run_ctl() {  # CMD [ARGS...] -> $RC, combined output in $SB/out.log
  setsid timeout 60 "$CTL" "$@" > "$SB/out.log" 2>&1 < /dev/null
  RC=$?
}

start() {  # NAME -> skip when a filter is set and does not match
  CASE="$1"
  SELECTED=0
  if [[ -n "$FILTER" && "$CASE" != *"$FILTER"* ]]; then return 1; fi
  SELECTED=1
  drop_sandbox
  new_sandbox
  BASE=$FAIL
  return 0
}

# -------------------------------------------------------------------- cases --

case_install() {
  start install_happy || return 0
  mk_release v1.0.0 1.0.0
  run_ctl install --app fakeapp
  assert_rc 0
  assert_grep "checksum verified"
  assert_grep "installed 1.0.0"
  assert_exec "$ARTCRAFT_BIN_DIR/fakeapp"
  assert_file "$ARTCRAFT_BIN_DIR/fakeapp-helper"
  assert_file "$ARTCRAFT_SHARE_DIR/applications/fakeapp.desktop"
  assert_file "$STATE/fakeapp"
  assert_file "$STATE/fakeapp.files"
  assert_eq "$(cat "$STATE/fakeapp")" "1.0.0"
  assert_lines "$STATE/fakeapp.files" 3
  assert_eq "$(find "$ARTCRAFT_DATA_DIR" -maxdepth 1 \( -name '.stage.*' -o -name '.backup.*' \) | wc -l)" "0"
  end
}

case_reinstall() {
  start install_refuses_reinstall || return 0
  mk_release v1.0.0 1.0.0
  run_ctl install --app fakeapp
  run_ctl install --app fakeapp
  assert_rc 1
  assert_grep "already installed"
  end
}

case_no_sha() {
  start install_refuses_without_checksum || return 0
  mk_release v1.0.0 1.0.0 helper missing
  run_ctl install --app fakeapp
  assert_rc 1
  assert_grep "ships no SHA256SUMS.txt"
  assert_no_file "$ARTCRAFT_BIN_DIR/fakeapp"
  assert_no_file "$STATE/fakeapp"
  end
}

case_bad_sha() {
  start install_refuses_bad_checksum || return 0
  mk_release v1.0.0 1.0.0 helper bad
  run_ctl install --app fakeapp
  assert_rc 1
  assert_grep "checksum verification FAILED"
  assert_no_file "$ARTCRAFT_BIN_DIR/fakeapp"
  end
}

case_arch() {
  start install_refuses_wrong_arch || return 0
  mk_release v1.0.0 1.0.0
  export ARTCRAFT_ARCH="linux-arm64"
  run_ctl install --app fakeapp
  unset ARTCRAFT_ARCH
  assert_rc 1
  assert_grep "no 1.0.0 linux-arm64 tarball"
  assert_no_file "$ARTCRAFT_BIN_DIR/fakeapp"
  end
}

case_update() {
  start update_reports_available || return 0
  mk_release v1.0.0 1.0.0
  run_ctl install --app fakeapp
  mk_release v2.0.0 2.0.0 nohelper
  run_ctl update --all
  assert_rc 0
  assert_grep "update available (1.0.0 -> 2.0.0)"
  assert_eq "$(cat "$STATE/fakeapp")" "1.0.0"
  end
}

case_update_absent() {
  start update_reports_not_installed || return 0
  mk_release v2.0.0 2.0.0
  run_ctl update --all
  assert_rc 0
  assert_grep "not installed (latest: 2.0.0)"
  end
}

case_upgrade() {
  start upgrade_replaces_and_prunes_orphans || return 0
  mk_release v1.0.0 1.0.0 helper
  run_ctl install --app fakeapp
  mk_release v2.0.0 2.0.0 nohelper
  run_ctl upgrade --all
  assert_rc 0
  assert_grep "upgraded to 2.0.0"
  assert_eq "$("$ARTCRAFT_BIN_DIR/fakeapp")" "fakeapp 2.0.0"
  assert_no_file "$ARTCRAFT_BIN_DIR/fakeapp-helper"
  assert_eq "$(cat "$STATE/fakeapp")" "2.0.0"
  assert_lines "$STATE/fakeapp.files" 2
  assert_contains "$ARTCRAFT_SHARE_DIR/applications/fakeapp.desktop" "Name=FakeApp 2.0.0"
  end
}

case_upgrade_same() {
  start upgrade_noop_when_current || return 0
  mk_release v1.0.0 1.0.0
  run_ctl install --app fakeapp
  run_ctl upgrade --all
  assert_rc 0
  assert_grep "already up to date"
  end
}

case_rollback() {
  start upgrade_rolls_back_when_destination_is_read_only || return 0
  mk_release v1.0.0 1.0.0 helper
  run_ctl install --app fakeapp
  mk_release v2.0.0 2.0.0 nohelper
  chmod a-w "$ARTCRAFT_BIN_DIR"
  run_ctl upgrade --all
  chmod u+w "$ARTCRAFT_BIN_DIR"
  assert_rc 1
  assert_grep "rolling back"
  assert_grep "is still at 1.0.0"
  assert_eq "$("$ARTCRAFT_BIN_DIR/fakeapp")" "fakeapp 1.0.0"
  assert_file "$ARTCRAFT_BIN_DIR/fakeapp-helper"
  assert_eq "$(cat "$STATE/fakeapp")" "1.0.0"
  end
}

case_rollback_mid() {
  start upgrade_rolls_back_after_the_first_half_landed || return 0
  # 1.0.0 ships only the binary; 2.0.0 adds a second binary, so the upgrade has
  # real work to undo in the bin/ half before the share/ half fails.
  mk_release v1.0.0 1.0.0 nohelper
  run_ctl install --app fakeapp
  mk_release v2.0.0 2.0.0 nohelper good fakeapp-new
  # Make the share/ half impossible: the target dir is gone and its parent is
  # read-only, so the bin/ files land first and the desktop file cannot.
  rm -rf "$ARTCRAFT_SHARE_DIR/applications"
  chmod a-w "$ARTCRAFT_SHARE_DIR"
  run_ctl upgrade --all
  chmod u+w "$ARTCRAFT_SHARE_DIR"
  assert_rc 1
  assert_grep "rolling back"
  assert_grep "is still at 1.0.0"
  # the replaced file comes back from the backup …
  assert_eq "$("$ARTCRAFT_BIN_DIR/fakeapp")" "fakeapp 1.0.0"
  # … and the file that had no predecessor is removed again
  assert_no_file "$ARTCRAFT_BIN_DIR/fakeapp-new"
  assert_eq "$(cat "$STATE/fakeapp")" "1.0.0"
  assert_lines "$STATE/fakeapp.files" 2
  end
}

case_uninstall() {
  start uninstall_removes_manifest_paths || return 0
  mk_release v1.0.0 1.0.0 helper
  run_ctl install --app fakeapp
  run_ctl uninstall --app fakeapp
  assert_rc 0
  assert_grep "uninstalled (3 file(s) removed)"
  assert_no_file "$ARTCRAFT_BIN_DIR/fakeapp"
  assert_no_file "$ARTCRAFT_BIN_DIR/fakeapp-helper"
  assert_no_file "$ARTCRAFT_SHARE_DIR/applications/fakeapp.desktop"
  assert_no_file "$STATE/fakeapp"
  assert_no_file "$STATE/fakeapp.files"
  # empty ancestors below the prefixes are pruned; the prefixes stay
  assert_no_file "$ARTCRAFT_SHARE_DIR/applications"
  assert_dir "$ARTCRAFT_BIN_DIR"
  end
}

case_manifest_guard() {
  start uninstall_ignores_manifest_paths_outside_prefixes || return 0
  mk_release v1.0.0 1.0.0
  run_ctl install --app fakeapp
  local victim="$SB/victim.txt"
  printf 'do not delete\n' > "$victim"
  printf '%s\n' "$victim" >> "$STATE/fakeapp.files"
  run_ctl uninstall --app fakeapp
  assert_rc 0
  assert_grep "ignoring manifest entry outside the install prefixes"
  assert_file "$victim"
  end
}

case_no_tty() {
  start init_does_not_block_without_a_tty || return 0
  rm -f "$ARTCRAFT_CONFIG_DIR/config"
  run_ctl init
  assert_rc 0
  assert_grep "nothing added"
  end
}

case_usage() {
  start help_goes_to_stdout || return 0
  setsid timeout 20 "$CTL" help > "$SB/usage.out" 2> "$SB/usage.err" < /dev/null
  RC=$?
  assert_rc 0
  grep -q "artcraftctl update" "$SB/usage.out" || bad "usage not on stdout"
  [[ -s "$SB/usage.err" ]] && bad "usage wrote to stderr"
  end
}

# -------------------------------------------------------------------- runner --

CASES=(install reinstall no_sha bad_sha arch update update_absent upgrade
       upgrade_same rollback rollback_mid uninstall manifest_guard no_tty usage)

SELECTED=0
MATCHED=0
for c in "${CASES[@]}"; do
  "case_$c"
  [[ $SELECTED -eq 1 ]] && MATCHED=$((MATCHED + 1))
done
drop_sandbox

# A filter that matches nothing must not read like a green run.
if [[ -n "$FILTER" && $MATCHED -eq 0 ]]; then
  printf "no case name contains '%s'. Names are descriptive, e.g.\n" "$FILTER" >&2
  printf '  install_refuses_bad_checksum, upgrade_rolls_back_after_the_first_half_landed\n' >&2
  printf 'Run without an argument to execute all %s cases.\n' "${#CASES[@]}" >&2
  exit 2
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '%s\n' "${FAILED[@]}"
  exit 1
fi
