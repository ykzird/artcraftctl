# AGENTS.md

## What this repo is

One shipped file: `artcraftctl`, a single bash script of about 570 lines. No build step, no
dependencies beyond the ones listed in `README.md`, no artifacts. `tests/run.sh` is an offline
sandbox suite for it — see *How to test*. Its header comment is the reference for internals.

## Invariants you must not break

- **Release contract.** Latest stable release from `gh api repos/<owner>/<repo>/releases/latest`;
  the tarball is *picked from the release's asset list* (`<repo>-<version>-<arch>.tar.gz` first,
  else the release's other tarball for that version and arch, skipping `-cli-`), never composed
  from the repo name; `SHA256SUMS.txt` is mandatory; the tarball wraps one top directory with
  `bin/` and `share/`, extracted `--strip-components=1`.
- **Architecture.** `ARCH` comes from `uname -m` (`ARTCRAFT_ARCH` overrides it). Never hardcode an
  arch suffix: a wrong-arch tarball downloads and installs successfully and then cannot run.
- **Install is a transaction.** `_stage_release` (pick, download, verify, extract) runs first, then
  `_install_staged` copies into `$DATA_DIR/.stage.*` (same filesystem, so each rename is atomic),
  moves files in one by one and keeps every replaced file in `$DATA_DIR/.backup.*`. Any failure
  rolls the backups back. Never reintroduce a plain `cp -a` over the destination, and never make
  `upgrade` delete the old version before the new one has landed.
- **Manifest and state are written aside and renamed.** A reader must never see a half-written
  manifest, and every path in it must sit under `$BIN_DIR` or `$SHARE_DIR`.
- **Paths.** Config `~/.config/artcraftctl/config`; state `<data>/artcraftctl/state/<app>`
  (version) and `<app>.files` (absolute-path manifest); `bin/` to `~/.local/bin`, `share/` to
  `~/.local/share`. All honour `XDG_*` and the four `ARTCRAFT_*` overrides.
- **Command model.** `update` reports only, `upgrade` replaces in place (stage, then transaction,
  then prune the orphans of the old version), `install` refuses when installed, `uninstall` removes
  manifest paths and the desktop caches it generated, `init` writes config; `sync` fails with a hint.

## How to change it

- Keep `set -euo pipefail` and the `need` checks in `main`.
- Output goes through `head_ info_ ok_ warn_ err_ die need`. Diagnostics belong on stderr (a
  redirected `update` must still report), `usage` is the only thing on stdout. Colour comes from
  the `C_*` variables, which are empty when output is not a terminal or `NO_COLOR` is set — never
  hardcode an escape sequence at a call site. Do not add a TUI dependency: this script deliberately
  needs nothing beyond `gh`, `tar`, `sha256sum` and coreutils.
- Prompts go through `confirm` and `ask`, which read `/dev/tty` (not stdin: `ask` runs inside
  `$( )`) and return immediately when there is no terminal. A non-tty run must never block.
- New paths need an `ARTCRAFT_*` override and a default; every file written must end up in
  `<app>.files`, or `uninstall` leaves it behind.
- Anything generated rather than shipped (desktop caches) is not part of the manifest; remove it in
  `_clean_desktop_caches` once nothing else needs it.

## How to test

`bash tests/run.sh` is the suite and runs with no network, no `gh` login and no writes outside a
temporary prefix: it puts a stub `gh` on `PATH`, builds throwaway release tarballs, and drives the
real entrypoint in a fresh sandbox per case. 15 cases cover install/update/upgrade/uninstall, the
two failure modes below, checksum and arch refusal, the manifest prefix guard, and the no-tty path.
`bash tests/run.sh rollback` runs only the matching cases. Exit 0 means every case passed.

`bash tests/mutation-check.sh` proves the suite has teeth: it removes one guard at a time from a
copy of `artcraftctl` and requires a named case to fail. Dev-only, not a gate — run it whenever the
install, rollback or prune logic changes, because a case that passes for the wrong reason looks
exactly like a case that passes for the right one.

Against real releases (needs `gh auth status` to be logged in), the manual recipe is still the
honest end-to-end check:

```sh
SANDBOX=$(mktemp -d)
export ARTCRAFT_CONFIG_DIR=$SANDBOX/config ARTCRAFT_DATA_DIR=$SANDBOX/data \
       ARTCRAFT_BIN_DIR=$SANDBOX/bin ARTCRAFT_SHARE_DIR=$SANDBOX/share
mkdir -p "$ARTCRAFT_CONFIG_DIR" "$ARTCRAFT_DATA_DIR"
printf 'storytold/photocraft\n' > "$ARTCRAFT_CONFIG_DIR/config"
./artcraftctl install --app photocraft
./artcraftctl update --all && ./artcraftctl upgrade --all
./artcraftctl uninstall --app photocraft
rm -rf "$SANDBOX"
```

Run `gh auth status` first. Prompts need a real terminal, so drive `init` in `tmux` on the target
host; a non-tty run is report-only, since confirmations are skipped. Check the side effect
(installed files, state files, leftovers) rather than only the pane text.

Two cases worth forcing, because they are the ones a refactor breaks. Both are automated cases in
`tests/run.sh` (`upgrade_rolls_back_*`, `upgrade_replaces_and_prunes_orphans`); the manual forms
below are for checking a real release end to end:

- **Rollback**: install an app, then `chmod a-w` the destination directory and run `upgrade` with
  an older version written into `state/<app>`. Expect `could not place the files — rolling back`,
  exit 1, and the previous files plus version still in place.
- **Upgrade path**: a fresh install of the same release never exercises the replace branch, so write
  an older version into `state/<app>` first.

## Quality gates

- `bash tests/run.sh` must pass (15 cases, offline, no token needed). It is the gate for behaviour:
  the transactional install, the rollback, orphan pruning, checksum/arch refusal and the manifest
  prefix guard each have a case, and `.github/workflows/ci.yml` runs it on every push to `master`
  and every pull request.
- `shellcheck -S style artcraftctl tests/run.sh` is the gate and must be clean — no exceptions.
  Older copies of this script carried an SC2318 in `_remove_files` (a single `local app=…
  manifest=…` that relied on the caller's `app`); it is fixed by splitting the declaration, so do
  not reintroduce the pattern.
- `shfmt` is **not** a gate today: the file is hand-formatted (aligned one-line helpers, trailing
  comments) and `shfmt -d` rewrites most of it. If you reformat, do it in its own commit with no
  behaviour change.

## Do not

- Commit config, state or manifest files; they live in the user's home, not here.
- Change the licence. The repo is Apache-2.0 (`LICENSE`) to match the Craft apps; do not add a
  second one or a CHANGELOG nobody asked for.
- Add telemetry, analytics, or network access beyond `gh` and the release assets.
