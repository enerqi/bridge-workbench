# Bridge Workbench

A desktop workbench for contract bridge practice and bidding-system notes. Windows today; Linux is planned,
and macOS may follow (untested).

- **Generate practice deals** for an auction, from the built-in scenarios or your own scenario files, as an
  interactive card page, a BBO hand-viewer page or text.
- **Analyse a deal you already have**: paste it, drop a `.pbn`/`.lin` file, or drop or paste a screenshot of
  a hand diagram (BBO, IntoBridge, BridgeWebs, RealBridge, club prints). The picture is read into a deal you
  can correct, then analysed: double-dummy par, make chances for declarer and dummy against unseen hands,
  card-combination lines, and what each card of a recorded play cost.
- **Edit bidding-system notes** written in BML (Bridge Markup Language) with a live preview, and make quiz
  pages from them.
- **Share deals** as a link or a QR code. A link opens in any browser, with nothing installed.

**Alpha.** Anything may change; the built-in scenarios are about to be reorganised.

## Install

From the [releases page](https://github.com/enerqi/bridge-workbench/releases):

- **Installer**: `bridge-workbench-<version>-setup.exe`. Installs for you alone, so no administrator rights
  are needed, and adds a Start-menu entry and an uninstaller. To install for every account on the machine
  (into Program Files, as administrator) run it as `bridge-workbench-<version>-setup.exe /ALLUSERS`.
- **Portable**: `bridge-workbench-<version>-windows-x64.zip`. Unzip anywhere and run `workbench.exe`.
- **Scoop**: `scoop install https://github.com/enerqi/bridge-workbench/releases/download/<tag>/bridge-workbench.json`

The program is not yet signed, so Windows SmartScreen may warn on first run: choose **More info**, then
**Run anyway**. `SHA256SUMS` on each release lets you check a download is what the release build produced.
The About panel's **Is a new version out?** button checks this repository's releases, and only when you
press it.

Releases are Windows 10/11, x64, for now. The code is written to be portable (its UI engine, Sciter, runs on
Windows, Linux and macOS), and Linux builds are planned. A macOS build may come later, but there is no Mac to test it on.

## Building from source

The workbench is written in [Odin](https://odin-lang.org) and built with [just](https://just.systems). It
needs these repositories checked out beside it (each found through an environment variable, default
`~/dev/<name>`):

| repository | variable | what for |
|---|---|---|
| [norn](https://github.com/enerqi/norn) | `NORN_HOME` | deal generation, card pages, card-combination analysis |
| [odin-dds](https://github.com/enerqi/odin-dds) | `DDS_HOME` | the DDS double-dummy solver |
| [odin-sciter](https://github.com/enerqi/odin-sciter) | `SCITER_HOME` | the user interface engine |
| [bridge-markup](https://github.com/enerqi/bridge-markup) | `MARKUP_HOME` | BML notes |
| [bridge-hand-ocr](https://github.com/enerqi/bridge-hand-ocr) | `HAND_OCR_DIR` | reading hand screenshots |

```shell
just workbench          # build and run
just lint               # type check and vet everything
just test-workbench     # the app's tests (a windowless engine view, no display needed)
just dist 0.1.0-dev     # what a release ships -> target/dist
just --list             # everything else: the command-line generator (`gen-all-cards`, ...), the advisor, tests
```

Releases are built by `.github/workflows/release-workbench.yml` from a `v*` tag, with the sibling
repositories at the commits pinned in `packaging/deps.json`.

## Licence

MIT - see `LICENSE`. The release's `THIRD_PARTY_NOTICES.txt` carries the licences of the code linked in
(Sciter, DDS, libcurl, Odin's libraries).
