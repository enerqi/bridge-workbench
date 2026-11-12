package main

/*
	look_preview.odin — THE LOOK PREVIEW in Settings: the notes page, the notes editor and the hand page, shown beside
	the settings that change them, so a look is chosen by seeing it (asked 2026-10-31). Settings is a split: the
	settings on the left, this pane on the right, one of the three at a time under its tab.

	WHAT EACH TAB SHOWS:
	  * notes page - a SAMPLE (`ui/look-sample.bml`, built in): one of everything a notes look colours - headings to
	    ****, a bid table three deep, their calls, seat and vulnerability tags, a table, an auction, a diagram, each
	    kind of box. The open notes would show only what they happen to hold, and a large file costs hundreds of MB
	    rendered (preview/preview.odin), which a second frame would pay again.
	  * editor - the same sample's SOURCE, read-only, in a second `<plaintext>` that the page script colours and
	    styles as it does the notes editor (`wbEditorLook` sets both).
	  * hand page - the page in the hand pane when there is one, so the look is judged on your own deals; else a
	    built-in sample deal, rendered here by norn as a generated page is (no double-dummy: nothing to wait for).

	THE TAB FOLLOWS WHAT CHANGED: a notes look choice shows the notes page, an editor row the editor, a felt or a card
	the hand page (`look_changed`). The suits are both looks', so they show the notes unless the hand page is up.

	THE HAND PAGE IS RELOADED on each change, as the hand pane's is (`hand_look.odin`: a style added to a loaded page
	applies nothing in this engine); the notes page is rendered again, which costs a parse of the sample; the editor
	needs nothing - its look is variables on the element.
*/

import "core:os"
import "core:path/filepath"
import "core:strings"

import bml "markup:."
import "norn:norn"
import sa "sciter:sciter_app"

Look_Tab :: enum {
	Notes,
	Editor,
	Hand,
}

LOOK_TAB_WORDS := [Look_Tab]string {
	.Notes  = "notes",
	.Editor = "editor",
	.Hand   = "hand",
}

LOOK_SAMPLE_BML :: #load("../ui/look-sample.bml", string)

// The sample deal: a void, a ten in every hand but one, long suits and short ones, so each part of a card the look
// colours is on show.
LOOK_SAMPLE_DEAL :: "N:AKT74.QJ3.K92.A6 Q85.T9862..KJ943 J6.AK5.QJ8763.Q2 932.74.AT54.T875"

look_tab_of :: proc(word: string) -> (tab: Look_Tab, ok: bool) {
	for candidate in Look_Tab {
		if LOOK_TAB_WORDS[candidate] == word {
			return candidate, true
		}
	}
	return .Notes, false
}

// Show `tab` in the preview pane, rendered with the look as it is now. Does nothing outside Settings.
show_look_tab :: proc(app: ^App, tab: Look_Tab) {
	app.look_tab = tab
	if current_view(app) != .Prefs {
		return
	}
	set_shown(app, "#look-notes", tab == .Notes)
	set_shown(app, "#look-text", tab == .Editor)
	set_shown(app, "#look-hand", tab == .Hand)
	for candidate in Look_Tab {
		selector := strings.concatenate({`#prefs-look-tabs [data-look-tab="`, LOOK_TAB_WORDS[candidate], `"]`}, context.temp_allocator)
		if button := find(app, selector); button != nil {
			sa.set_attribute(button, "class", "segbtn on" if candidate == tab else "segbtn")
		}
	}
	note := ""
	switch tab {
	case .Notes:
		note = show_look_notes(app)
	case .Editor:
		note = show_look_text(app)
	case .Hand:
		note = show_look_hand(app)
	}
	set_text_at(app, "#prefs-look-note", note)
}

// A look changed: show the tab it is the look of. The suits (`tab` nil) belong to both, so they keep the hand
// page when it is up and show the notes otherwise.
look_changed :: proc(app: ^App, tab: Maybe(Look_Tab)) {
	if current_view(app) != .Prefs {
		return
	}
	chosen, given := tab.?
	if !given {
		chosen = .Hand if app.look_tab == .Hand else .Notes
	}
	show_look_tab(app, chosen)
}

@(private = "file")
show_look_notes :: proc(app: ^App) -> string {
	doc := bml.parse(LOOK_SAMPLE_BML, {resolve_include = bml_include, include_user = app})
	defer bml.destroy(doc)
	page := preview_document(app, bml.render_html(doc, context.temp_allocator), -1, context.temp_allocator)
	if !load_frame_html(app, "#look-notes", page, "file://workbench/look-notes.html") {
		return "the sample notes could not be shown"
	}
	return "sample notes"
}

// The sample's source in the read-only editor, coloured. Written once: the text never changes, and the look is the
// element's variables, which `wbEditorLook` keeps current.
@(private = "file")
show_look_text :: proc(app: ^App) -> string {
	element := find(app, "#look-text")
	if element == nil {
		return ""
	}
	if !app.look_text_loaded {
		if asset, err := sa.element_asset(element, "plaintext"); err == nil {
			value := sa.value_from(LOOK_SAMPLE_BML)
			defer sa.value_clear(&value)
			if sa.asset_set(asset, "content", &value) != nil {
				sa.set_text(element, LOOK_SAMPLE_BML)
			}
		}
		app.look_text_loaded = true
	}
	result, _ := sa.eval(app.window, "wbLookTextColorize()")
	sa.value_clear(&result)
	apply_editor_look(app)
	return "sample notes, read-only"
}

@(private = "file")
show_look_hand :: proc(app: ^App) -> string {
	page, base, about := "", "file://workbench/look-hand.html", "a sample deal - with a hand page open, it is shown here instead"
	switch {
	case app.showing_analysed && app.analysed_page != "":
		page, about = app.analysed_page, "the analysed page in the hand pane"
	case app.showing_lead && app.lead_row >= 0 && shown_lead_html(app) != "":
		page, about = shown_lead_html(app), "the lead problem's layouts in the hand pane"
	case app.shown_path != "" && strings.has_suffix(strings.to_lower(app.shown_path, context.temp_allocator), ".html"):
		if data, err := os.read_entire_file(app.shown_path, context.temp_allocator); err == nil {
			url, _ := strings.replace_all(app.shown_path, `\`, "/", context.temp_allocator)
			page = string(data)
			base = strings.concatenate({"file:///", strings.trim_left(url, "/")}, context.temp_allocator)
			about = strings.concatenate({"the page in the hand pane: ", filepath.base(app.shown_path)}, context.temp_allocator)
		}
	}
	if page == "" {
		page = look_sample_page(context.temp_allocator)
	}
	if !load_frame_html(app, "#look-hand", with_hand_look(app, page, context.temp_allocator), base) {
		return "the hand page could not be shown"
	}
	return about
}

// The sample deal as a card page, as a generated one is written: North deals, North-South vulnerable.
look_sample_page :: proc(allocator := context.allocator) -> string {
	board, err := norn.parse_pbn_deal(LOOK_SAMPLE_DEAL)
	if err != .None {
		return ""
	}
	b := strings.builder_make(allocator)
	norn.render_page_prologue(&b, .Html_Cards, "Sample deal")
	norn.render_deal_html_cards_at(&b, board.deal, {vulnerability = .North_South, dealer = .North})
	norn.render_page_epilogue(&b, .Html_Cards)
	return strings.to_string(b)
}

@(private = "file")
load_frame_html :: proc(app: ^App, selector, html, base_url: string) -> bool {
	element := find(app, selector)
	if element == nil {
		return false
	}
	asset, aerr := sa.element_asset(element, "frame")
	if aerr != nil {
		return false
	}
	html_value := sa.value_from(html)
	defer sa.value_clear(&html_value)
	base := sa.value_from(base_url)
	defer sa.value_clear(&base)
	result, err := sa.asset_call(asset, "loadHtml", {html_value, base})
	defer sa.value_clear(&result)
	return err == nil && !sa.value_is_error(&result)
}
