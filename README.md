# artcraftctl

`artcraftctl` installs and updates the ArtCraft suite: the apps in the
[storytold](https://github.com/storytold) GitHub organisation (photocraft, vectorcraft,
lightcraft, filmcraft, effectcraft, designcraft, pdfcraft, gridcraft, deckcraft, soundcraft,
wordcraft, cadcraft and the rest). GitHub releases are the source of truth. The tool asks the
API for the latest stable release, picks the tarball for this machine's architecture out of that
release, verifies it against the release's `SHA256SUMS.txt` — and refuses to install anything it
cannot verify — then unpacks it into your home directory. No build step, no scraping, no package
manager, no daemon: one command installs one app, another tells you whether it is still current.

This is a third-party installer, not an official ArtCraft product: the apps belong to the
`storytold` organisation and carry their own licence (Apache-2.0). This tool ships only the
download-and-place logic, under the same licence.

## Quick start

```sh
install -m 755 artcraftctl ~/.local/bin/   # put the script on your PATH
artcraftctl init                           # choose repos to track; writes the config
artcraftctl install --app photocraft       # install one app
```

`init` asks for one `owner/repo` at a time and checks each one against the GitHub API, so a typo
or a repo you cannot read is rejected before it reaches the config file.

## Commands

| Command | What it does |
| --- | --- |
| `artcraftctl update --app APP \| --all` | Compare installed versions with the latest stable release. Report only. |
| `artcraftctl upgrade --app APP \| --all` | Move an installed app to the latest release. |
| `artcraftctl install --app APP \| --all` | Install an app. Refuses if it is already installed. |
| `artcraftctl uninstall --app APP \| --all` | Remove an app and the files it put down. |
| `artcraftctl init` | Interactive one-time setup; writes the config file. |
| `artcraftctl help` | Usage text. |

`APP` is either a bare app name (`photocraft`, resolved through the config) or a full
`owner/repo`, which bypasses the config lookup. The four app commands need `--app APP` or
`--all`; there is no default target.

## How it tracks versions

The config file lists the repositories to track, one `owner/repo` per line. Anything from `#`
to the end of a line is a comment and blank lines are ignored, so the file stays hand-editable
after `init` has written it.

For each repo the app name is the part after the last slash. Two files per app live in the state
directory: `<app>` holds the installed version (the release tag with the leading `v` removed),
and `<app>.files` holds the absolute path of every file the install wrote. `uninstall` reads the
manifest, removes exactly those paths and then drops directories it left empty.

An app counts as installed if its state file exists or its binary is executable in
`~/.local/bin`. The state file wins when a version is needed; otherwise the version is read from
`<app> --version`.

## Files and paths

| Path | Purpose |
| --- | --- |
| `~/.config/artcraftctl/config` | Tracked repositories, one `owner/repo` per line. |
| `~/.local/share/artcraftctl/state/<app>` | Installed version. |
| `~/.local/share/artcraftctl/state/<app>.files` | Manifest of installed absolute paths. |
| `~/.local/bin` | Destination for the tarball's `bin/`. |
| `~/.local/share` | Destination for `share/` (desktop files, icons). |

These paths honour `XDG_CONFIG_HOME` and `XDG_DATA_HOME`, and can be pointed elsewhere for
testing with `ARTCRAFT_CONFIG_DIR`, `ARTCRAFT_DATA_DIR`, `ARTCRAFT_BIN_DIR` and
`ARTCRAFT_SHARE_DIR`; `ARTCRAFT_ARCH` overrides the release suffix taken from `uname -m`. After an install or uninstall, `update-desktop-database` and
`gtk-update-icon-cache` run when present, so launchers pick up changes without a re-login.

## Requirements

- Linux on x86_64, aarch64 or riscv64 — the release has to publish a tarball for the architecture
  `uname -m` reports (override with `ARTCRAFT_ARCH`)
- bash 4 or newer (`mapfile`)
- `gum` for the terminal UI. It is checked before the command is parsed, so `help` needs it too,
  and without it you get a bare `gum: command not found` rather than the tool's own error
- `gh`, authenticated, with a token that can read the tracked repos
- `tar`, `sha256sum`, plus coreutils, `awk`, `sort` and `find`
- optional: `update-desktop-database`, `gtk-update-icon-cache`

## Known limitations

- `uninstall` removes what the manifest lists, not caches that other tools generate, such as
  `~/.local/share/applications/mimeinfo.cache`.
- An app deleted by hand still counts as installed: its state and manifest files remain until
  you remove them.
- Without a manifest, `uninstall` falls back to deleting `~/.local/bin/<app>` and
  `~/.local/bin/<app>-*` and leaves the rest of the files behind.
- The asset picker prefers `<repo>-<version>-<arch>.tar.gz` and otherwise takes the release's
  other tarball for that version and architecture, skipping `-cli-` builds. If a release carries
  several of those, it stops and lists them instead of guessing.
- A release without `SHA256SUMS.txt`, or without an entry for the chosen asset, is refused. There
  is no flag to install without a checksum.
- `upgrade` stages and verifies the new version before it touches the old one, so a failed
  download or a bad checksum leaves your install intact. The copy itself is not atomic: an
  interrupted copy after that point can leave a half-installed app.
- `sync` is gone. It was split into `update` (check) and `upgrade` (apply), and the tool exits
  with a hint if you still type it.

## Uninstall and cleanup

Remove one app, or everything the config knows about:

```sh
artcraftctl uninstall --app photocraft
artcraftctl uninstall --all
```

To drop the tool itself, delete the script and the directories it owns:

```sh
rm -f ~/.local/bin/artcraftctl
rm -rf ~/.config/artcraftctl ~/.local/share/artcraftctl
```

Installed apps stay where they are, so run `artcraftctl uninstall` first if you want them gone
too. For internals (the release contract, the gum terminal handling, the order of the uninstall
and upgrade steps) read the header comment and the section banners in the script.

## License

Apache-2.0, see [LICENSE](LICENSE). The Craft apps are licensed by the `storytold` project
owners, not by this repository.
