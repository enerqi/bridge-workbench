package main

/*
	notes_insert.odin — the heading palette's two WRITING modes: it was a way to go somewhere, and the same
	list is what a cross-reference needs, so it also writes.

	LINK (CTRL+L, or typing `](#`): pick a heading, and the link to it is written at the caret - `[name](#name)`
	from the key, the rest of `](#name)` when it was typed. 920 links in the corpus, every one an anchor that
	has to match its heading's text exactly, and a typo is a dead link nobody sees until it is clicked (the
	`links` check finds them afterwards; this stops them being typed). A heading in ANOTHER document - another
	`#INCLUDE` tree, so another page - is written `[name](other.html#id)`, the form the notes already use for
	`alternatives.html#...`, since `#name` only lands inside one page.

	INSERT (CTRL+I): the same palette listing BML's constructs instead of headings - the directives nobody
	remembers (`#CUT` / `#PASTE` with replacements, `#VUL`, `#SEAT`, `#HIDE`), competitive headers, lists, font
	styles. Each is a template written at the caret, with the caret left where you type next (`$0`).

	Both write through `bmlInsertAt` in the page script: ONE `plaintext.update`, so one ctrl+z.
*/

import "core:fmt"
import "core:strings"

import "../outline"
import bml "markup:."
import sa "sciter:sciter_app"

Goto_Mode :: enum {
	Jump,
	Link,
	Insert,
}

// One construct of the insert palette. `template` marks where the caret goes with `$0` (the end if absent).
Bml_Snippet :: struct {
	label, about, template: string,
}

BML_SNIPPETS :: [?]Bml_Snippet {
	{"heading", "* top-level heading", "* $0"},
	{"heading 2", "** a section under it", "** $0"},
	{"heading 3", "*** a subsection", "*** $0"},
	{"competitive table", "their opening: (1N)--- then our calls", "($0)---\n"},
	{"balancing table", "their opening passed round: (1N)-P-(P)---", "($0)-P-(P)---\n"},
	{"cut a reusable block", "#CUT name ... #ENDCUT: rows kept for #PASTE, not shown here", "#CUT $0name\n\n#ENDCUT"},
	{"copy a reusable block", "#COPY name ... #ENDCOPY: shown here and kept for #PASTE", "#COPY $0name\n\n#ENDCOPY"},
	{"paste a block", "#PASTE name, replacing text: \\R=D \\M=H", "#PASTE $0name \\R=D \\M=H"},
	{"vulnerability", "#VUL we/them, each Y, N or 0: for the tables after it", "#VUL $0Y0"},
	{"seat", "#SEAT 1, 2, 3, 4, 12 or 34: for the tables after it", "#SEAT $034"},
	{"hide a table", "#HIDE: the table is parsed but not shown on the page", "#HIDE"},
	{"include a file", "#INCLUDE chapter.bml: its text, here", "#INCLUDE $0"},
	{"title", "#+TITLE: the page's title", "#+TITLE: $0"},
	// The four blocks rendered since 2026-10-26 (bml2html / bridge-markup). Each is a block of its own: a blank
	// line above and below, or it joins the text around it.
	{"deal diagram", "a header (board, dealer, vul, contract, lead), then hands: spades hearts diamonds clubs, - for a void", "#1, Dealer N, None vul$0\nN: AKxx Qxx Kxx Axx\nS: Qxx AKxx Axx Kxx"},
	{"auction", "rows of four calls; P D R AP are pass, double, redouble, all pass", "1H P 1S P\n$0"},
	{"table", "| cells |, with a |---+---| line under the header row", "| $0 | |\n|---+---|\n| | |"},
	{"description list", "- term :: what it means", "- $0 :: "},
	{"bullet list", "- one item a line", "- $0"},
	{"numbered list", "1. one item a line", "1. $0\n2. "},
	{"italic", "/text/", "/$0/"},
	{"bold", "*text* (not at the start of a line: that is a heading)", "*$0*"},
	{"monospace", "=text=", "=$0="},
	{"comment", "// a line the page leaves out", "// $0"},
}

// The palette's rows for INSERT: each snippet as a heading-shaped row, so the same ranking and list serve it -
// `text` is the label that is matched, `file` the note shown on the right, `row` its index here.
snippet_rows :: proc(allocator := context.allocator) -> []outline.Heading {
	snippets := BML_SNIPPETS
	rows := make([dynamic]outline.Heading, 0, len(snippets), context.temp_allocator)
	for snippet, i in snippets {
		append(&rows, outline.Heading{file = snippet.about, text = snippet.label, level = 1, row = i, order = i})
	}
	return outline.clone_headings(rows[:], allocator)
}

/*
The link to `target` as written from a file `open` in the notes folder `docs`: `#name` inside the same document
(the same `#INCLUDE` tree, so the same page), `other.html#id` across documents. `typed` is the `](#` the
writer already typed: then only the rest is returned, and `drop` says how many characters before the caret
(the `#`) the cross-document form replaces.
*/
link_text :: proc(docs, open: string, target: outline.Heading, typed: bool) -> (text: string, drop: int) {
	names := list_bml_files(docs, context.temp_allocator)
	here, _ := notes_root_of(docs, names, open)
	there, _ := notes_root_of(docs, names, target.file)
	anchor := fmt.tprintf("#%s", target.text)
	if !strings.equal_fold(here, there) {
		anchor = fmt.tprintf(
			"%s.html#%s",
			strings.trim_suffix(there, ".bml"),
			bml.normalise_header_id(target.text, context.temp_allocator),
		)
	}
	if typed {
		// `](#` is already there: the `#` goes when the target is another page's.
		return fmt.tprintf("%s)", anchor[1:] if anchor[0] == '#' else anchor), 0 if anchor[0] == '#' else 1
	}
	return fmt.tprintf("[%s](%s)", target.text, anchor), 0
}

// The caret as [row, column] - `selectionStart`, which the plaintext publishes as an array.
caret_position :: proc(app: ^App) -> (row, col: int) {
	element := find(app, "#bml-text")
	if element == nil {
		return
	}
	asset, aerr := sa.element_asset(element, "plaintext")
	if aerr != nil {
		return
	}
	value, gerr := sa.asset_get(asset, "selectionStart")
	if gerr != nil {
		return
	}
	defer sa.value_clear(&value)
	at :: proc(value: ^sa.Value, i: int) -> int {
		item, err := sa.value_at(value, i)
		if err != nil {
			return 0
		}
		defer sa.value_clear(&item)
		n, ierr := sa.value_to_int(&item)
		return int(n) if ierr == nil else 0
	}
	return at(&value, 0), at(&value, 1)
}

// Write `text` at [row, col] of the source, `drop` characters before it removed first, and leave the caret
// at its `$0` (or its end). Lines after the first take the indent of the line written into, so a block lands
// at the level it was asked for. One undo step. False when the page script could not do it.
insert_into_source :: proc(app: ^App, row, col, drop: int, template: string) -> bool {
	source, _ := bml_source(app, context.temp_allocator)
	lines := strings.split(source, "\n", context.temp_allocator)
	indent := 0
	if row < len(lines) {
		line := lines[row]
		for indent < len(line) && line[indent] == ' ' {
			indent += 1
		}
	}
	text, _ := strings.replace_all(template, "\n", fmt.tprintf("\n%s", strings.repeat(" ", indent, context.temp_allocator)), context.temp_allocator)
	before, after := text, ""
	if at := strings.index(text, "$0"); at >= 0 {
		before, after = text[:at], text[at + 2:]
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "bmlInsertAt(%d, %d, %d, ", row, col, drop)
	write_json_string(&b, before)
	strings.write_string(&b, ", ")
	write_json_string(&b, after)
	strings.write_byte(&b, ')')
	result, err := sa.eval(app.window, strings.to_string(b))
	defer sa.value_clear(&result)
	done, _ := sa.value_to_bool(&result)
	return err == nil && done
}

// ENTER (or a click) in a writing mode: the link, or the construct, at the caret the palette was opened from.
write_from_palette :: proc(app: ^App, target: outline.Heading) {
	row, col := app.goto_at[0], app.goto_at[1]
	mode, typed := app.goto_mode, app.goto_typed
	// The target's strings are the palette index's; copied before the close, which hands the focus back to the
	// source and can run handlers of its own.
	target := target
	target.file = strings.clone(target.file, context.temp_allocator)
	target.text = strings.clone(target.text, context.temp_allocator)
	close_goto(app)
	switch mode {
	case .Jump:
	case .Link:
		text, drop := link_text(app.docs, app.bml_open, target, typed)
		if insert_into_source(app, row, col, drop, text) {
			bml_status(app, fmt.tprintf("linked to %s (%s)", target.text, target.file))
		} else {
			bml_status(app, "the link could not be written")
		}
	case .Insert:
		snippets := BML_SNIPPETS
		if target.row < 0 || target.row >= len(snippets) {
			return
		}
		snippet := snippets[target.row]
		if insert_into_source(app, row, col, 0, snippet.template) {
			bml_status(app, fmt.tprintf("%s - %s", snippet.label, snippet.about))
		} else {
			bml_status(app, "that could not be written")
		}
	}
}
