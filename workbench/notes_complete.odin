package main

/*
	notes_complete.odin — word completion in the notes source, from a LEXICON of bridge terms.

	The terms are `ui/bml-lexicon.txt` (compiled in: the bml Sublime Text syntax's bid-type and convention
	lists, and common terms it lacked), then a notes folder's own `lexicon.txt` beside its .bml files if it has
	one, then - when Settings says so - every word of five letters or more already used in the folder's notes,
	which picks up a system's own vocabulary without anyone curating it, at the price of more noise. Each is
	one term a line, written as it should be written (`RKCB`, `Lebensohl`, `self-sufficient`); `#` starts a
	comment line.

	The host builds the list and hands it to the page script (`bmlSetLexicon`), which does the rest: after
	three letters of a word in a description or prose - never the bid column - it names the first match in the
	status line, TAB writes it, CTRL+SPACE steps through the others, ESC drops it. NO POPUP: a floating element
	froze this window once (the squiggle hover, see the page script), so the suggestion lives where every other
	message does.

	Settings: `off`, `terms` (the default: the lexicon files), `+ folder words`.
*/

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../prefs"
import sa "sciter:sciter_app"

NOTES_COMPLETE_PREF :: "notes.complete"
NOTES_COMPLETE_WORDS :: [?]string{"off", "terms", "folder"}
BML_LEXICON_BUILTIN :: #load("../ui/bml-lexicon.txt", string)
// A folder's own terms, beside its notes.
NOTES_LEXICON_FILE :: "lexicon.txt"
// Folder words shorter than this are mostly words anyone can type faster than read a suggestion for.
FOLDER_WORD_MIN :: 5

notes_complete_mode :: proc(p: ^prefs.Prefs) -> string {
	if word, found := prefs.get(p, NOTES_COMPLETE_PREF); found {
		for known in NOTES_COMPLETE_WORDS {
			if word == known {
				return word
			}
		}
	}
	return "terms"
}

// The terms of one lexicon text: a term a line, blank lines and `#` comments left out.
lexicon_lines :: proc(text: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 128, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		term := strings.trim_space(line)
		if term == "" || strings.has_prefix(term, "#") {
			continue
		}
		append(&out, term)
	}
	return out[:]
}

// The words of five letters or more in a text, as written (letters, and `-` or `'` inside a word).
folder_words :: proc(text: string, into: ^[dynamic]string) {
	start := -1
	for i := 0; i <= len(text); i += 1 {
		c := text[i] if i < len(text) else ' '
		letter := ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
		inner := (c == '-' || c == '\'') && start >= 0
		if letter || inner {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 {
			word := strings.trim_right(text[start:i], "-'")
			if len(word) >= FOLDER_WORD_MIN {
				append(into, word)
			}
			start = -1
		}
	}
}

/*
The completion list for a notes folder under `mode`: the built-in lexicon, the folder's own, and with
`folder` its notes' words - each term once, the first spelling seen winning (case-insensitively), so a
curated `Lebensohl` is not shadowed by a `lebensohl` typed somewhere. Scratch memory.
*/
completion_terms :: proc(docs, mode: string) -> []string {
	if mode == "off" {
		return nil
	}
	all := make([dynamic]string, 0, 512, context.temp_allocator)
	append(&all, ..lexicon_lines(BML_LEXICON_BUILTIN, context.temp_allocator))
	if docs != "" {
		if path, jerr := filepath.join({docs, NOTES_LEXICON_FILE}, context.temp_allocator); jerr == nil {
			if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
				append(&all, ..lexicon_lines(string(data), context.temp_allocator))
			}
		}
		if mode == "folder" {
			words := make([dynamic]string, 0, 4096, context.temp_allocator)
			for name in list_bml_files(docs, context.temp_allocator) {
				path, _ := filepath.join({docs, name}, context.temp_allocator)
				if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
					folder_words(string(data), &words)
				}
			}
			slice.sort(words[:]) // a stable order, whatever order the files came in
			append(&all, ..words[:])
		}
	}
	seen := make(map[string]struct{}, len(all), context.temp_allocator)
	terms := make([dynamic]string, 0, len(all), context.temp_allocator)
	for term in all {
		key := strings.to_lower(term, context.temp_allocator)
		if key in seen {
			continue
		}
		seen[key] = {}
		append(&terms, term)
	}
	return terms[:]
}

// Hand the page script the list for the open folder and the chosen mode. Called on entering the notes view,
// on changing folder, and on changing the setting.
send_lexicon :: proc(app: ^App) {
	terms := completion_terms(app.docs, notes_complete_mode(&app.prefs))
	encoded, err := json.marshal(terms, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	script := strings.concatenate({"bmlSetLexicon(", json_string(string(encoded), context.temp_allocator), ")"}, context.temp_allocator)
	result, _ := sa.eval(app.window, script)
	sa.value_clear(&result)
}

// The Settings row.
choose_notes_complete :: proc(app: ^App, word: string) {
	if app.prefs.values != nil {
		prefs.set(&app.prefs, NOTES_COMPLETE_PREF, word)
		if app.prefs_path != "" {
			_ = prefs.save(&app.prefs, app.prefs_path)
		}
	}
	draw_notes_complete_prefs(app)
	send_lexicon(app)
}

draw_notes_complete_prefs :: proc(app: ^App) {
	chosen := notes_complete_mode(&app.prefs)
	for word in NOTES_COMPLETE_WORDS {
		selector := strings.concatenate({`#prefs-panel [data-notes-complete="`, word, `"]`}, context.temp_allocator)
		if button := find(app, selector); button != nil {
			sa.set_attribute(button, "class", "segbtn on" if word == chosen else "segbtn")
		}
	}
}
