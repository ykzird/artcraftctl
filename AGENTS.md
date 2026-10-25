# AGENTS.md

## What this repo is

One file: `artcraftctl`, a single bash script of about 430 lines. No build step, nothing
vendored, no tests directory, no artifacts. Its header comment is the reference for internals.

## Invariants you must not break

- **Release contract.** Latest stable release from `gh api repos/<owner>/<repo>/releases/latest`;
  asset `<repo>-<version>-linux-x86_64.tar.gz` plus `SHA256SUMS.txt` in that release; the
  tarball wraps one top directory with `bin/` and `share/`, extracted `--strip-components=1`.
- **Paths.** Config `~/.config/artcraftctl/config`; state `<data>/artcraftctl/state/<app>`
  (version) and `<app>.files` (absolute-path manifest); `bin/` to `~/.local/bin`, `share/` to
  `~/.local/share`. All honour `XDG_*` and the four `ARTCRAFT_*` overrides.
- **Command model.** `update` reports only, `upgrade` uninstalls then installs, `install` refuses
  when installed, `uninstall` removes manifest paths, `init` writes config; `sync` fails with a hint.

## How to change it

- Keep `set -euo pipefail` and the `need` checks in `main`.
- Output goes through `head_ info_ warn_ err_ ok_ die need`. `gum log` writes to stderr: never
  redirect its stderr, and do not swap the helpers for bare `echo`.
- Interactive calls (`gum confirm`, `gum input`, `gum choose`) only behind `interactive()`,
  which tests `[[ -t 0 && -t 1 ]]`; a non-tty run must never block.
- Leave `_tty_hold` / `_tty_release` alone: they hold echo off and drain the tty on exit,
  because gum probes the terminal for capabilities. Dropping them leaks replies to the prompt.
- New paths need an `ARTCRAFT_*` override and a default; add every written file to
  `<app>.files`, or `uninstall` leaves it behind.

## How to test

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

Run `gh auth status` first. gum needs a real terminal, so drive interactive paths in `tmux` on
the target host; a non-tty run is report-only, since confirmations are skipped. Check the side
effect (installed files, state files) rather than only the pane text.

## Quality gates

- `shellcheck -S style artcraftctl` is the gate: it must stay clean apart from SC2318 in
  `_remove_files`, where `local app="$1" manifest="$STATE_DIR/$app.files"` expands `$app` before
  the assignment lands and only resolves because the caller has `app` in scope. Split it into two
  `local` lines when you touch that function; do not rely on dynamic scope in new code.
- `shfmt` is **not** a gate today: the file is hand-formatted (aligned one-line helpers, trailing
  comments) and `shfmt -d` rewrites most of it. If you reformat, do it in its own commit with no
  behaviour change.

## Do not

- Commit config, state or manifest files; they live in the user's home, not here.
- Add a LICENSE or CHANGELOG the owner has not chosen.
- Add telemetry, analytics, or network access beyond `gh` and the release assets.
