package main

/*
	notes_guide.odin — the BML GUIDE: every construct of the notes' markup, its source beside what the page
	makes of it, in the preview pane (`guide`, in the preview's head). Asked for 2026-10-28 as a tutorial
	page showing how each feature renders.

	THE RENDERED HALF IS NOT WRITTEN DOWN: each example's source goes through `bml.parse` + `bml.render_html`
	when the guide is shown, so the guide cannot drift from the renderer - a change to how a diagram is drawn
	shows in the guide the next time it is opened. Only the sources and the sentences about them live here.

	Each example has an `insert` link that writes its source at the editor's caret (one undo step, through the
	same `insert_into_source` the insert palette uses), so the guide is also the friendlier way to add a
	construct: see it, then take it.

	While the guide is up the live preview leaves it alone (`preview_bml` returns early), so typing an example
	in does not throw the guide away; `guide` again goes back to the notes.
*/

import "core:fmt"
import "core:strings"

import bml "markup:."
import sa "sciter:sciter_app"

Guide_Example :: struct {
	label, about, source: string,
}

GUIDE_EXAMPLES :: [?]Guide_Example {
	{"headings", "* at the start of a line, ** under it, down to ****. A * heading is listed in the page's side links.", "* Openings\n\n** One of a major"},
	{"text styles", "*bold* (not at the start of a line - that is a heading), /italic/, _underline_, =monospace=", "A *strong* hand, /maybe/ _forcing_; ask with =4NT=."},
	{"suits and dashes", "!s !h !d !c are suit symbols, and a bid like 2H or 1NT gets one by itself. -- is a dash between numbers.", "Lead the !s5. 2H shows 5+ !hs and 11--15."},
	{"bid table", "a bid, = and what it means; the replies indented under it, 4 spaces a level (tab does that)", "1N = 15--17 balanced\n    2C = Stayman\n        2D = no major\n        2H = 4+ hearts\n    2D = transfer to hearts"},
	{"a longer meaning", "a meaning that runs on: the lines after the bid, indented under it, with no = of their own", "2C = strong, artificial:\n    - 22+ balanced\n    - any game force\n    2D = waiting"},
	{"competitive bid table", "their calls in brackets, the calls of the auction joined by --", "(1H)--X\n    1S = 4+ spades, 0--8\n    2C = 4+ clubs, 0--8\n    2H = cue bid, game force"},
	{"seat and vulnerability", "in a bid table's meaning, (NV) (VUL) NV VUL, 1st/2nd 3rd/4th, 3rd seat, 4th position and passed hand are drawn as tags, so where a meaning changes stands out", "2H = 5+ (NV) / 6+ (VUL) card weak two, 1st/2nd\n    2N = ask, natural invite by a passed hand"},
	{"bullet list", "- at the start of each line", "- 5+ hearts\n- 10+ points"},
	{"numbered list", "1. 2. 3. at the start of each line", "1. Count your tricks\n2. Plan the play"},
	{"description list", "- a term :: what it means", "- Stayman :: 2C asks for a major\n- Jacoby :: 2D and 2H transfer"},
	{"table", "| cells |, a |---+---| line under the header row. Tab lines it up and goes to the next cell.", "| Points | Action |\n|---+---|\n| 0--7 | pass |\n| 8+ | invite |"},
	{"auction", "calls only, any number a line: P X XX AP, ? for the call asked about, - for a seat before the dealer. Enter lines it up.", "W N E S\n- 1H P 1S\nP 2S AP"},
	{"auction with notes", "2C* or 2NT^1 points at a note under the auction (* ... or ^1 ...); P! is alerted", "W N E S\n1H 2C* 2NT^1 P!\n* natural\n^1 Lebensohl"},
	{"deal diagram", "a header line (board, dealer, vulnerability, contract like 3NS, lead like sQ), then the hands: N: spades hearts diamonds clubs, - for a void", "#7, Dealer N, None, 3NS, sQ\nN: AKxx Qxx Kxx Axx\nS: xxx AKx AQx KQxx"},
	{"caption", "#+CAPTION: a title over the diagram, auction or table under it - not a heading, so no new section", "#+CAPTION: Board 7 - the hold-up\nW N E S\n- 1N P 3N\nAP"},
	{"side by side", "#BOX ... #ENDBOX: the diagram, auction or table it starts with on the left, the text after it beside them", "#BOX\nN: AKxx Qxx Kxx Axx\nS: xxx AKx AQx KQxx\n\nNine tricks on top: duck the first spade and the defence is cut off.\n#ENDBOX"},
	// EVERY KIND, not one (reported 2026-11-02: Settings' notes look colours note, info, tip, warning and the
	// titled box, and the guide showed only warning).
	{"callout", "#BOX note, info, tip or warning, then a title if you like: the box in a coloured frame. #BOX Title alone is a grey frame. Settings > Notes look colours each kind.", "#BOX note Remember\nOur 1NT is 15--17 in every seat.\n#ENDBOX\n\n#BOX info Why\nA weak 1NT is harder to compete over.\n#ENDBOX\n\n#BOX tip Tip\nWith 4-3-3-3, count the 4-card suit as a stopper.\n#ENDBOX\n\n#BOX warning Systems on\nAfter our 1NT is overcalled 2C, X is Stayman and transfers still apply.\n#ENDBOX\n\n#BOX Titled\nA plain frame with a title.\n#ENDBOX"},
	{"class hook", "{.name} at the end of a heading, #BOX or #+CAPTION: line gives what it makes that CSS class, for a stylesheet of your own; the text and the heading's link leave it out", "** Defence to 1NT {.danger}\n\n#BOX tip Systems on {.compact}\nX is Stayman.\n#ENDBOX"},
	{"links","[text](#heading) goes to a heading (ctrl+k picks one); [text](https://...) to the web", "See [Stayman](#Stayman), or the [BML source](https://github.com/enerqi/bml)."},
	{"comment", "// at the start of a line: the line is left out of the page", "Shown.\n// a note to yourself, not on the page\nAlso shown."},
	// Placeholders as words (`SUIT`, `MAJOR`), not BML's own docs' `\R` / `\M`: a paste's `X=Y` is a plain
	// find-and-replace on the cut rows, so any text found nowhere else will do, and a backslash read as syntax
	// (asked 2026-10-28: "what is \R").
	{"cut and paste", "#CUT name ... #ENDCUT keeps rows to reuse; #PASTE name writes them there. Each WORD=text after it replaces that word in them: SUIT and MAJOR here are made-up placeholders - any word that appears nowhere else.", "#CUT transfer\n2SUIT = transfer\n    2MAJOR = accept\n    3MAJOR = super accept\n#ENDCUT\n\n1N = 15--17\n    2C = Stayman\n    #PASTE transfer SUIT=D MAJOR=H\n    #PASTE transfer SUIT=H MAJOR=S"},
}

// Directives that change the page without being drawn on it: listed under the examples, with no render.
GUIDE_UNDRAWN :: [?]Guide_Example {
	{"title", "the page's title, as the browser tab shows it", "#+TITLE: Our system"},
	{"include", "that file's text, here: a document made of chapters", "#INCLUDE nt-bidding.bml"},
	{"hide", "inside a bid table: it is parsed but not shown", "#HIDE"},
	// The preview's engine is not a browser; what a stylesheet of the author's own runs into is said here, once.
	{"own stylesheet", "your own CSS file(s) in the notes folder, after the notes' stylesheet so its rules win - aim them at class hooks. The preview shows it (it reads the file when the notes change); it ignores width @media rules, a margin on inline text, and a custom property set anywhere but :root, and a side-by-side row cuts off a taller child.", "#+CSS: my-notes.css"},
	// `#VUL` / `#SEAT` are left out (decided 2026-10-28): only the BBO Full Disclosure export reads them, and
	// the notes say seat and vulnerability in the description instead - which the page now tags.
}

// The source WRAPS: a one-line example wider than its column got a scrollbar drawn over the line (reported
// 2026-10-28), and a wrapped line still reads as the text to type. Each example is a TABLE ROW, source cell and
// rendered cell: as a horizontal flow of two divs the row took the rendered side's height in this engine and
// cut the source's wrapped lines off (reported the same day); a table row grows to its tallest cell.
// BOTH CELLS ARE SIZED, each with a max-width (reported 2026-10-31: explanation columns "very thin"). With only the
// source's `width: 42%`, this engine sized the row from the content and the source cell took 950 of 1088px, the
// rendered side wrapping a word a line; `test_the_guide_columns_keep_their_shares` measures it.
// AND NEITHER CAN BE SQUEEZED (reported 2026-11-02, real window, shares or not: the source a word a line at ~85px):
// the notes' sheet gives every bid table `width: 900px` (700/750 in its width @media), a minimum the table
// algorithm must honour, so the rendered cell took the row and the source got what was left. In the guide a bid
// table is as wide as its cell, the source has a floor of its own (a min-width on its text, which is content, so
// any table algorithm keeps it), and the page is not held to the notes' 900px column: a guide is two columns.
GUIDE_CSS :: `<style>
body.content { max-width: 1500px; padding: 0 1.5em; }
td.wb-guide-out div.bidtable { width: auto; max-width: 100%; }
.wb-guide-intro { margin: 0.4em 0 1em 0; }
.wb-guide { margin: 0 0 1.4em 0; }
.wb-guide-head { margin-bottom: 0.3em; }
.wb-guide-head b { font-size: 1.05em; }
.wb-guide-about { color: #6b6b6b; }
table.wb-guide-row { width: 100%; border-collapse: collapse; }
table.wb-guide-row td { vertical-align: top; padding: 0; }
td.wb-guide-src { width: 42%; max-width: 42%; padding-right: 1em; }
td.wb-guide-out { width: 58%; max-width: 58%; }
pre.wb-guide-src { margin: 0; min-width: 16em; padding: 0.4em 0.6em; background: rgba(128,128,128,0.12); font-size: 0.9em; white-space: pre-wrap; }
td.wb-guide-out > :first-child { margin-top: 0; }
</style>`

// The rendered body of one example: the page `render_html` makes of it, without the page around it (the
// head, the `Top` link, the side links). Scratch memory.
@(private = "file")
guide_render :: proc(source: string) -> string {
	doc := bml.parse(source)
	defer bml.destroy(doc)
	html := bml.render_html(doc, context.temp_allocator)
	OPEN :: `<body class="content">`
	start := strings.index(html, OPEN)
	end := strings.index(html, `<a class="top-link"`)
	if start < 0 || end < start {
		return ""
	}
	return html[start + len(OPEN):end]
}

// The guide as a page for the preview frame (which adds the notes' stylesheet, as it does to the notes).
guide_page :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "<html><head>")
	strings.write_string(&b, GUIDE_CSS)
	strings.write_string(&b, `</head><body class="content"><div class="wb-guide-intro"><b>BML, the notes' markup.</b> `)
	strings.write_string(&b, `Each example's text on the left, what the page makes of it on the right. <b>insert</b> writes the example at the caret. `)
	strings.write_string(&b, `A blank line ends a block, so leave one between them. <b>guide</b> again goes back to your notes.</div>`)
	examples := GUIDE_EXAMPLES
	for example, i in examples {
		fmt.sbprintf(
			&b,
			`<div class="wb-guide"><div class="wb-guide-head"><b>%s</b> <span class="wb-guide-about">%s</span> <a href="wbinsert:%d">insert</a></div>`,
			escape_html(example.label, context.temp_allocator),
			escape_html(example.about, context.temp_allocator),
			i,
		)
		fmt.sbprintf(
			&b,
			`<table class="wb-guide-row"><tr><td class="wb-guide-src"><pre class="wb-guide-src">%s</pre></td><td class="wb-guide-out">%s</td></tr></table></div>`,
			escape_html(example.source, context.temp_allocator),
			guide_render(example.source),
		)
	}
	strings.write_string(&b, `<div class="wb-guide"><div class="wb-guide-head"><b>not drawn on the page</b> <span class="wb-guide-about">directives that change it without showing</span></div><ul>`)
	undrawn := GUIDE_UNDRAWN
	for example in undrawn {
		fmt.sbprintf(
			&b,
			`<li><code>%s</code> - %s</li>`,
			escape_html(example.source, context.temp_allocator),
			escape_html(example.about, context.temp_allocator),
		)
	}
	strings.write_string(&b, "</ul></div></body></html>")
	return strings.to_string(b)
}

// `guide` in the preview's head: show the guide, or go back to the notes.
toggle_guide :: proc(app: ^App) {
	app.bml_guide = !app.bml_guide
	app.bml_guide_loaded = false
	app.bml_rendered = 0 // back to the notes: render them again, even if the text did not change
	mark_toggle(app, "#bml-guide", app.bml_guide)
	_, why := preview_bml(app)
	bml_status(app, why)
}

// The guide in the preview frame, once: the live preview calls in after every pause in the typing, and
// reloading would throw away where the guide was scrolled to.
show_guide :: proc(app: ^App) -> (ok: bool, why: string) {
	if !app.bml_guide_loaded {
		if !show_preview_html(app, preview_document(app, guide_page(context.temp_allocator), -1, context.temp_allocator)) {
			return false, "the guide could not be loaded into the frame"
		}
		app.bml_guide_loaded = true
		app.previewed = true
		watch_preview_clicks(app)
	}
	app.bml_showing = true
	set_shown(app, "#bml-preview-pane", true)
	show_preview_button(app)
	return true, "the BML guide · insert writes an example at the caret · guide again for your notes"
}

// An example's `insert` (`GUIDE_INSERT`, posted by the link's click): its source at the caret. On a line
// with text the example goes after it, a blank line between, since a block runs on until a blank line.
guide_insert :: proc(app: ^App) {
	examples := GUIDE_EXAMPLES
	if app.guide_insert < 0 || app.guide_insert >= len(examples) {
		return
	}
	example := examples[app.guide_insert]
	row, col := caret_position(app)
	source, _ := bml_source(app, context.temp_allocator)
	lines := strings.split(source, "\n", context.temp_allocator)
	template := fmt.tprintf("%s$0\n", example.source)
	if row < len(lines) && strings.trim_space(lines[row]) != "" {
		col = len(lines[row])
		template = fmt.tprintf("\n\n%s$0\n", example.source)
	}
	if insert_into_source(app, row, col, 0, template) {
		bml_status(app, fmt.tprintf("inserted %s - %s", example.label, example.about))
		focus_bml_source(app)
	} else {
		bml_status(app, "that could not be written")
	}
}

// The editor gets the focus back after an insert from the guide, so typing goes on where the example went.
@(private = "file")
focus_bml_source :: proc(app: ^App) {
	if element := find(app, "#bml-text"); element != nil {
		_ = sa.set_focus(element)
	}
}
