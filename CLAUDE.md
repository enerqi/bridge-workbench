# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The **Bridge Workbench** and its command-line programs, in Odin on the `norn` library: `workbench/` (the
desktop app: deal generator, single-deal advisor, notes editor, scenario editor, hosted card pages), `sim`
(deal generation from the scenario registry), `analyse_deal` (the declarer+dummy advisor / exact double
dummy for one deal), `page_check`, the share-link `player`, and every local package they are built from.

It was `deal-simulations/odin-sims/` inside the bidding notes repository (`enerqi/bridge-bidding-systems`,
`~/docs/bridge/bridge-bidding-system`) until 2026-10-22, when it became its own repository with its history
(`git filter-repo --subdirectory-filter`; plan and reasons in `REPO_SPLIT_PLAN.md`). The notes are now an
OPTIONAL neighbour, read and never built against: the notes view opens them at startup through
`BML_DOCS_DIRECTORY`, and the corpus-wide tests (`test-quiz-corpus`'s parity goldens, the notes-editor tests in
`test-workbench`) read them through `BRIDGE_SYSTEM_HOME`. The justfile exports both when the checkout is at its
usual place (`~/docs/bridge/bridge-bidding-system`, or wherever `BRIDGE_SYSTEM_HOME` says) and leaves them empty
otherwise, so a machine without the notes - CI - runs those tests as skips. The notes' html build
(`bml2html`) moved to bridge-markup at the same time.

`AGENTS.md` is the short command guide; this file is the long-form record of how things work and why.

## External dependencies (must be installed/configured)

All siblings are found through an environment variable, defaulting to `~/dev/<name>`, and pinned for releases
in `packaging/deps.json` (`just pin-deps`).

- **Odin** + **norn** (`NORN_HOME`) — the engine library this project consumes (`norn:norn`, `norn:cli`,
  `norn:combo`).
- **odin-dds** (`DDS_HOME`) — DDS bindings, the `dds` collection, linked only through `deal_solve/`. Its static
  library must be built first (`just build-lib` there).
- **odin-sciter** (`SCITER_HOME`) — the workbench's UI engine bindings. Sciter is dynamic-link-only, so it is a
  *runtime* dependency too: the justfile exports `SCITER_LIB` at that checkout's engine library.
- **bridge-markup** (`MARKUP_HOME`) — the Odin BML implementation, the `markup` collection: the notes editor's
  live preview, `quiz_corpus`, the heading palette. It also owns `bml2html`, the notes' build tool.
- **bridge-hand-ocr** (`HAND_OCR_DIR`) — its `odin/` directory is the `hocr` collection, the in-process reader of
  dropped/pasted hand screenshots. Build-time only (atlases compiled in). The python at that checkout's root is
  the reference implementation; `just build-hand-ocr` builds the reader's CLI.
- **The notes** (`BRIDGE_SYSTEM_HOME`, optional) — see above.
- **bridge-system-apps** (`BRIDGE_APPS_HOME`, optional) — only to re-record the quiz-corpus goldens (the python
  quiz is the oracle) and to rebuild the vendored `ui/quiz-template.html`.
- **zig** — only to build the shared-deals player's DDS (`just player-dds`).
- **uv** — every python script here carries PEP 723 metadata and runs with `uv run --script` / `--no-project`.
- **just**, **node** (the player and QR-JS checks), **npx** (`publish-player`).

## Common commands

```shell
just lint                    # odin check every package and program (-vet -strict-style) - the gate
just test                    # the bidding package; `just --list` for test-deal-solve, test-share, test-player, ...
just test-workbench          # the workbench tests as 4 parallel processes (~6s); -serial = one process, for debugging
just page-check              # does the hosted card page still lay out in Sciter? (no display needed)

just gen-all-cards           # every scenario as a CARD page -> $DEALS_OUTPUT_DIR/<name>.html (default w:/deals/)
just gen-all                 # ... as BBO hand-viewer pages -> <name>.hv.html (the two formats never share a name)
just gen-some 1c,2c          # just those scenarios
just gen-one 2c              # one scenario -> ./2c.html (dir just was invoked from)
just scenarios               # list compiled scenario names

just workbench               # build + run the desktop app
just workbench-debug         # the same window with the debug affordances (see below)
WORKBENCH_GFX=raster just workbench   # force software Skia (a GPU layer is the engine's own default)
just inspector               # the SDK's DevTools-style inspector, against that running window
just dist 0.1.0-alpha.1      # THE RELEASE ARTIFACT -> target/dist (portable CPU, no console, version stamped)
```

The release is CI's: `.github/workflows/release-workbench.yml` on a `v*` tag (or a manual run), building `just
dist` from this repository plus the five siblings at the commits in `packaging/deps.json`. Plan:
`DEPLOYMENT_PLAN.md`.

## The quiz button and its vendored template

**The workbench's `quiz` button** (notes view) is the other tie, and it is a VENDORED FILE, not a
build dependency. The apps repo builds the quiz once as a self-contained HTML page with an empty corpus
slot (the tina port's Odin packages compiled to `js_wasm32`, the routes running in the page, Datastar's
fetch answered from the module) and `just dswasm vendor-template` there copies it to
`ui/quiz-template.html`, which the workbench `#load`s - so the button works
for any user with nothing to set up (`.gitignore` un-ignores `ui/*.html` for this). The button
reads the bid tables out of the EDITOR BUFFER with `quiz_corpus`, writes them as JSON into the template's
`/*QUIZ_CORPUS*/` slot and saves `<file>-quiz.html` (setting `quiz.dir`, empty = the deals folder). The
controls are a group in the SOURCE PANE'S HEAD, after the file's name and `save` - all act on the open file (2026-10-10;
it was a strip under the bar spanning both panes, and read as misplaced) - with a full button, `make quiz` (`remake
quiz` once a page exists; it was a small `generate` beside a dim `quiz` label, obscure for what it does), `↗ open` the open file HAS a page on disk
(checked on every open/save/generate/folder change, never creating the folder), and a line giving the
page's age and marking it out of date when the notes were saved after it. No compiler or python at that point. Setting `quiz.template` (or `QUIZ_TEMPLATE`) OVERRIDES the
bundled copy, for trying a new build; an unusable override falls back to the bundled one and says so. The
app's messages are for users: no build commands in them. The wasm build is NOT byte-reproducible (the
compiler orders data differently run to run), so each vendor is a ~660KB diff - vendor only when the quiz
app changed. It is not
shown in a pane: the page runs WebAssembly, which Sciter's script does not. Files with fewer than 8
distinct meanings are refused (a question has up to 8 candidates). TOPICS come from `#+TOPIC: Name =
pattern, pattern` lines in the `.bml` (and its `#INCLUDE`s) - both BML parsers drop a `#+KEY:` block whole,
so they render as nothing; keep them in a block of their own - plus 18 generic defaults
(`quiz_corpus/topics.odin`, from the python quiz's `default_topics.toml`); the quiz PAGE keeps only topics
whose filter selects enough auctions to quiz on (it holds the matcher). Unreadable topic lines are
reported in the status line. The page's "System Notes" panel shows the file ITSELF: rendered as the
preview renders it, `bml.css` inlined, carried in the corpus JSON as `system_notes_html` and given to the
panel as a blob by `host.js` (`system_notes_url` = `/__quiz/notes/0`). **Editing a `.bml` file also moves `quiz_corpus`'s parity digests**: re-record them

## How the code is organised

**Scenario names are auction ids, with a label and a former name** (2026-10-20). `cli.Scenario` (norn) has
`name` (the id: a file name on `w:/deals` and the `-S` argument, ASCII, lower case, shell-safe), `label` (the
auction as a player writes it, suit glyphs: `1♥/♠ – ? : slam try`; the workbench row shows it with the id dim
after it) and `formerly` (the id before the rename, the old `.tcl` basename; `cli.lookup` still answers it,
current names first, and the workbench filter matches it). The id notation is documented at the top of
`bidding/scenarios.odin`: `1hs`/`1cd` for either major/minor, `opp-` before the opponents' calls (no brackets:
`(` is syntax in nu and bash), `_` before the hand being practised (`1n_two-suiter`). Hook keys in `sim_hooks`
must be CURRENT ids (a former one fails `validate_gen_hooks`). Pages generated before the rename keep their old
file names, so regenerate the deals folder after it. The system axis of the tags is `any-system` (hand types,
partnership totals, the opponents' auctions) vs `swedish-club` (everything that commits to a meaning of ours,
including the 1NT/2NT/1M/weak-two auctions, whose ranges are WSC's); it is meant to become a `system` field -
plan in `TODO-scenario-create-select-filter.md` ("scenarios belong to a SYSTEM").

Local packages:

| package | what |
|---|---|
| `bidding/` | this system's scenario predicates + the named-scenario registry (`cli.main_program` consumes it) |
| `deal_solve/` | the **DDS boundary** — the only place the `dds` collection is linked. Par + makeable census (`annotate`), Monte-Carlo make-% sampling over unknown hands, the misguess-tax achievable estimate, exact grids. Whole-deal, entries respected. `play_cost.odin` solves every position of a RECORDED play (one batched DDS call) for the per-card cost the card page's play-through bar shows (`data-play`); the positions, the reading of DDS's answers and the element are `replay/`'s. The sampling's arithmetic (layouts, grids, lead grids, tax, the page JSON) is `sampled/`'s; this package keeps the DDS calls and names `sampled`'s types under the old names. `sim_json.odin` bakes those results into the card page's `data-sim` / `-sim-leads` / `-sim-guess` attributes (the format lives with the code that computes it, and is unit-tested without building an exe). (Was named `dd`; renamed because it is one character from the `dds` bindings and had outgrown "double dummy".) **Generation solves in BATCHES** (2026-10-16): `prepare_tables` is norn's `cli.Annotation_Prepare`, so a `--par` or DD-filtered export deals first (a filter in rounds of 40 survivors), solves every deal with `CalcAllTables` 40 at a time, then writes the pages on the pool - one deal at a time kept ~3 threads busy. The whole registry with `--par` went from ~7 minutes to 81s. DDS takes every logical core but two (`DDS_SPARE_THREADS`). |
| `suit_book/` | this project's **published suit-combination table** (baked from the BridgeHands tables by `suit_book/encyclopedia/`), plugged into `norn:combo`'s book hook via `combo.set_suit_book(suit_book.provider())`. Kept out of norn deliberately: the lines and percentages are facts, but the prose and arrangement are someone else's editorial work. |
| `analyse/` | the single-deal advisor as a LIBRARY: the deal reader (PBN tag / bare `N:...` / LIN record / bridge-site hand URL), the argument surface (`core:flags`), the DDS sampling step, the text report and the card-page assembly. All output goes through an `analyse.Sink` (a report writer + a diagnostics writer) rather than to stdout, which is what lets a GUI capture a run; `parse_args(argv, allow_stdin = false)` is for a caller with no terminal behind it. `--table text|csv` (`match.odin`, `just match-report <file>`) judges a whole match file instead: one line a board against double dummy (tricks, what the lead, declarer and the defence gave away, claims, score and par in IMPs) plus totals by kind of contract. The card page of a played match carries the same table (hidden `.match-table`, the page's `Table` button; a row opens its board at the first costly card), and a team match's two rooms are compared board by board (`rooms.odin`: each swing split into the bidding's share, both contracts played double dummy, and the play's). Extracted from `analyse_deal.odin`, which was a single-file `package main` nothing could import or test. |
| `quiz_corpus/` | a bidding QUIZ's questions read out of a `.bml` document: every bid-table row as an auction plus its description, completed with the bids its section headings imply. A port of the python quiz's extraction (`apps/quiz/quiz.py` in the apps repo) over bridge-markup, held to it auction for auction over EVERY `.bml` file here (19/19, 19,486 auctions) by digests in `testdata/goldens.json` - `just test-quiz-corpus`, re-recorded by `just quiz-corpus-goldens`. Uses `markup:bids`, the call model (a copy of the tina quiz port's `bids/`, itself a port of `bmlbids.py`). Feeds the workbench's `quiz` button. |
| `outline/` | the notes' HEADINGS as a searchable list - the model behind the editor's CTRL+R "go to heading" palette (Sublime's `goto symbol`): heading parsing, subsequence scoring with word-start/prefix/exact tiers, and ranking the whole corpus with the open file first. No engine in it, so the ranking's judgement calls are unit-tested (`just test-outline`). |
| `par_caption/` | the par caption a card page shows, written from the solver's numbers (trick table + par result) rather than by the solver - DDS-free, so the wasm player writes the same caption from a link. `deal_solve` converts DDS's results and calls it. |
| `replay/` | a RECORDED PLAY as the card page replays it, without the solver: the positions to solve (DDS's `deal` struct, `positions`), what each card cost from DDS's answers (`costs`), the `.play` element (`data-play`, plus `data-pack`: the play's bytes for a share link), and those bytes (`pack_play`: each card a 4-bit index into its player's hand). Where the record stops early (a claim), a solved play goes on to the last card DOUBLE DUMMY (`playout_card`, one solve a card; the page draws those cards as the play-out, `end` stopping at the claim first). Shared by `deal_solve.play_cost` (one batched native solve) and the wasm player (one `SolveBoard` a position, in a worker), which `test-player` holds to each other card for card. |
| `sampled/` | the 2-hand advisor's SAMPLING without the solver: the layouts (`generate_layouts`, seeded reject sampling around the known hands), the running grid and the adaptive stop (`tally`, `adaptive_stop`, checked every `ROUND` = 40 layouts, DDS's batch), the lead sub-grids, the misguess tax and the per-lead tax (filters over one solved batch), `advise` (all of it for a board) and `write_advisor_par` (the `.par` element with `data-sim`/`-leads`/`-guess`). `deal_solve` solves natively; the wasm player solves on a pool of DDS workers - `test-player` holds the player to the advisor given the same layouts (`rand` is another sequence on wasm32, so its OWN layouts give the same statistics, not the same digits). |
| `share/`, `player/` | a card page as a LINK (`SHARING_PLAN.md` Tier B): `share` is the payload and the page rebuilt from it (pure, `just test-share`); `player` is that, compiled to wasm with `combo`, as the one-file `player.html` a link opens (`just player`, `test-player`, `vendor-player`). The player shows the page AT ONCE without the analysis, and computes a board's `.combo` ONLY when the reader asks from the CCA panel (`ncRequestAnalysis` -> a pool of Web Workers, one a processor less two and at most eight, boards side by side -> the page's `ncAddAnalysis`; nothing runs on the reader's processor otherwise). The same request solves a whole deal's double-dummy table with DDS compiled to wasm (`player/dds/`, built by zig: `just player-dds`; ONE set of DDS workers, `ddsShared`, for the tables, the plays and the 2-hand sampling alike: a job queue, one a processor less two and at most eight, closed after 30s idle; a link with par carries the table already, so those boards need no solve, `pl_par_tricks`) and the player writes the contract picker's exact grid from it (`pl_exact`, by `par_caption.write_exact_sim` - the native advisor page's writer too; `test-player` holds the wasm grids to native DDS's). A board with a RECORDED PLAY (format `v2.`: a link with plays in it; `v3.`: a 2-hand board naming its contract and the defender inferences its sampling was conditioned on, the `.par`'s `data-contract` / `data-held` / `data-shape`, which the reader's sampling then reads instead of the grid's best, over layouts meeting those inferences; every other link stays `v1.`) gets the replay bar, and the bar offers what each card cost (`What did each card cost? (slow)` -> `ncRequestPlay` -> the same DDS worker solving every position -> `ncAddPlay`); once asked, boards with a play are worked out as they are shown. A 2-hand advisor board (a link with the CCA) offers the advisor's SAMPLING in the CCA panel's verdict band (`Sample the hidden hands (slow)` -> `ncRequestSample` -> up to 300 layouts on the same DDS workers -> `ncAddSample` replaces the board's `.par`); progress shows in the band, and once asked a 2-hand board shown with the panel open is sampled on arrival. The page's own Share button carries plays from each `.play`'s `data-pack`. Its `Save` button downloads that spliced html - the browser's own save writes the already-built carousel, which does not open again. The workbench's `share link` button. |
| `qr/` | a QR code ENCODER (Tier C): byte mode, versions 1-40, L/M/Q/H, masks by penalty, plus `qr.svg`. Pure Odin, held module for module to `qrcodegen` matrices that zxing-cpp scanned back (`qr/testdata/goldens.txt`, `just test-qr`; re-record with `just qr-goldens` only when adding cases - NOT segno, which pads non-canonically). The workbench's `QR` button (a panel beside `share link`; error correction L, par dropped above `QR_READABLE_VERSION` = 25, the phone-scan ceiling). The CARD PAGE's own `QR` button runs a JS PORT of it (norn's `norn/html_cards_qr.js`) held to the same goldens by `just test-qr-js` - change the two together. |
| `sim_hooks/` | this system's double-dummy generation hooks (per-scenario filters + annotators) as data, shared by both generator front ends: the compiled scenarios' (`1hs_game-force`, `ns-32plus-opc`), those a scenario FILE asks for with `double-dummy: <north-south|east-west> make <game|slam|grand>` (`deal_solve.makes_filter`), and the `--par` caption. A scenario's hooks are PART OF IT and always apply - the old `--dd` switch (the workbench's "double-dummy hooks" box) is gone, because without it `ns-32plus-opc` was just "32+ points" under that name. What is left per run is `--par` ("par for every deal (slower)"): every scenario without its own annotator gets the par caption. A file scenario named like a compiled one gets no hooks (the compiled one wins the name). Kept out of `bidding` because it references `deal_solve` and `bidding` is lint-checked without the `dds` collection. |
| `workbench/` | the desktop app, and the one program here that is a PACKAGE rather than a single file: `workbench.odin` plus `workbench_test.odin`. It was one 12,900-line file with half of that tests, and `odin ... -file` compiles exactly one file — so splitting the tests out is what made it a directory. `#load`s `../ui/workbench.{html,css}`. |
| `sim.odin`, `analyse_deal.odin`, `page_check.odin` | the three single-file programs, all thin drivers: `sim` generates deals from a scenario predicate; `analyse_deal` (was `pbn_analyse`) analyses ONE deal you already have, as either the declarer+dummy advisor (defenders `-`) or, for a complete four-hand deal, exact double dummy; `page_check` (`just page-check`) is the guard for that last part — it renders a page and asserts its layout inside a windowless Sciter view. None of them contains analysis — that is `analyse`, `deal_solve` and `norn:combo`. |

**Two places, one splitter idiom.** The window's tab strip has TWO entries — deals and notes — and both are
the same shape: a one-line `.bar` over a `.split` of panes. The hand page used to be a third tab and is now a
PANE of the deals view, opened beside the controls that made it. `◧ scenarios` folds the scenario list, and
WHERE THE PAGE IS is one three-position control (`closed` / `split` / `wide`) rather than two toggles: a pane
cannot be wide and shut, and two buttons said it could, so every transition needed a correction afterwards
(`wide` opening a closed pane, `close` un-widening a wide one). The lit segment says where the page is, and
it is DERIVED from the display properties on every draw — the same read-from-the-document rule `current_view`
follows, with no second copy of the state to drift. A page ARRIVING opens the pane (generate, analyse, a
dropped `.html`, or picking a scenario that has one); closing it is always a decision, and it is also what
hands back the ~86MB a 48-deal page holds.

**THE SPLITS ARE PLAIN FLOWS, NOT FRAMESETS** (2026-10-04). All three views' `.split`s are `<div>`s with
`flow: horizontal`, ordinary `.divider` elements between the panes, and the widths as inline CSS — px for a
fixed column, flex `N*` for the rest, `box-sizing: border-box` so a number is the whole pane. Sciter's
`<frameset>` was used first and dropped after a run of measured faults, each found by fixing the last: its
`state` did not match its panes; a `display: none` pane still reported its old box; hiding a `<splitter>`
with `display: none` broke it so every later `state` write threw; it divided flex shares over content boxes;
and its own drag arithmetic applied the window's CSS zoom twice (at 110% an untouched `250px` became
`303px`). It ended with the hand page's bar drawn on top of the controls. Nothing sits between the CSS and
the code any more. Two things the frameset did for free now have to be said: the split clips
(`overflow: hidden`) and `.work` scrolls itself, or a tall pane makes the whole view taller than the window.

**THE DEALS LAYOUT IS A MODEL RENDERED ONE WAY** (`apply_deal_layout`). One value, `app.deal_layout`: the
list's and the controls' widths in CSS px; the hand page takes the rest (`1*`), like a sidebar-and-content
layout. Every show / hide / wide / startup renders the panes' widths from it plus which panes are shown, and
the controls' width is CLAMPED when rendered so the page always keeps `DEAL_PAGE_MIN_PX` (a width remembered in
a wider window or at a lower zoom would otherwise overflow). The controls and page were flex SHARES once, and a
drag log from the real window showed why that fails: this engine's flex units divide the space left AFTER each
pane's content (SDK `css/flows-and-flexes.md`), and a real card page claims nearly all of it — `1487*:835*`
rendered as 28px : 2294px. Dividers follow their panes (`show_needed_dividers`, run from `set_shown`).

**THE DRAG IS THE SCRIPT'S, AND THE RELEASE JUST READS IT** (end of `ui/workbench.html`, `take_deal_drag`). A
mousedown on `.split > .divider` captures the mouse and shields the frames (`.dragging` → frames
`pointer-events: none`); each move rewrites ONLY the two panes beside the divider, as CSS px (on-screen ÷
zoom), the right one `1*` if it is last; moves and the release are heard anywhere, and a move with no button
ends the drag. On release the host READS those inline widths into the model - no measuring: the layout lags
the mouse (~124ms a step with a 48-board page), and a measurement at release read where the panes WERE.
Hidden panes are detected by their INLINE display first (a hidden element can report a stale box). Debug
builds used to log every press, move, release, render and the settled widths; that is now OPT-IN with
`WORKBENCH_DRAG_LOG=1`, in any build (`WB_DRAG_LOG`, `drag_log`), because it flooded the console of every
debug run.

**The deals list has the editors' sidebar shape** (2026-10-20): a TITLE with the count in it (`#scenario-title`, "scenarios · 12 of 101"), the filter and groups indented under it, then the deals folder as one QUIET line (`pages in`, the `#outdir` field drawn as small dim text that edits in place, and `#outdir-pick`, a folder dialog). The always-on key-hint line went (the filter's placeholder says ctrl+r, the groups tooltip ctrl+g), and so did the count under the list. While `every scenario` is ticked the title carries an accent pill, "all 101 in the run", and every row an accent tint and left edge. Two engine traps there: a class on the LIST does not repaint rows already drawn without `update_element(list, render = true)`, and a class that changes a row's border WIDTH computes but is never laid out - so the rows always carry a 3px transparent left edge and the class only colours it.

**FOLDER → SCENARIO → FORMAT is the window's hierarchy, and all three levels are on screen.** The deals
folder heads the SCENARIO LIST (id still `#outdir`, labelled `deals folder`), with the filter and the groups
under it: all three act on that list, and as a strip across the top of the view they read as governing the
panels and the pane too (reported, 2026-10-10). Not in the generate panel either, because it says where pages
are READ as well as written — it decides whether the segment is alive at all. The deals bar keeps only the
window's layout: the list fold and the pane segment. Leaving that field re-reads the folder; per-keystroke would be six filesystem probes a
character on what is a network share by default. One `read_dir` then answers "what has been generated" for
every scenario at once (707 `stat` calls a redraw otherwise), and feeds two projections: format TAGS on each
list row, and a row of CHIPS for the selected scenario (the generate panel's last line, "view generated formats:" - it was a strip across the top of the view and read as governing the analyse panel and the pane too) — **all seven formats, always**, dead where no file
exists (absence has no shape otherwise, and two scenarios showed two different sets of chips), lit for the
one the pane is showing, and marked with an ↗ only where pressing it really does leave for a browser — which
is an `html-handviewer` page and nothing else (`hv` is `-f handviewer`: bridgebase query strings in a
`.hv.txt`, i.e. text). Anything in the pane can be sent to a browser from the pane's own `↗ browser` button,
which acts on what is SHOWN (an analysed page, which has no file, is written to `workbench-analysed.html` in the temp folder first, one file replaced each time) — the pane could otherwise
only ever open the newest output, leaving a `.pbn` written before the page unreachable. `.hv.txt` is matched
before `.txt` (longest extension wins); both html formats share `.html` and are still told apart by looking
inside the file.

**The pane segment is alive when there is a page to SHOW, not when one has been loaded.** A generate run
writes to disk and puts nothing in the frame, so the earlier reading left the segment dead after generating
— and with `view page` demoted there was then nothing on screen that would load one. Opening the pane is
what fetches the selection, which also means a window started on last week's folder can show what is in it.

**Picking a scenario shows its page, but only into a pane that is already open** — a hand page is up to 86MB,
so arrowing down a 101-scenario list must not load one per row, and a shut pane is someone not looking at
pages. A handviewer page is never followed in either state: those are an `<iframe>` per deal onto
bridgebase.com and need a real BROWSER, which no click in a list should launch. The `browser` button appears
for exactly that case and is hidden for every other kind — it is all that is left of `view page`, whose
loading job the follow took over.

**THE WORKBENCH'S OWN STYLESHEET IS CUT INTO `<style>` BLOCKS THAT FIT, AUTOMATICALLY** (`css_blocks` in
`workbench.odin`). An inline `<style>` is capped at 32 KiB in this engine, all or nothing — one byte over
and the whole block is discarded, first rule included, in silence — and `ui/workbench.css` crossed it at
35,781 bytes. **The symptom is not a styling one**, which is what makes it expensive: `behavior: button`
stops attaching, so scenario rows, file rows and palette entries answer `do_click` with `handled = false`,
and unrelated tests fail as though event routing had broken. The cap is per element, so the sheet is cut at
TOP-LEVEL RULE BOUNDARIES into blocks under a 24 KiB budget — block comments skipped whole (this project's
CSS comments quote `@set x { … }`), nested `@media` blocks kept intact, order preserved. A hand-placed split
marker was tried first and rejected: it is the same cliff one step back, still failing late and still
needing a person to know the trap. `test_the_stylesheet_is_cut_into_blocks_that_fit` and
`test_the_cutter_never_cuts_inside_a_comment_or_a_block` are the guards. The card page has the same cap and
a different answer (`norn` strips CSS comments from the emitted page; `page-check` asserts the byte count).

**The report pane is `readonly`, because `<plaintext>` IS an editor** — the same widget the notes view edits
with, so without it the run log takes a caret and typing that the next redraw discards. And the pane icons
carry their OWN ground and ink rather than `currentColor`: on the lit segment `currentColor` is
`--accent-ink` on an accent ground, which inverted the drawing (the empty half became the bright one) and
made `split` say "page on the left". Lighting a segment is the button's job.

**An analysed page keeps the pane until something else is asked for.** Opening the pane re-asks for the
selection only when it was CLOSED and the frame does not hold `analyse`'s page; `split` <-> `wide` never
reloads (reported: `wide` threw the analysis away for the selected scenario). The last analysed page is kept
(`app.analysed_page`) and `show last`, beside `analyse`, puts it back without analysing again. The pane is titled by its board
count (`analysed: 16 boards`) since one analyse can read a whole match; the hand page is the default and `as text report` the opt-out; and a dropped
`.pbn`/`.lin` leaves its PATH in the analyse box, which `analyse_job` reads as `--file` (`deal_file_path`) so it can be
re-analysed with other settings. While an analyse runs, a spinner stands in `show last`'s place
(`set_analyse_busy`) and a file of boards counts them there ("board 3 of 16"): `analyse.Sink` has an optional
`progress` hook, called before each board, which the worker posts as `ANALYSE_STEP`. `clear` is in the REPORT
pane's own header (`#report-head`), not the analyse panel - it empties the report, which generate writes to too. An analyse reports in ITS panel - its own small bar inside the busy mark and
`#analyse-status` - never the generate panel's `#fill` / `#status` (`set_job_status`, `set_progress` route by job
kind). `generate` reads `regenerate` when the run would replace a file (`refresh_generate_label`: the selected
scenario's file in the dropdown's format, or any scenario's with `generate every scenario` on), from the same
`read_dir` the chips use.

**Opening the hand pane re-asks what the follow asks.** A closed pane is not followed, so re-opening it
would otherwise bring back the file from before while the list, chips and status line all name another
scenario — `shown_page_is_the_selection` decides, and a page that already IS the selection is left alone.

**THE REPORT PANE IS THE EASIEST WAY TO FREEZE THIS WINDOW.** It is a `<plaintext>` — not virtualised,
~22KB a LINE — and every `TRANSCRIPT` message rewrites its whole content, so three rules hold: a batch never
echoes its deals (the echo is for ONE small text run — `every scenario` in `pretty` pushed ~74,000 lines and
the window went "(Not Responding)" for the run), a burst of lines costs ONE post (the worker claims an atomic
flag, the handler clears it before drawing), and the transcript is capped at 512KB keeping its tail. On top
of that `ui_thread_priority` raises the engine thread to ABOVE_NORMAL while a job runs — a generate batch
saturates the machine (the worker plus `combo`'s pool of up to 16), and raising the pump is the only lever
this program owns, since that pool is started inside norn.

**A pane is not just a narrower window, and three bugs came from treating it as one.** The hosted card
page's toolbar needs `flow: horizontal-flow` (`flow: horizontal` does not wrap, so at pane width the last
controls were clipped) with `max-width: 100%` to have something to wrap against; `page-check` now includes a
520px pane pass, since every other check in it runs at 1280. Hiding a split pane needs
`update_element(el, render = true)` on the split (`relayout_split`) or the survivors keep their old widths
until the next click. And the chips' lit state must be redrawn by `remember_shown_path` — drawing it in
`note_selected_page`, before the follow loads anything, lights the previous file's chip.

**`every scenario` is a setting of the generate panel, and shows itself in the list.** It overrides the
selection — 101 scenarios, one page each. It went from the generate panel to the bar and back (2026-10-10):
it is a property of the RUN, so it sits with the run's settings, and the list's wash is what keeps it from
reading as one more harmless switch. While it is
on, every row takes a soft wash and a left edge and the selected row keeps its stronger mark on top: what
the run will cover and which scenario the chips describe are different questions, both live at once. The
class goes on the LIST, not per row, because the rows are replaced wholesale on every redraw.

**The bar's icons are CSS BOXES, not `<svg>`** — bordered `<i>` elements coloured by `currentColor`, so they
inherit each button's colour and every state rule already in the sheet (`:hover`, `[disabled]`, `.on`)
recolours them for free. They started as inline svg (which does work, and `fill="currentColor"` with it) and
were replaced after a report that they degraded into a rounded corner as the window zoomed: a probe showed a
stroked `<rect>` losing its right and bottom edges under `zoom`, at any authoring. A border is drawn by the
box painter and laid out by the same box model as everything else, so it scales when a path does not. The
one diagonal — the chip's "leaves the window" mark — stays a `↗` glyph. No icon font either: a glyph cannot
be styled in parts, and this document is `#load`ed into the exe as one string, so a URL-loaded asset would
need the `this://app/` archive convention. **The editors' file actions are the exception** (2026-10-03):
new / folder / save / check / rescan / words, plus settings and about in the header, are inline Material
Icons (Apache-2.0) as FILLED `<path>`s with `fill="currentColor"` — standard pictures a box drawing cannot
match, and filled rather than stroked because it was the STROKE that lost edges under zoom. The windowless
test only proves they paint (`test_every_toolbar_icon_paints`); the GPU-zoom question needs a real window. The same filled-svg rule now covers the LIST TOGGLE in all three views (bulleted rows, 2026-10-20 - the box version, a band filled LEFT, read as the mirror of the pane's `split` box), the header's MARK (two fanned cards) and the generate / analyse section pictures. `test_snapshot_the_views` (opt-in, `WB_SNAPSHOTS=<folder>`) writes each view to a PNG for looking at a layout change.

**Themes are one attribute** (`theme.odin`): every colour is a token on `:root` (dark, catppuccin mocha) and
`html[theme="light"]` redefines them (latte); the settings view picks dark / light / system (Windows'
`AppsUseLightTheme`), remembered as `theme` in the prefs file. Two measured traps: descendants keep their
old colours until `update_element(root, render = true)`, and that restyle does NOT reach a hidden view — so
every view off screen is marked stale and `show_view` restyles it on its next showing. The frames (notes
preview, hand page) do not follow the window's theme: they are the published pages. But the engine gives a page with no ground of its own the SYSTEM's colours, so the card page's `@media sciter` block says `html { background: #fff; }` and its buttons' ink (a dark Windows showed a black page with unreadable titles and buttons, 2026-10-20); page-check guards both.

**The notes have a LOOK of their own** (`workbench/notes_look.odin`, Settings' "Notes look", 2026-10-20): page
classic / white / dark, suits four-colour / two-colour / colour-blind, font. `bml.css` (the bml repo's) names
its colours and font as `--bml-*` tokens on `:root`, and a look is a second `:root` block after it - appended
in the preview and the quiz's notes panel, and, with "built pages: this look", written to `bml-look.css` in the
notes folder, which `just bml` appends to the `bml.css` it copies. The html never changes, so parity and the
goldens do not move. The file's EXISTENCE is that setting. `test_the_original_notes_look_is_the_stylesheets_own`
keeps the default preset equal to the sheet's values.

**The hand page has a LOOK too** (`workbench/hand_look.odin`, Settings' "Hand page look", 2026-10-20): felt green / blue / grey, cards white / cream, and the SUITS - one setting (`suits`) shared with the notes, asked for (`notes.suits` is still read when it is absent). A look is plain rules on the card page's OWN selectors (`.suit.c`, `.compass`, `.seat`), not tokens, so pages written before it take it too; the original look is no rules at all. **It goes into the MARKUP before the page loads**: measured, a `<style>` appended to a loaded document (createElement or insertAdjacentHTML, restyled or not) and a `CSS.set` style set on its root apply nothing in this engine. So with a look chosen, `show_page_file` reads the file and loads it as html with the block in its head (`load_file_with_look`; the original keeps `loadFile`), `show_page_html` adds it the same way, and a change of look reloads the page when the deals view is next shown (`hand_look_stale`). "saved pages: this look" writes it into pages a run writes via `norn.page_look_css`, set in `start_job` before the worker exists. Share links keep the original.

**A horizontal flow does not centre children of different heights**, and an inline-block sits on the
baseline — which is why the deals bar needed a box on its bare labels (`display: inline-block`), a button
that lays out its own icon-plus-word content (`flow: horizontal; vertical-align: middle`), and the same
property on the segment GROUP. The same property on the `.bar` itself measured as a no-op. Layout of this
kind must be asserted ACROSS THE ZOOM: at 100% the broken bar looked settled and the first version of
`test_the_deals_bar_lines_up` passed on it; the faults appear from 133% up, where paddings, borders and text
round differently.

**When a drawing looks wrong in the window and right in the tests, suspect the RASTERIZER.** The windowless
harness is software Skia; the real window is on a GPU backend by default. The svg-under-zoom defect above
does NOT reproduce windowless — pointed at the old icon the new test passes — so `WORKBENCH_GFX=raster` is
the bisect, and some drawing bugs have no witness but a real window.

**THE WORKBENCH TESTS ARE PAID FOR IN PAINTS** (2026-10-09: 70-100s -> 18s). A windowless view has no
pump of its own; `pump(&app)` is 8 heartbeats (~2us each: posted work, timers, events) and ONE paint (~11ms at
1120x780 in software Skia). The paint is not optional - layout only settles in it, and drag/zoom/fit checks
fail without - but one per pump is enough (it was one per heartbeat). Inside a gesture use `beat()` (the
heartbeats alone) and `pump` once before measuring. Tests that only need the notes corpus open its SMALLEST
chapter (`editor_corpus`): opening the 57KB first chapter cost ~220ms per test plus its teardown in the next.
`just test-workbench-timings` prints setup / pumps / the test's own work per test (opt-in
`-define:WB_TEST_TIMINGS=true`); the runner's own log has whole-second timestamps. Timers run on the WALL
clock, so a debounce never fires in a test - call what it would have called.
**`just test-workbench [SHARDS=4]` runs the tests in N PROCESSES at once: ~6s against ~18s for
`test-workbench-serial`, which stays for debugging one test (`-define:ODIN_TEST_NAMES=main.<name>`).** One process must stay one thread (Sciter's thread affinity, one shared windowless view that cannot be
re-created, DDS), but N processes are N engines: the exe is built ONCE (`odin build -build-mode:test`) and
started N times with the runner's run-time `-tests:` list (`tools/test_shards.py`). Tests touching
`target/debug` as a deals folder (`PARITY_DIR`) all run in shard 0; the rest are balanced on their last
measured times. A new test writing a shared path must either name a folder of its own or use `PARITY_DIR`
(which pins it to shard 0) - two shards writing one file is the failure this cannot see.

**THE EDITOR VIEWS PUT EACH CONTROL ON WHAT IT ACTS ON** (2026-10-10), the deals view's rule. The bar is
layout only (`◧ files`, ctrl+b; the notes' `preview` segment) plus `?`; the STATUS line is a `.statusbar` under the panes, as an editor's mode line is (it was squeezed into the bar beside the layout buttons). The scenarios tab reads `my scenarios` (data-view still `scenarios`): "scenarios" alone did not say this is where you write your own. The notes preview
is the deals view's three-position control (`data-preview` closed / split / wide, `Pane_Mode` again, derived by
`preview_mode` from `bml_showing` and whether `#bml-source` is hidden; ctrl+t / ctrl+\ cycle it on both views, ctrl+shift+t back the other way, one shared `next_pane_mode`):
a toggle whose label turned into `close` did not read as closing the pane on the right. Wide hides the SOURCE
and leaves the file list to ctrl+b; closing brings the source back. The FOLDER actions
head the sidebar (`add…`; the scenarios' `add…`/`rescan`/`new…`; the folder buttons were `folder…` until 2026-10-20, a folder-with-plus picture now). Each pane
of the split is a `.pane` WRAPPER - a `.pane-head` then the widget - so the source is TITLED with the open file's name and its unsaved dot (`draw_file_title`, redrawn with the file list and on each key-up; the status line no longer repeats the name) and carries `save` (and the
quiz / `check`), the notes preview carries `fold`/`links`, the scenario report carries `words`. The drag
and `set_shown` act on the wrapper: the preview is `#bml-preview-pane`, which starts hidden.
The notes have a FOLDERS LIST above the files (`notes_dirs.odin`, the scenarios view's `.sources` shape): the folder found at startup first and never forgettable, `add…` adding one (`notes.dirs`), the open one remembered (`notes.dir`) and reopened at the next start. Both editor sidebars read SECTION TITLE (`.side-title`, "notes folders" / "scenario folders") > its actions indented under it (`.side-actions`, wrapping; the scenarios' `add…`, `rescan` and `new…` all one size) > the folders > a small `files` subheading (`.side-sub`) > the files (2026-10-20). Each view's bar puts the sidebar toggle left and the pane's controls right (`.bar-gap`), so the toggle is not read as one group with the preview segment. The notes' file list is an INCLUDE TREE (`bml_file_tree`): files nothing includes, alphabetical, each
followed by its `#INCLUDE`s indented under it (read from disk on each redraw; a file two roots include is
listed under both; a cycle is not followed), and each top-level group after the first starts with a gap and
a seam (`.row.top`).

**The notes view is an editor, not a viewer**, and two engine facts are why it did not look like one. The
caret colour is `text-selection-caret-color` (the browsers' `caret-color` does not exist here), so the default
black caret was invisible on the dark field; and this engine paints a caret only in a FOCUSED widget, so the
view now focuses its source pane when it opens. On an EMPTY line the caret is drawn a whole cell wide and the
block is left behind when the caret moves off — stale paint, measured (the selection model is identical either
side of every pass this document runs), cleaned up with `requestPaint()` on keyup/mouseup and after any
shrinking edit.

**CTRL+BACKSPACE IS THE SCRIPT'S, in both editors** (2026-10-19). The engine's own word delete breaks the
widget when it empties a line: the caret vanishes until a key brings it back at the top of the text, and the
window froze twice. `bmlDeleteWordBack` counts the word and does that many plain backspaces in one
`plaintext.update` (one undo step). Two engine facts it rests on: a widget handles its keys AT THE ELEMENT, so
a bubbling `document.on("keydown")` hears them too late - the handler is a CAPTURE listener on each editor;
and `plaintext.selectRange` only moves the caret here (start and end both read back as the range's end), so
select-then-delete removes one character. `WORKBENCH_KEY_LOG=1` prints every key the editors get, with the
caret either side; `WORKBENCH_CHECK_LOG=1` the scenario check's runs.

**Typing pays for the lines that changed, not for the buffer.** The colorizer keeps each line's last-marked
text ON THE LINE ELEMENT (an index breaks the moment enter or backspace moves a line), so a burst of keystrokes
costs a 2-8ms walk instead of a 49-203ms whole-buffer pass of `Range` work. The squiggle-clearing does the
same, over the elements it marked.

**The BML preview is LIVE**, debounced by what a render COSTS rather than by file size: ~100ms for a chapter
folded, 157-512ms whole, **1.02s for the assembled root** — of which the parse and `render_html` are 4-18ms
and the rest is the engine building the sub-document. The delay is `max(base, 4 × last render)` capped at 3s;
`WORKBENCH_LIVE_MS` sets the base (0 = off; the same knob and rule drive the scenarios tab's `check`, which
follows the typing too, ~8ms a scenario), `WORKBENCH_COLOUR=0` turns the colorizer off, and the two exist
to bisect anything that goes wrong WHILE TYPING. **The render is POSTED, never run in the frame's own timer
handler**: the timer belongs to the preview `<frame>` (`.TIMER` never reaches a window handler) and the render
replaces that frame's document, so doing both in one dispatch tears the tree out from under the engine and the
window stops answering.

**A heading in the preview is a link to itself in the source** (2026-10-19): a click moves the source's caret
to it, so a FOLDED preview opens that section (the fold follows the caret), and a heading from an `#INCLUDE`d
chapter opens that chapter, as the palette does. The preview is another document, so the handler
(`on_preview_click`) is attached to the framed document's ROOT after every render, and the jump is POSTED
(`HEADING`) - it re-renders the document the click is being delivered in. Matched by anchor id, the n-th
heading with an id to the n-th in the source; a click on a link inside a heading stays the link's. **A LINK never loads into the preview** (`follow_preview_link`, 2026-10-20: the overview's GitHub link replaced the preview with GitHub's page): `#Anchor` is left to the page, a web address goes to the system browser, a relative `.html` opens its `.bml` from the folder (posted), anything else is refused in the status line. The handler is the same one on the framed root, subscribed to `.BEHAVIOR_EVENT` for `.HYPERLINK_CLICK`.

**The notes' problems are listed UNDER THE SOURCE** (`#bml-problems`, `draw_bml_problems`, 2026-10-21), replaced
on every render, a click on a row going to its line (opening an included chapter first). They used to be
written to the transcript, i.e. the DEALS view's report, and appended on every live render. The `links`
check counts a heading as defined when every ROOT that includes the open file defines it (`page_anchors`,
bridge-markup's `Parse_Options.known_anchors` + `heading_anchors`): only roots are published, so a chapter's
link to a sibling chapter works on the page a reader has. Clearing an element is `set_text(el, "")` -
`set_html(el, "")` hands the engine a nil pointer and leaves the old content.

**CTRL+R in the notes view is the heading palette** - Sublime's `goto symbol` over the WHOLE corpus
(~1000 headings in 19 files), the open file first. Type part of a name; the letters need only be in order
(`lbn` -> Lebensohl) and **spaces and punctuation are separators rather than characters**, so `1h 1s` finds
`1H-1S`, `1H--1S` and `1H/1S` alike - nobody types the dashes. Enter moves the caret there (loading another
chapter if the heading is in one) and scrolls BOTH panes: the source with `set_scroll_pos`, since
`selectRange` moves the caret and does not scroll, and the preview by finding the heading's rendered element
**by its anchor id** (`bml.normalise_header_id`, public in `bridge-markup` for this) - a heading is BML, so
`1!c-1!s` renders as suit glyphs inside spans and matching its TEXT can never work. A frame's sub-document
has its DOM the moment `loadHtml` returns but not its layout, and an unlaid-out document clamps every scroll
to zero while reporting success, so the preview scroll is verified by re-reading `scroll_info` and retried on
a timer attached to the frame element (`WORKBENCH_SCROLL_LOG=1` prints what each attempt measured, to the
console; it used to go to the deals report in every debug build, once per preview render). A row shows the heading as the PAGE reads it (`bml.render_inline`, suit glyphs and all); the query still
matches the source text. The model, the fuzzy scoring and the ranking are `outline/`; the DOM
half is `workbench.odin`.

**`share link` puts the hand pane's page in a LINK** (2026-10-11, `SHARING_PLAN.md` Tier B). `share/` is the
payload (14 bytes a board, base64url after `#v1.`) and reads the boards back out of ANY card page (each
`.compass`'s `data-hv` plus the seat marked `is-dealer`); `player/` is norn + `combo` compiled to `js_wasm32` as
ONE fixed `player.html` that rebuilds the page in the reader's browser. Both are held to the native page byte for
byte (`just test-share`, `just test-player`, the latter in node). The workbench BUNDLES a vendored copy
(`ui/player.html`, `just vendor-player`) - **re-vendor whenever norn's card page changes**, or links rebuild
the old page. Links open the PUBLISHED player, `share.PUBLISHED_PLAYER` (bridge-workbench.netlify.app, deployed by
`just publish-player`), unless Settings' `player at` (`share.player`) or `sim`'s `SHARE_PLAYER` names another;
only a setting that is not an address at all (`share.usable_player_address`) falls back to that copy written to the
deals folder as a `file:///` address (this computer only, and the status line says so). Two build facts:
every `_test.odin` in norn, `combo` and `share` starts with `#+build !js` (this compiler resolves test files'
imports in an ordinary build, and `core:testing` pulls in `core:os`, a compile-time panic on js), and `combo` on
wasm needs `-define:COMBO_THREADS=false`. `rand` is not portable to wasm32 (32-bit `int`: same seed, other
deals), so a link carries deals, never a seed. Par travels as the solver's NUMBERS: the caption is written by
`par_caption/` (DDS-free; `deal_solve` converts its results), and each caption carries them as `data-par`. The
card page has its own Share button (`ncShareFragment`, held to `share.encode` by `page-check`); its address is
`norn.share_player` (Settings in the workbench, `SHARE_PLAYER` for `sim`).

**Drop a file on the workbench window.** A hand-diagram screenshot (PNG, JPEG, BMP, GIF) is read IN-PROCESS by
hand-ocr's Odin port (`hocr:hand_ocr`, `read_hand_image` in `workbench.odin`; it was a `uv run --project
$HAND_OCR_DIR` python subprocess, ~1s a picture, until 2026-10-21 - the port takes ~20-80ms and reads the same
deals). The deal it read lands in the analyse box so a misread card can be corrected; a board that reads as an
impossible deal is put there too, with the problem in the transcript, and NOT analysed. Otherwise it is analysed with whatever the
analyse panel says (`sample`/`contract`/`target`/`defenders`/`as text report`; `defenders` is `--lead`/`--void`/`--len`, one word each told apart by shape, `defender_flag`; those settings are remembered as `analyse.<id>` in the prefs file, saved when an analysis reads them without an error, `remember_analyse_settings`). A `.pbn`/`.lin`/`.txt` is analysed via
`--file`; an `.html` is shown the way "view page" would show it. Two measured engine facts hold this up, both
easy to get wrong: the EXCHANGE group **never reaches a window handler** (the drop is refused in silence, which
reads as the app not accepting drops) so the handler is attached to the document ROOT, and **both**
`.WILL_ACCEPT_DROP` and `.DRAG` must be consumed or no `.DROP` arrives. On Windows the payload is
`MAP{"file": ARRAY["file:///C:/..."]}` — a percent-encoded URL, not a path; on Linux the same map came back
EMPTY, so the feature is Windows-shaped and says so rather than swallowing the drop.

The **card page is also a desktop document.** The workbench shows the same interactive page (`Html_Cards`)
inside a Sciter `<frame>`, and it fits there because of ONE append-only `@media sciter { … }` block in
`~/dev/norn/norn/html_cards_header.html.tmpl` plus three small shims in the footer template's script
(`setHidden`/`isHidden`, `viewW`/`viewH`) — browser-correct code either way, and a browser never matches an
unknown media type, so the published pages on `w:/deals/` are byte-for-byte unaffected. Two things about
that block are load-bearing and easy to undo by accident: it must stay ABOVE the phone
`@media (max-width: 640px)` (Sciter cannot parse that query and the parse error discards the rest of the
stylesheet), and the numbers in it are for a desktop window rather than a phone. `just page-check`
is the automated check — it renders a deal, loads the page into a windowless engine view and asserts the
board's box, the trick slider's control type and that the CCA overlay really opens; `just page-check
-unported` runs the same checks with the block cut out and expects them all to fail. Editing the card page
in norn without running it is how that port silently rots: an unported page does not fail to load, it just
lays out wrong. **The harness re-inserts the Google Fonts `<link>` the page no longer has** (2026-10-10,
`render_page` in `page_check.odin`): without an external stylesheet still LOADING while the script builds
the carousel, this windowless software engine paints opacity-below-1 elements wrongly or not at all (the
neighbour boards opaque and unscaled, the face-down W/E row missing) with the DOM and computed styles
identical to a good run. The real window is correct without it; a slow URL hides it, an instant `data:`
sheet does not. Don't take that line out to "make the check offline".

Two DEBUG-ONLY affordances exist because a windowless check cannot see hover, a drag, or a window someone
resized — and nearly every layout bug in the hosted page was found by looking at the real window. Both are
`when ODIN_DEBUG`, i.e. `just workbench-debug`: a **`dump` button** in the page bar writes the framed
document's boxes and the computed styles this engine reads differently into the transcript and to stderr
(paste-able into a bug report), and the SDK's **inspector** (`just inspector`, from `SCITER_SDK_DIR`)
attaches over a socket for the interactive version. The inspector needs three things and the release build
grants none of them on purpose — the window flag, `set_debug_mode`, and `.SOCKET_IO` for the script, which
the hosted page would inherit.

**AN INLINE `<style>` IS CAPPED AT 32 KiB in Sciter, ALL OR NOTHING** — at 32,769 bytes the WHOLE block is
discarded, its first rule included; it is not truncated at the cap (re-measured 2026-08-20 by bisection,
32,741 applies / 32,769 does not; the earlier "the rest of the sheet is dropped" reading was wrong). No
warning, and the engine's CSS diagnostics go quiet for that sheet at the same moment. The card page's
`<style>` had reached ~32.6 KB, so one added comment silently took the ENTIRE stylesheet — visible symptom:
hands the full width of the window, which reads like the `@media sciter` block alone had gone. **The scope is
one inline `<style>` element**: two blocks of 20 KB both apply, and a `<link>`ed sheet has no cap in reach
(100 KB measured, every rule live). `norn`'s `render_page_prologue` strips CSS comments from the EMITTED page
— 33.3 KB down to 18.4 KB, browsers cannot tell — and `just page-check` asserts the byte count so it
cannot creep back. Comment-stripping buys headroom but leaves the cliff; splitting the emitted CSS across two
`<style>` blocks is what removes it, and keeps the page single-file (a `<link>` would not — these pages are
copied to `w:/deals/` and handed to a `<frame>`). Two keyboard facts from the same session: the engine fills in
`event.code`, NOT `event.key` (so the page reads either), and a key only reaches a document once something
inside it holds the focus (the workbench focuses the framed `<body>`) — the arrow keys and the
`a`/`n`/`e`/`s`/`w` seat shortcuts work in the window because of those two.

**A full deal analysed with a make chance opens the CCA panel in BLIND** (2026-10-20): the deal was sampled
as if the defenders were unseen (`data-sim-blind`, `render_full_deal_body`), and that is what the reader asked
for, so the panel starts there until they pick Exact. While it reads blind the two hands declarer cannot see
are faded and labelled "unseen by declarer" (`syncBlindFade` in norn's footer template). **That change is
applied on a zero TIMEOUT, not inside the caller**: changing the seats (a class on the slide or compass, an
inline style or the note, all three tried) inside the Exact button's own re-render crashed Sciter a frame
later with an access violation. `page-check`'s `check_the_blind_fade` holds it.

**Performance of the hosted page is a LAYOUT question, measured.** Every board on a card page takes part in
layout whether or not it is on screen, and the engine re-lays out all of them on each window-resize step:
124ms per step at 48 boards, against 6ms with the far boards parked (`display: none`; `visibility: hidden`
does not help — the boards keep their boxes). The card page therefore parks the boards outside a small window
round the active one, which is also free money in a browser. `border-radius`, `opacity`, `scale()` and
hiding all the text made no measurable difference to that LAYOUT cost, and neither did `set_debug_mode`.

**BUT `box-shadow` IS MOST OF THE PAINT** (measured 2026-10-09, and it corrects the line above for paint):
a 16-board page at 1700x1100 painted in 197ms with its drop shadows and 16ms without - the active felt's
spread ring (a `box-shadow` the size of the board) ~90ms alone. Every frame of a window resize is a full
paint, so the `@media sciter` block draws the rings as `outline` and the felt and hands flat (browsers keep
the shadows). A shadow in the card page or the workbench's own sheet is a cost to measure, not a nicety.
Settings has a Graphics choice (`gpu` / `software`, pref `graphics`, read before the window exists, so it
applies at the next start; `WORKBENCH_GFX` overrides it). And the page lays out only the ACTIVE board while a
size is changing.

**AND NO `vw`/`vh` IN A HOSTED PAGE** (measured 2026-10-10, real window only). With a card page LOADED,
every frame of a window resize cost ~150ms more (~45ms -> ~200ms on a 4K screen), on the GPU and the
software layer alike - with the page's body hidden, with the frame `display: none`, with the pane CLOSED. A
page whose `vw`/`vh` lengths were swapped for px was back at ~45ms, hidden or not; the font link, the script
and the media queries made no difference. So a viewport unit anywhere in the cascade makes each resize step
restyle the whole document. **The windowless harness cannot see this** (a hidden page there costs ~6ms a
step either way), which is why the bisect was done in the real window with `WORKBENCH_FRAME_LOG=1` and
`WORKBENCH_PAGE_STRIP` / `WORKBENCH_PAGE_CSS` (they rewrite an ANALYSED page, not a file). OVERRIDING the
units is not enough - a visible page stayed slow while a base rule still named one - so the card page's base
rules carry their viewport lengths in `:where(html) …` copies placed right after each rule (this engine drops
such a rule, alone, with an "unrecognized css selector" warning; a browser applies it at the same place and
specificity; `@media not sciter` does NOT work - this engine matched it and dropped every rule after it) - the
phone `@media (max-width: 640px)` block INCLUDED: this engine reports it as a parse error, yet its `vh` still
cost the full ~150ms. With no viewport unit left the carousel's height stops following the view, so the
page's size watch reads the view too, and re-centres once more after new sizes land. And
the `@media sciter` block re-says every viewport length as a Sciter variable, `length(nc-h240)` =
2.4% of the view's height, set by the page script's `setViewUnits` once a size settles (the cards keep their
size during a drag and adjust when it stops). Two engine facts it rests on: only the Sciter form updates
from script (`style.variables({'nc-h240': '21px'})` + `length(nc-h240)`; a standard `--x` set the same way
does not), and a `font-size: calc(2.4 * length(x))` is computed once and never follows the variable - so one
variable per size, used bare. An earlier note here blamed ~150ms a step on the GPU layer itself; that was
this, measured with a page loaded.

The one host-side lever is the graphics layer — and it is already pulled: per the SDK's changelog a GPU backend is
the DEFAULT everywhere (Windows DX12/Vulkan with an OpenGL fallback, Linux Vulkan, macOS Metal), so
`WORKBENCH_GFX=gpu|vulkan|opengl|raster` exists to FORCE one, or to fall back to software when a GPU path
misbehaves. `graphics_caps` is not the answer to "which layer am I on" — it is a Direct2D-era 0/1/2 rating
that reports `Software` on a GPU-default build, and nothing in the API reports the active layer.

**"view page" opens what the scenario HAS, newest first** — `<name>.html` / `.txt` / `.pbn` in the output
directory, decided by the filesystem rather than by the format dropdown (which says what the next run will
write, not what exists). Both html formats share `.html`, so the kind is read from inside the file:
`nc-track` means a cards page, `handviewer`/`<iframe>` means a handviewer page. It then does three different
things, because the formats are three different things. html-cards is hosted in the frame. **html-handviewer is opened in the system browser**: it is an `<iframe>` per deal onto
bridgebase.com, so in the frame it makes dozens of https requests and the site then reports javascript as
disabled — it wants a browser, so it gets one. pretty/line/pbn are shown in the frame as text (wrapped in a
one-`<plaintext>` document, so `<` and `&` in a PBN cannot be read as markup).

The **card-combination engine** (`combo`) is NOT here — it lives in the norn library as `norn:combo` (`~/dev/norn/combo/`): generic bridge maths, no bidding-system content, and norn already owns the card-page JS that renders its output. Per-suit, entry-free model with narratable lines — the explanatory counterpart to `deal_solve`'s solver truth. Lint/test it in the norn checkout (`just lint`, `just test-combo`). It also carries its OWN suit-combination table, self-generated by an
optimal single-suit solver (`combo/suit_solver_table*.odin`, baked by `just bake-suit-lines` in norn: hours at
every tier, about 10 minutes with `max-tier=0`; resumable from `<out>.partial`). One line per CLASS of holdings (who holds each card from the 8 up, plus the small-card
counts), valued in the class's worst layout of small cards, so its chances are a floor. Each entry also keeps
its line split by East's length (a joint table), so where the BridgeHands book is silent the line is one more
CANDIDATE beside the fixed lines (`SOLVER_LINE`): picked as the suit's blind line when its floor is the best, it
feeds the blue `sd` row (then labelled `sv`), the `E` blind mean, the sd total, the `>=sd` curve and the page's
a-posteriori re-pick. The wasm player carries the table too (gzipped in its page: 503KB -> 747KB), so a
link rebuilds the same page; `combo.set_suit_solver_table(false)` turns it off for a process.
Changing the solver or its narration means a re-bake: the drift-guard test fails otherwise. A change only to
what an entry stores needs `just bake-suit-lines redo=1` (each entry re-solved at its recorded tier, ~1 hour). A change
only to the FIXED LINES is a plain bake that decides most classes from their search records
(`combo/suit_solver_table_data.odin.searches`, kept across bakes) and searches only where a line may beat the new fixed
ones; a change to the search itself means bumping `combo.SOLVER_SEARCH_VERSION`. Plan and results:
`SUIT_SOLVER_PLAN.md`.
