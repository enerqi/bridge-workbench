# Bridge Workbench changelog

One `## <version>` section per release; the release workflow publishes that section as the release notes
and refuses a tag without one. Versions are semver, `0.1.0-alpha.1`; the tag is `v0.1.0-alpha.1`.

## 0.1.0-alpha.4

Mostly the notes editor, which is now a real editor for BML rather than a text box beside a preview.

**Writing notes**

- **Syntax highlighting**: headings by level, the calls of a bid table (alternating by depth, as the page
  draws them), opponents' calls, alerts, suits, links, numbers, convention names, conditions, comments, hand
  diagrams and auctions each have their own colour, in both themes.
- **Indenting**: Tab, Shift+Tab and Enter indent with spaces; Backspace in an indent goes back a level. Bids are
  capitalised as you type, and ` = ` is written for you after a bid. **Tidy** re-indents bid tables (4 spaces a
  level), and indentation problems show in the problems list.
- **Completion** from a list of bridge terms (and, optionally, the words of your own notes): Tab accepts,
  Ctrl+Space shows the next.
- **Links and inserts**: Ctrl+K (or typing `](#`) links to a heading; Ctrl+I inserts a BML construct.
- **A BML guide**: every construct of the notes' markup, its source beside how it renders, each with an
  `insert` link that writes it at the caret: the **guide** button, or Ctrl+G.
- **Find and replace**: Ctrl+F, Ctrl+H, F3 / Shift+F3; match case and whole word.
- **Line keys**: Ctrl+L selects the line, Ctrl+Shift+K deletes it, Alt+Up/Down moves it, Ctrl+/ comments it
  out. Ctrl+Left/Right move by word and no longer stick inside `S: Qxx`.
- **Ctrl+O** opens a notes file by name from any of your notes folders; Ctrl+Shift+O adds a folder.
- A key the editor takes for itself (Tab, Enter, `=`) no longer also types its character.

**How the notes look**

- **Settings > Notes look**: presets for the page, suit colours, fonts and the bid cells (square, rounded, fade,
  bar), fine tuning of each colour and font, and **profiles** - a whole look saved under a name, loaded again
  with one click; deleted profiles can be restored. Built pages can keep the original look or match the
  preview.
- **Settings > Notes editor**: the editor's own font, size and line height, and its colours (headings, calls,
  marks, the caret), kept separately for the dark and the light theme. The line holding the caret is tinted,
  so the caret is easier to find (it can be turned off). Profiles here too, with a built-in **theme** profile
  that goes back to the theme's own look.
- The preview shows a page's list of links once, at the top, rather than again under every heading.
- The notes' stylesheet is bundled, so the preview looks right on a machine without the BML tools.

**Pages and quizzes**

- **Export** the open notes as pages (opened in the browser), as a zip, or every notes file in the folder as
  one zip.
- The quiz shows, under an auction that means different things in different places, the headings that tell
  them apart, and never offers the same auction twice; suit symbols are coloured.

**Analysing deals**

- The progress bar moves while random layouts are simulated.
- "Make chance" is now **simulate N random layouts**, and the card page's Exact / Blind toggle reads **This
  deal / Random layouts**.
- The box you paste a deal into grows with its text.

## 0.1.0-alpha.3

- The program has its own icon on the taskbar, in Explorer, on its Start-menu and desktop shortcuts and in
  Settings > Apps, instead of Windows' generic program icon.

## 0.1.0-alpha.2

- The installer no longer asks whether to install for you alone or for every account: it installs for you,
  with no administrator rights needed. To install for every account (into Program Files, as administrator),
  run it as `bridge-workbench-0.1.0-alpha.2-setup.exe /ALLUSERS`.

An existing 0.1.0-alpha.1 install is upgraded in place.

## 0.1.0-alpha.1

The first public build. **Alpha**: the built-in scenarios are about to be reorganised, and anything may
change.

- Generate practice deals for an auction, from the built-in scenarios or your own scenario files, as an
  interactive card page, a BBO hand-viewer page or text.
- Analyse a deal you already have: paste it, drop a `.pbn`/`.lin` file, or drop or paste a SCREENSHOT of
  a hand diagram (BBO, IntoBridge, BridgeWebs, RealBridge, club prints) - it is read into a deal you can
  correct, then analysed.
- Edit bidding-system notes (BML) with a live preview, and make quiz pages from them.
- Share deals as a link or a QR code.

Windows 10/11, x64. The installer needs no administrator rights. The program is not yet signed, so
Windows SmartScreen may warn on first run: choose **More info**, then **Run anyway**.
