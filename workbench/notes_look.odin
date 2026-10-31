package main

/*
	notes_look.odin — how the NOTES look: page colours, suit colours and font, picked in Settings.

	A LOOK IS A SECOND `:root` BLOCK. `bml.css` names every colour and its font once, as `--bml-*` tokens on
	`:root` (the bml repo's stylesheet; its values are the original look), so a look is a small block placed
	AFTER that sheet which redefines some of them. No rule is rewritten, nothing in the html changes, and a
	stylesheet without the tokens (an older `bml.css`) simply ignores the block and keeps its own look.

	THREE CHOICES, EACH A FEW PRESETS, because the person choosing is not writing CSS:

	  * page  - classic (antique white, the original), white, dark;
	  * suits - four-colour (the original: green clubs, orange diamonds), two-colour (red and black, as most
	            players learned), colour-blind safe (Okabe-Ito blue / orange / vermillion: the original's green
	            clubs against red hearts is exactly the red-green pair a colour-blind reader cannot tell apart);
	  * font  - Open Sans (the original), the system's, serif, and three more stacks Windows has - Calibri,
	            Cambria, Verdana - each falling back to a metric twin (Carlito, Caladea) or a cousin elsewhere, as
	            a built page is read on other machines;
	  * bid cells - the shape of a bid's tinted cell: square (the original), rounded, a fade into the
	            description, or a bar down its left edge instead of a fill.

	Spades (and two-colour clubs) are the page's INK rather than black, so they stay readable on the dark page.

	FINE TUNING, FOR WHOEVER WANTS MORE: one row per token (`NOTES_TUNES`) - the page, the suits, each callout
	type, the condition tag, the vulnerable seat, the table lines, the text size - each a `#rrggbb` colour (or a
	percentage) that, when set, wins over the presets. Empty is "as the look above", and the row's reset and
	`reset all` put it back, so the presets stay one click away. A colour that a token needs translucent (a bid
	column, a table's lines) or that has a tint beside it (a callout's background) is written as `rgba` from the
	same red, green and blue: the preview engine has no `color-mix` to make the tint from the colour itself.

	WHERE IT APPLIES: the notes preview and the quiz page's notes panel, which inline the stylesheet and append
	this. And, when Settings says so, the pages BUILT from the notes: those link `bml.css` itself, so the block
	is written to `bml-look.css` in the notes folder and the `bml` recipe appends it to the `bml.css` it copies
	there. The html never changes - only the stylesheet beside it. The file's EXISTENCE is the setting (the
	read-from-the-document rule, here the folder): no pref to disagree with it.
*/

import "core:fmt"
import "core:os"
import "core:slice"
import "core:path/filepath"
import "core:strings"

import "../prefs"
import sa "sciter:sciter_app"

NOTES_PAGE_PREF :: "notes.page"
NOTES_SUITS_PREF :: "notes.suits" // read only when `suits` is absent (hand_look.odin: the suits are shared now)
NOTES_FONT_PREF :: "notes.font"
NOTES_BIDS_PREF :: "notes.bids"

// The words, in the order Settings shows them. The first of each is the original look.
NOTES_PAGES :: [?]string{"classic", "white", "dark"}
NOTES_SUITS :: [?]string{"four-colour", "two-colour", "colour-blind"}
NOTES_FONTS :: [?]string{"open-sans", "system", "serif", "calibri", "cambria", "verdana"}
NOTES_BIDS :: [?]string{"square", "rounded", "fade", "bar"}

Notes_Look :: struct {
	page:  string,
	suits: string,
	font:  string,
	bids:  string,
	// Per `NOTES_TUNES` row, the value set in fine tuning (already checked by `tune_value`); "" for none.
	tuned: [len(NOTES_TUNES)]string,
}

// The prefs key of a fine-tuning row: `notes.tune.<token>`.
NOTES_TUNE_PREF_PREFIX :: "notes.tune."

// One fine-tuning row: the `--bml-<token>` it sets and how its value is written.
Notes_Tune :: struct {
	token:      string,
	label:      string,
	// "" writes the colour as given; else as `rgba(r, g, b, alpha)` - the token is a translucent one.
	alpha:      string,
	// A second token written from the same colour at `tint_alpha`: a callout's background.
	tint:       string,
	tint_alpha: string,
	// A whole NUMBER, not a colour: a size in percent unless `unit` says otherwise.
	percent:     bool,
	// A number's unit (`%` when empty) and its range (50 to 200 when both are 0).
	unit:        string,
	low, high:   int,
	// What an empty number field shows, and the hint on it.
	placeholder: string,
	hint:        string,
	// A font list (`Georgia, serif`), not a colour.
	font:        bool,
	// The row's group in Settings (`NOTES_TUNE_GROUPS`): rows of a group share a line.
	group:       int,
	// The token an empty EDITOR row falls back to, `--<base>`; `--syn-<token>` when empty (`editor_look.odin`).
	base:        string,
}

// A number row's unit, `%` unless it names one.
tune_unit :: proc(tune: Notes_Tune) -> string {
	return tune.unit if tune.unit != "" else "%"
}

// A number row's range, 50 to 200 unless it names one.
tune_range :: proc(tune: Notes_Tune) -> (low, high: int) {
	if tune.low == 0 && tune.high == 0 {
		return 50, 200
	}
	return tune.low, tune.high
}

// The groups the rows are shown in, in order.
NOTES_TUNE_GROUPS :: [?]string{"page", "suits", "boxes", "tags, tables", "fonts"}

// In the order Settings shows them; every token is one `bml.css` declares on `:root`.
NOTES_TUNES :: [?]Notes_Tune {
	{token = "page-bg", label = "page"},
	{token = "ink", label = "text"},
	{token = "link", label = "links"},

	{token = "bid-col", label = "bid column", alpha = "0.4", tint = "bid-bar", tint_alpha = "1"},
	{token = "bid-col-alt", label = "next bid column", alpha = "0.4", tint = "bid-bar-alt", tint_alpha = "1"},
	{group = 1, token = "club", label = "clubs"},
	{group = 1, token = "diamond", label = "diamonds"},
	{group = 1, token = "heart", label = "hearts"},
	{group = 1, token = "spade", label = "spades"},
	{group = 2, token = "note", label = "note box", tint = "note-tint", tint_alpha = "0.09"},
	{group = 2, token = "info", label = "info box", tint = "info-tint", tint_alpha = "0.09"},
	{group = 2, token = "tip", label = "tip box", tint = "tip-tint", tint_alpha = "0.09"},
	{group = 2, token = "warning", label = "warning box", tint = "warning-tint", tint_alpha = "0.11"},
	{group = 2, token = "callout", label = "titled box", tint = "callout-tint", tint_alpha = "0.08"},
	{group = 3, token = "cond", label = "seat / vul tag", alpha = "0.18"},
	{group = 3, token = "vul", label = "vulnerable seat"},
	{group = 3, token = "vul-ink", label = "its letter"},
	{group = 3, token = "table-line", label = "table lines", alpha = "0.45"},
	{group = 3, token = "table-head", label = "table header", alpha = "0.16"},
	{group = 3, token = "table-stripe", label = "table stripe", alpha = "0.07"},
	{group = 4, token = "font", label = "text font", font = true},
	{group = 4, token = "heading-font", label = "heading font", font = true},
	{
		group = 4,
		token = "font-size",
		label = "text size",
		percent = true,
		placeholder = "100%",
		hint = "The text size, as a percentage of the look's (50 to 200); empty keeps it.",
	},
}

/*
A fine-tuning value as it is remembered: `#rrggbb` (a `#rgb` is widened, the hex lower-cased) for a colour, a
whole number in the row's range for a number (its unit after it is allowed), a font list for a font - names, commas,
spaces, quotes and dashes only. `ok` false for anything else, which is then not remembered - the row is a CSS
value written into a stylesheet, and a `;` or a `}` in it would break the rules after it.
*/
tune_value :: proc(tune: Notes_Tune, typed: string, allocator := context.allocator) -> (value: string, ok: bool) {
	text := strings.trim_space(typed)
	if tune.font {
		if text == "" || len(text) > 160 {
			return "", false
		}
		letters := false
		for ch in transmute([]u8)text {
			switch ch {
			case 'a' ..= 'z', 'A' ..= 'Z':
				letters = true
			case '0' ..= '9', ' ', ',', '\'', '"', '-':
			case:
				return "", false
			}
		}
		return strings.clone(text, allocator) if letters else "", letters
	}
	if tune.percent {
		text = strings.trim_space(strings.trim_suffix(text, tune_unit(tune)))
		if text == "" || len(text) > 3 {
			return "", false
		}
		n := 0
		for ch in transmute([]u8)text {
			if ch < '0' || ch > '9' {
				return "", false
			}
			n = n * 10 + int(ch - '0')
		}
		if low, high := tune_range(tune); n < low || n > high {
			return "", false
		}
		return strings.clone(text, allocator), true
	}
	if !strings.has_prefix(text, "#") || (len(text) != 4 && len(text) != 7) {
		return "", false
	}
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '#')
	for ch in transmute([]u8)(text[1:]) {
		lower := ch | 0x20
		if !((ch >= '0' && ch <= '9') || (lower >= 'a' && lower <= 'f')) {
			strings.builder_destroy(&b)
			return "", false
		}
		digit := ch if ch <= '9' else lower
		strings.write_byte(&b, digit)
		if len(text) == 4 {
			strings.write_byte(&b, digit) // #abc is #aabbcc
		}
	}
	return strings.to_string(b), true
}

// `#rrggbb` as `rgba(r, g, b, alpha)`.
rgba_of :: proc(hex, alpha: string, allocator := context.allocator) -> string {
	channel :: proc(pair: string) -> int {
		value := 0
		for ch in transmute([]u8)pair {
			value = value * 16 + (int(ch - '0') if ch <= '9' else int(ch - 'a') + 10)
		}
		return value
	}
	return fmt.aprintf("rgba(%d, %d, %d, %s)", channel(hex[1:3]), channel(hex[3:5]), channel(hex[5:7]), alpha, allocator = allocator)
}

// The remembered look; a missing or unknown word is the original.
notes_look :: proc(p: ^prefs.Prefs) -> Notes_Look {
	pick :: proc(p: ^prefs.Prefs, key: string, words: []string) -> string {
		if word, found := prefs.get(p, key); found {
			for known in words {
				if word == known {
					return known
				}
			}
		}
		return words[0]
	}
	pages, fonts := NOTES_PAGES, NOTES_FONTS
	bids := NOTES_BIDS
	look := Notes_Look {
		page  = pick(p, NOTES_PAGE_PREF, pages[:]),
		suits = chosen_suits(p),
		font  = pick(p, NOTES_FONT_PREF, fonts[:]),
		bids  = pick(p, NOTES_BIDS_PREF, bids[:]),
	}
	// A remembered value that does not check out (an edited prefs file) is as good as none.
	for tune, index in NOTES_TUNES {
		if text, found := prefs.get(p, tune_pref(tune)); found && text != "" {
			look.tuned[index], _ = tune_value(tune, text, context.temp_allocator)
		}
	}
	return look
}

@(private = "file")
tune_pref :: proc(tune: Notes_Tune) -> string {
	return strings.concatenate({NOTES_TUNE_PREF_PREFIX, tune.token}, context.temp_allocator)
}

// The `:root` block as a complete `<style>` element, for a page that inlines its stylesheet.
notes_look_css :: proc(look: Notes_Look, allocator := context.allocator) -> string {
	return strings.concatenate({"<style>", notes_look_rules(look, context.temp_allocator), "</style>"}, allocator)
}

/*
The `:root` block for a look, as CSS. CONCATENATED, not formatted: `fmt` reads a brace as a directive (see
`preview_override_css`).
*/
notes_look_rules :: proc(look: Notes_Look, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, ":root {")
	token :: proc(b: ^strings.Builder, name, value: string) {
		strings.write_string(b, " --bml-")
		strings.write_string(b, name)
		strings.write_string(b, ": ")
		strings.write_string(b, value)
		strings.write_string(b, ";")
	}

	switch look.page {
	case "white":
		token(&b, "page-bg", "white")
		token(&b, "ink", "#1a1a1a")
		token(&b, "bid-col", "rgb(165, 252, 247, 0.3)")
		token(&b, "bid-col-alt", "rgb(135, 206, 250, 0.3)")
		token(&b, "link", "rgb(0, 102, 204)")
	case "dark":
		token(&b, "page-bg", "#1e1f26")
		token(&b, "ink", "#e4e4e8")
		token(&b, "bid-col", "rgb(70, 140, 150, 0.35)")
		token(&b, "bid-col-alt", "rgb(80, 120, 170, 0.35)")
		token(&b, "bid-bar", "rgb(80, 165, 175)")
		token(&b, "bid-bar-alt", "rgb(95, 140, 205)")
		token(&b, "link", "#7cb8ff")
		strings.write_string(&b, " --nav-link-color: #e0a070;")
	case:
		token(&b, "page-bg", "antiquewhite")
		token(&b, "ink", "black")
		token(&b, "bid-col", "rgb(165, 252, 247, 0.4)")
		token(&b, "bid-col-alt", "rgb(135, 206, 250, 0.4)")
		token(&b, "link", "rgb(0, 102, 204)")
	}

	// The red on the dark page is lifted, or it sinks into the background.
	red := "#ff6b6b" if look.page == "dark" else "Red"
	switch look.suits {
	case "two-colour":
		token(&b, "club", "var(--bml-ink)")
		token(&b, "diamond", red)
		token(&b, "heart", red)
	case "colour-blind":
		token(&b, "club", "#56b4e9" if look.page == "dark" else "#0072b2")
		token(&b, "diamond", "#e69f00")
		token(&b, "heart", "#ff7a3d" if look.page == "dark" else "#d55e00")
	case:
		token(&b, "club", "MediumSeaGreen")
		token(&b, "diamond", "Orange")
		token(&b, "heart", red)
	}
	token(&b, "spade", "var(--bml-ink)")

	switch look.font {
	case "system":
		token(&b, "font", "'Segoe UI', system-ui, sans-serif")
	case "serif":
		token(&b, "font", "Georgia, 'Times New Roman', serif")
	case "calibri":
		token(&b, "font", "Calibri, Carlito, 'Segoe UI', sans-serif")
	case "cambria":
		token(&b, "font", "Cambria, Caladea, Georgia, serif")
	case "verdana":
		token(&b, "font", "Verdana, Geneva, 'DejaVu Sans', sans-serif")
	case:
		token(&b, "font", "'Open Sans', 'Segoe UI', sans-serif")
	}

	// The bid cells' shape: the original (square) writes nothing - the sheet's own tokens are that look.
	switch look.bids {
	case "rounded":
		token(&b, "bid-radius", "6px")
	case "fade":
		// The tint fading out into the description; a little rounding where it starts.
		token(&b, "bid-paint", "linear-gradient(to right, var(--bml-bid-col), transparent)")
		token(&b, "bid-paint-alt", "linear-gradient(to right, var(--bml-bid-col-alt), transparent)")
		token(&b, "bid-radius", "4px 0 0 4px")
	case "bar":
		// No fill, a bar down the left edge: an INSET shadow, so the cell keeps its width and the column its place.
		// In the bar colours, the tints' solid versions: the tint itself is 40%, a ghost as a 4px bar, and the
		// engine draws only the first of several shadows, so stacking it does not darken it (measured).
		token(&b, "bid-paint", "transparent")
		token(&b, "bid-paint-alt", "transparent")
		token(&b, "bid-shadow", "inset 4px 0 0 var(--bml-bid-bar)")
		token(&b, "bid-shadow-alt", "inset 4px 0 0 var(--bml-bid-bar-alt)")
	}

	// Fine tuning last: a later declaration of the same token wins.
	for tune, index in NOTES_TUNES {
		value := look.tuned[index]
		switch {
		case value == "":
		case tune.percent:
			token(&b, tune.token, strings.concatenate({value, "%"}, context.temp_allocator))
		case tune.alpha != "":
			token(&b, tune.token, rgba_of(value, tune.alpha, context.temp_allocator))
		case:
			token(&b, tune.token, value)
		}
		if value != "" && tune.tint != "" {
			token(&b, tune.tint, rgba_of(value, tune.tint_alpha, context.temp_allocator))
		}
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// ---- profiles: a whole look under a name ---------------------------------------------------------------

/*
A PROFILE is the whole notes look - page, suits, font, bid cells and every fine-tuning row - saved under a name
of the person's choosing, to come back to: `notes.profile.<name>` in the prefs, its value the look's prefs as
`key=value;key=value`. Neither `;` nor `=` can be in a value: the presets are fixed words and every tuning value
has been through `tune_value`, which refuses both. The suits are shared with the hand page, so loading a profile
changes its suits too.
*/
NOTES_PROFILE_PREF_PREFIX :: "notes.profile."
// A DELETED profile, kept until the trash is emptied: delete is one click because it can be undone (↺).
NOTES_PROFILE_TRASH_PREFIX :: "notes.profile-trash."

// The current look as a profile's value. Read through `notes_look`, so it holds checked values only, and two
// equal looks give the same text - which is how Settings knows which profile is the one in use.
notes_look_snapshot :: proc(p: ^prefs.Prefs, allocator := context.allocator) -> string {
	look := notes_look(p)
	b := strings.builder_make(allocator)
	write :: proc(b: ^strings.Builder, key, value: string) {
		if strings.builder_len(b^) > 0 {
			strings.write_byte(b, ';')
		}
		strings.write_string(b, key)
		strings.write_byte(b, '=')
		strings.write_string(b, value)
	}
	write(&b, NOTES_PAGE_PREF, look.page)
	write(&b, SUITS_PREF, look.suits)
	write(&b, NOTES_FONT_PREF, look.font)
	write(&b, NOTES_BIDS_PREF, look.bids)
	for tune, index in NOTES_TUNES {
		if look.tuned[index] != "" {
			write(&b, tune_pref(tune), look.tuned[index])
		}
	}
	return strings.to_string(b)
}

// The saved profiles' names, sorted. Scratch memory.
notes_profile_names :: proc(p: ^prefs.Prefs, prefix := NOTES_PROFILE_PREF_PREFIX) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for key, value in p.values {
		if strings.has_prefix(key, prefix) && value != "" {
			append(&names, key[len(prefix):])
		}
	}
	slice.sort(names[:])
	return names[:]
}

// A name a profile can have: 1 to 40 letters, digits, spaces, `-`, `_` or `.`, trimmed. "" when it is not one.
notes_profile_name :: proc(typed: string) -> string {
	name := strings.trim_space(typed)
	if name == "" || len(name) > 40 {
		return ""
	}
	for ch in transmute([]u8)name {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', ' ', '-', '_', '.':
		case:
			return ""
		}
	}
	return name
}

/*
THE SECOND CLICK. Each profile action that loses a look - replacing a saved one, deleting one, loading over a look
that is saved nowhere - is refused the first time with a word on what it would lose, and done when the same
action is asked for again straight after; any other action in between starts over. The notes editor's guard for
unsaved text, for the same reason: no dialog, and nothing goes by a stray click. True when `action` may go ahead.
*/
profile_guard :: proc(app: ^App, action: string) -> bool {
	armed := string(app.profile_armed[:app.profile_armed_len])
	if armed == action {
		app.profile_armed_len = 0
		return true
	}
	app.profile_armed_len = copy(app.profile_armed[:], action)
	return false
}

// Nothing waiting for a second click: any profile action that needed none clears the guard.
@(private = "file")
profile_unarm :: proc(app: ^App) {
	app.profile_armed_len = 0
}

/*
A SET OF PROFILES: the notes look's, and the notes editor's (`editor_look.odin`), each with its own prefs prefix,
its own line in Settings and its own way to make a saved look the current one. The data attributes on its buttons
are `data-<word>-profile-load` and so on, and its second-click guard actions start with its word, so a click in
one set never confirms an action armed in the other.
*/
Profile_Set :: struct {
	word:         string,
	prefix:       string,
	trash_prefix: string,
	// Selectors: the line of profiles, the deleted ones and the line they are on.
	list:         string,
	trash:        string,
	trash_line:   string,
	// The look as it is now, as a profile's value (scratch memory).
	snapshot:     proc(p: ^prefs.Prefs) -> string,
	// Make a saved look the current one, from its `key=value` pairs.
	load:         proc(app: ^App, saved: map[string]string),
	// Draw the set's Settings section again.
	redraw:       proc(app: ^App),
	// A BUILT-IN profile, first on the line, when not "": the look with nothing set, so the theme's own. It cannot be
	// deleted or saved over, its button is `data-<word>-profile-builtin`, and a saved profile cannot take its name.
	builtin:      string,
}

notes_profiles :: proc() -> Profile_Set {
	return {
		word = "notes",
		prefix = NOTES_PROFILE_PREF_PREFIX,
		trash_prefix = NOTES_PROFILE_TRASH_PREFIX,
		list = "#prefs-notes-profiles",
		trash = "#prefs-notes-trash",
		trash_line = "#prefs-notes-trash-line",
		snapshot = proc(p: ^prefs.Prefs) -> string {return notes_look_snapshot(p, context.temp_allocator)},
		load = load_notes_look,
		redraw = draw_notes_look_prefs,
	}
}

// Every setting a notes profile holds, and every fine-tuning row it does not hold emptied.
@(private = "file")
load_notes_look :: proc(app: ^App, saved: map[string]string) {
	for key in ([]string{NOTES_PAGE_PREF, NOTES_FONT_PREF, NOTES_BIDS_PREF}) {
		prefs.set(&app.prefs, key, saved[key] or_else "")
	}
	for tune in NOTES_TUNES {
		prefs.set(&app.prefs, tune_pref(tune), saved[tune_pref(tune)] or_else "")
	}
	// The suits last, through their own chooser: it saves the prefs, and it is the one that tells the hand page.
	choose_suits(app, saved[SUITS_PREF] or_else chosen_suits(&app.prefs))
	notes_look_changed(app)
}

// The notes look's profile actions, by their old names.
save_notes_profile :: proc(app: ^App, typed: string) -> string {return save_profile(app, notes_profiles(), typed)}
load_notes_profile :: proc(app: ^App, name: string) -> string {return load_profile(app, notes_profiles(), name)}
delete_notes_profile :: proc(app: ^App, name: string) -> string {return delete_profile(app, notes_profiles(), name)}
restore_notes_profile :: proc(app: ^App, name: string) -> string {return restore_profile(app, notes_profiles(), name)}
empty_notes_trash :: proc(app: ^App) -> string {return empty_profile_trash(app, notes_profiles())}

// A guard action of a set: `<word>:<action>`.
@(private = "file")
profile_action :: proc(set: Profile_Set, action: string) -> string {
	return strings.concatenate({set.word, ":", action}, context.temp_allocator)
}

// Save the current look under `typed`. Replacing an existing profile takes a second click. Says what happened.
save_profile :: proc(app: ^App, set: Profile_Set, typed: string) -> string {
	name := notes_profile_name(typed)
	if name == "" {
		profile_unarm(app)
		return "a profile's name: up to 40 letters, digits, spaces, - _ or ."
	}
	if set.builtin != "" && strings.equal_fold(name, set.builtin) {
		profile_unarm(app)
		return fmt.tprintf("%q is the built-in profile - choose another name", set.builtin)
	}
	key := strings.concatenate({set.prefix, name}, context.temp_allocator)
	existing, replaced := prefs.get(&app.prefs, key)
	current := set.snapshot(&app.prefs)
	if replaced && existing == current {
		profile_unarm(app)
		return fmt.tprintf("profile %q is already this look", name)
	}
	if replaced && !profile_guard(app, profile_action(set, strings.concatenate({"save:", name}, context.temp_allocator))) {
		return fmt.tprintf("%q already exists - press save again to replace it with this look", name)
	}
	if !replaced {
		profile_unarm(app)
	}
	if app.prefs.values != nil {
		prefs.set(&app.prefs, key, current)
		if app.prefs_path != "" {
			_ = prefs.save(&app.prefs, app.prefs_path)
		}
	}
	set.redraw(app)
	return fmt.tprintf("%s profile %q", "replaced" if replaced else "saved", name)
}

// Make a profile the look. Over a look that no profile holds, a second click: the first says it would be lost.
load_profile :: proc(app: ^App, set: Profile_Set, name: string) -> string {
	value, found := prefs.get(&app.prefs, strings.concatenate({set.prefix, name}, context.temp_allocator))
	if !found || value == "" || app.prefs.values == nil {
		profile_unarm(app)
		return fmt.tprintf("no profile %q", name)
	}
	return load_profile_value(app, set, name, value)
}

// The built-in profile (`Profile_Set.builtin`): nothing set.
load_builtin_profile :: proc(app: ^App, set: Profile_Set) -> string {
	if set.builtin == "" || app.prefs.values == nil {
		profile_unarm(app)
		return "no built-in profile"
	}
	return load_profile_value(app, set, set.builtin, builtin_snapshot(set))
}

// The built-in profile's value: the snapshot of prefs with nothing in them, so whatever the set's defaults are
// (the editor's caret line is on, for one).
@(private = "file")
builtin_snapshot :: proc(set: Profile_Set) -> string {
	empty: prefs.Prefs
	return set.snapshot(&empty)
}

@(private = "file")
load_profile_value :: proc(app: ^App, set: Profile_Set, name, value: string) -> string {
	current := set.snapshot(&app.prefs)
	if current == value {
		profile_unarm(app)
		return fmt.tprintf("profile %q is the look already", name)
	}
	if !profile_is_saved(&app.prefs, set, current) &&
	   !profile_guard(app, profile_action(set, strings.concatenate({"load:", name}, context.temp_allocator))) {
		return fmt.tprintf("the look now is in no profile - save it first, or click %q again to load over it", name)
	}
	profile_unarm(app)
	saved := make(map[string]string, 64, context.temp_allocator)
	for part in strings.split(value, ";", context.temp_allocator) {
		if at := strings.index_byte(part, '='); at > 0 {
			saved[part[:at]] = part[at + 1:]
		}
	}
	set.load(app, saved)
	return fmt.tprintf("loaded profile %q", name)
}

// Whether some profile of the set holds `snapshot` - a look that can be loaded again if it is left.
@(private = "file")
profile_is_saved :: proc(p: ^prefs.Prefs, set: Profile_Set, snapshot: string) -> bool {
	if set.builtin != "" && snapshot == builtin_snapshot(set) {
		return true
	}
	for name in notes_profile_names(p, set.prefix) {
		stored, _ := prefs.get(p, strings.concatenate({set.prefix, name}, context.temp_allocator))
		if stored == snapshot {
			return true
		}
	}
	return false
}

// Delete a profile: into the TRASH, where its ↺ brings it back. One click - it can be undone. A deleted profile of
// the same name already there is replaced (the trash keeps the latest of each name).
delete_profile :: proc(app: ^App, set: Profile_Set, name: string) -> string {
	profile_unarm(app)
	key := strings.concatenate({set.prefix, name}, context.temp_allocator)
	value, found := prefs.get(&app.prefs, key)
	if !found || value == "" {
		return fmt.tprintf("no profile %q", name)
	}
	prefs.set(&app.prefs, strings.concatenate({set.trash_prefix, name}, context.temp_allocator), value)
	prefs.remove(&app.prefs, key)
	save_profiles(app, set)
	return fmt.tprintf("deleted profile %q - ↺ %s under deleted brings it back", name, name)
}

// Bring a deleted profile back. Over a saved profile of the same name (and a different look), a second click.
restore_profile :: proc(app: ^App, set: Profile_Set, name: string) -> string {
	trash_key := strings.concatenate({set.trash_prefix, name}, context.temp_allocator)
	value, found := prefs.get(&app.prefs, trash_key)
	if !found || value == "" {
		profile_unarm(app)
		return fmt.tprintf("no deleted profile %q", name)
	}
	key := strings.concatenate({set.prefix, name}, context.temp_allocator)
	if live, exists := prefs.get(&app.prefs, key); exists && live != "" && live != value &&
	   !profile_guard(app, profile_action(set, strings.concatenate({"restore:", name}, context.temp_allocator))) {
		return fmt.tprintf("a saved %q is a different look - press ↺ again to replace it with the deleted one", name)
	}
	profile_unarm(app)
	prefs.set(&app.prefs, key, value)
	prefs.remove(&app.prefs, trash_key)
	save_profiles(app, set)
	return fmt.tprintf("restored profile %q", name)
}

// Empty the trash: the deleted profiles gone for good - on the second click.
empty_profile_trash :: proc(app: ^App, set: Profile_Set) -> string {
	names := notes_profile_names(&app.prefs, set.trash_prefix)
	if len(names) == 0 {
		profile_unarm(app)
		return "the trash is empty"
	}
	if !profile_guard(app, profile_action(set, "empty-trash")) {
		return fmt.tprintf("press empty again to delete %d profile%s for good", len(names), "" if len(names) == 1 else "s")
	}
	for name in names {
		prefs.remove(&app.prefs, strings.concatenate({set.trash_prefix, name}, context.temp_allocator))
	}
	save_profiles(app, set)
	return "the trash is emptied"
}

@(private = "file")
save_profiles :: proc(app: ^App, set: Profile_Set) {
	if app.prefs_path != "" {
		_ = prefs.save(&app.prefs, app.prefs_path)
	}
	set.redraw(app)
}

// The profiles line: a button per profile (lit when it is the look in use) and an `×` to delete it.
draw_profiles :: proc(app: ^App, set: Profile_Set) {
	list := find(app, set.list)
	if list == nil {
		return
	}
	// The trash, on a line of its own that is there only while it has something in it.
	trashed := notes_profile_names(&app.prefs, set.trash_prefix)
	set_shown(app, set.trash_line, len(trashed) > 0)
	if trash := find(app, set.trash); trash != nil && len(trashed) > 0 {
		tb := strings.builder_make(context.temp_allocator)
		for name in trashed {
			shown := escape_html(name, context.temp_allocator)
			fmt.sbprintf(
				&tb,
				`<button class="small profile-restore" data-%s-profile-restore="%s" title="Bring this profile back">&#x21BA; %s</button>`,
				set.word,
				shown,
				shown,
			)
		}
		fmt.sbprintf(
			&tb,
			`<button class="ghost small" data-%s-trash-empty="1" title="Delete these for good (press twice)">empty</button>`,
			set.word,
		)
		sa.set_html(trash, strings.to_string(tb))
	}

	names := notes_profile_names(&app.prefs, set.prefix)
	if len(names) == 0 && set.builtin == "" {
		sa.set_html(list, `<span class="barlabel">none saved yet</span>`)
		return
	}
	current := set.snapshot(&app.prefs)
	b := strings.builder_make(context.temp_allocator)
	if set.builtin != "" {
		shown := escape_html(set.builtin, context.temp_allocator)
		fmt.sbprintf(
			&b,
			`<span class="profile-item"><button class="small profile%s" data-%s-profile-builtin="1" title="Nothing set: the theme's own look, in both themes" data-hint="Built in: clears every row, in both themes - the editor as the theme draws it.">%s</button></span>`,
			" on" if current == builtin_snapshot(set) else "",
			set.word,
			shown,
		)
	}
	for name in names {
		stored, _ := prefs.get(&app.prefs, strings.concatenate({set.prefix, name}, context.temp_allocator))
		shown := escape_html(name, context.temp_allocator)
		fmt.sbprintf(
			&b,
			`<span class="profile-item"><button class="small profile%s" data-%s-profile-load="%s" title="Load this look">%s</button><button class="ghost small profile-delete" data-%s-profile-delete="%s" title="Delete this profile (it goes to deleted, where ↺ brings it back)">&#xD7;</button></span>`,
			" on" if stored == current else "",
			set.word,
			shown,
			shown,
			set.word,
			shown,
		)
	}
	sa.set_html(list, strings.to_string(b))
}

// ---- the built pages ----------------------------------------------------------------------------------

NOTES_LOOK_FILE :: "bml-look.css"

NOTES_LOOK_FILE_HEADER ::
	"/* Written by Bridge Workbench (Settings, Notes look: built pages). The notes view's build button adds this to\n" +
	"   the bml.css it writes beside the pages. Delete it, or choose \"original look\", to build with the stylesheet alone. */\n"

notes_look_file :: proc(app: ^App) -> string {
	if app.docs == "" {
		return ""
	}
	path, _ := filepath.join({app.docs, NOTES_LOOK_FILE}, context.temp_allocator)
	return path
}

// Do the built pages use the chosen look? Whether the file is there.
built_pages_use_look :: proc(app: ^App) -> bool {
	path := notes_look_file(app)
	return path != "" && os.exists(path)
}

// Write the chosen look for the built pages, or take it away. Says what happened.
set_built_pages_look :: proc(app: ^App, on: bool) -> string {
	path := notes_look_file(app)
	if path == "" {
		return "no notes folder to write the look into"
	}
	if !on {
		if os.exists(path) {
			if err := os.remove(path); err != nil {
				return strings.concatenate({"could not remove ", path}, context.temp_allocator)
			}
		}
		return "built pages: the original look, from the next build"
	}
	body := strings.concatenate(
		{NOTES_LOOK_FILE_HEADER, notes_look_rules(notes_look(&app.prefs), context.temp_allocator), "\n"},
		context.temp_allocator,
	)
	if err := os.write_entire_file(path, transmute([]u8)body); err != nil {
		return strings.concatenate({"could not write ", path}, context.temp_allocator)
	}
	return "built pages: the same as the preview, from the next build"
}

// A look button was pressed: remember it, and re-render the preview the next time the notes are shown (the
// settings view hides them, and a frame is not rendered into while hidden).
choose_notes_look :: proc(app: ^App, key, word: string) {
	if app.prefs.values != nil {
		prefs.set(&app.prefs, key, word)
		if app.prefs_path != "" {
			_ = prefs.save(&app.prefs, app.prefs_path)
		}
	}
	notes_look_changed(app)
}

// The look changed: the preview re-renders when next shown, and the built pages follow when they use it.
notes_look_changed :: proc(app: ^App) {
	app.notes_look_stale = true
	// The built pages follow a change too, when they are set to use the look.
	if built_pages_use_look(app) {
		set_text_at(app, "#prefs-notes-note", set_built_pages_look(app, true))
	}
	draw_notes_look_prefs(app)
}

/*
A SET OF FINE-TUNING ROWS: the notes look's (`NOTES_TUNES`), and the notes editor's (`EDITOR_TUNES`,
`editor_look.odin`). Each has its own field ids, its own place in Settings and its own prefs keys - the editor's
colours are kept per theme - and says what to do once a row has changed.
*/
Tune_Set :: struct {
	rows:         []Notes_Tune,
	groups:       []string,
	// A row's field is `#<field_prefix><token>`, its reset `#<field_prefix><token>-reset`.
	field_prefix: string,
	// Selectors: where the rows go, the "N set" count, and the line that says why a value was refused.
	list:         string,
	count:        string,
	note:         string,
	// The reset buttons' attribute, its value the row's token (`*` for every row).
	reset_attr:   string,
	// A row's prefs key.
	pref:         proc(app: ^App, tune: Notes_Tune) -> string,
	// A row changed and is saved: show it.
	changed:      proc(app: ^App),
}

TUNE_FIELD_PREFIX :: "prefs-tune-"

// The rows as slices, for a `Tune_Set` (a constant array cannot be sliced).
notes_tune_rows := NOTES_TUNES
notes_tune_groups := NOTES_TUNE_GROUPS

notes_tune_set :: proc() -> Tune_Set {
	return {
		rows = notes_tune_rows[:],
		groups = notes_tune_groups[:],
		field_prefix = TUNE_FIELD_PREFIX,
		list = "#prefs-notes-tune",
		count = "#prefs-notes-tune-count",
		note = "#prefs-notes-tune-note",
		reset_attr = "data-notes-tune-reset",
		pref = proc(_: ^App, tune: Notes_Tune) -> string {return tune_pref(tune)},
		changed = notes_look_changed,
	}
}

// The notes look's rows, by their old names.
remember_notes_tune :: proc(app: ^App, id: string) -> bool {return remember_tune(app, notes_tune_set(), id)}
reset_notes_tune :: proc(app: ^App, token: string) {reset_tune(app, notes_tune_set(), token)}

// Each row's remembered value, checked (`tune_value`); "" for none. Scratch memory.
tune_values :: proc(app: ^App, set: Tune_Set) -> []string {
	values := make([]string, len(set.rows), context.temp_allocator)
	for tune, index in set.rows {
		if text, found := prefs.get(&app.prefs, set.pref(app, tune)); found && text != "" {
			values[index], _ = tune_value(tune, text, context.temp_allocator)
		}
	}
	return values
}

// The fine-tuning field `#<field_prefix><token>` was left: remember what it holds, or say why not. Returns whether
// `id` was one of the set's fields.
remember_tune :: proc(app: ^App, set: Tune_Set, id: string) -> bool {
	if !strings.has_prefix(id, set.field_prefix) {
		return false
	}
	name := id[len(set.field_prefix):]
	for tune in set.rows {
		if tune.token != name {
			continue
		}
		text := strings.trim_space(tune_field_text(app, tune, id))
		value, ok := tune_value(tune, text, context.temp_allocator)
		if text != "" && !ok {
			low, high := tune_range(tune)
			want := "a colour as #rrggbb or #rgb"
			switch {
			case tune.font:
				want = "a font list (names, commas, quotes)"
			case tune.percent && tune_unit(tune) == "%":
				want = fmt.tprintf("a whole percentage from %d to %d", low, high)
			case tune.percent:
				want = fmt.tprintf("a whole number of %s from %d to %d", tune_unit(tune), low, high)
			}
			set_text_at(app, set.note, strings.concatenate({tune.label, ": ", text, " is not ", want}, context.temp_allocator))
			return true
		}
		// NOTHING CHANGED, nothing to do. Not only an optimisation: the host filling an input (`set_tune_colour`, on
		// every draw) fires the input's own `change` too, which comes back here as `wb-tune` - and saving it would
		// redraw, which fills the inputs again: a loop. A value that is already the saved one ends it.
		saved, _ := prefs.get(&app.prefs, set.pref(app, tune))
		if old, _ := tune_value(tune, saved, context.temp_allocator); old == value {
			return true
		}
		store_tunes(app, set, {tune.token}, value)
		set_text_at(app, set.note, "")
		return true
	}
	return false
}

// A fine-tuning reset: one row back to the look above, or every row (`*`).
reset_tune :: proc(app: ^App, set: Tune_Set, token: string) {
	tokens := make([dynamic]string, context.temp_allocator)
	for tune in set.rows {
		if token == "*" || tune.token == token {
			append(&tokens, tune.token)
		}
	}
	store_tunes(app, set, tokens[:], "")
	set_text_at(app, set.note, "every row is the look above again" if token == "*" else "")
}

@(private = "file")
store_tunes :: proc(app: ^App, set: Tune_Set, tokens: []string, value: string) {
	if app.prefs.values != nil {
		for tune in set.rows {
			if slice.contains(tokens, tune.token) {
				prefs.set(&app.prefs, set.pref(app, tune), value)
			}
		}
		if app.prefs_path != "" {
			_ = prefs.save(&app.prefs, app.prefs_path)
		}
	}
	set.changed(app)
}

/*
What a row's field holds. A colour row is the engine's own COLOUR INPUT (`<input|color>`: a hex field with a
picker on its button), whose value is a colour object - `undefined` when it is empty - so it is read through
script, where `String()` writes it `#RRGGBB`. The size row is a plain text field.
*/
@(private = "file")
tune_field_text :: proc(app: ^App, tune: Notes_Tune, id: string) -> string {
	if tune.percent || tune.font {
		return read_text(app, strings.concatenate({"#", id}, context.temp_allocator))
	}
	script := strings.concatenate({"(function(){ var c = document.$('#", id, "'); return c && c.value ? String(c.value) : ''; })()"}, context.temp_allocator)
	value, err := sa.eval(app.window, script)
	defer sa.value_clear(&value)
	if err != nil {
		return ""
	}
	text, _ := sa.value_to_string(&value, context.temp_allocator)
	return text
}

// Fill a colour row's input: a checked `#rrggbb`, or "" to empty it (`undefined` is the input's "no colour").
@(private = "file")
set_tune_colour :: proc(app: ^App, id, value: string) {
	shown := "undefined" if value == "" else strings.concatenate({"'", value, "'"}, context.temp_allocator)
	script := strings.concatenate({"(function(){ var c = document.$('#", id, "'); if (c) { c.value = ", shown, "; wbTuneSwatch(c); } })()"}, context.temp_allocator)
	result, _ := sa.eval(app.window, script)
	sa.value_clear(&result)
}

// The `fine tuning` toggle: show or fold the rows. Folded at start - they are for when the presets are not enough.
toggle_notes_tunes :: proc(app: ^App) {
	opening := effective_display_is_hidden(app, "#prefs-notes-tune-box")
	set_shown(app, "#prefs-notes-tune-box", opening)
	set_text_at(app, "#prefs-tune-toggle", "fine tuning ▾" if opening else "fine tuning ▸") // ▾ open, ▸ folded
}

/*
The fine-tuning rows, made once (a redraw that rebuilt them would take the caret out of the field being typed
in, and Tab into the next one would land nowhere), then their values set on every draw. One LINE per group,
the group's rows side by side and wrapping, so the block is four lines rather than twenty-one; and the count
says how many rows are set, so a folded block still shows that the look is not the presets' alone.
*/
draw_tunes :: proc(app: ^App, set: Tune_Set, values: []string) {
	list := find(app, set.list)
	if list == nil {
		return
	}
	if count, err := sa.child_count(list); err == nil && count == 0 {
		b := strings.builder_make(context.temp_allocator)
		for group, g in set.groups {
			strings.write_string(&b, `<div class="line tune-group"><span class="barlabel field-label">`)
			strings.write_string(&b, group)
			strings.write_string(&b, `</span><div class="tune-items">`)
			for tune in set.rows {
				if tune.group != g {
					continue
				}
				id := strings.concatenate({set.field_prefix, tune.token}, context.temp_allocator)
				strings.write_string(&b, `<span class="tune-item"><label for="`)
				strings.write_string(&b, id)
				strings.write_string(&b, `">`)
				strings.write_string(&b, escape_html(tune.label, context.temp_allocator))
				strings.write_string(&b, `</label><span class="tune-field">`)
				if tune.percent {
					strings.write_string(&b, `<input type="text" class="num tune" id="`)
					strings.write_string(&b, id)
					strings.write_string(&b, `" placeholder="`)
					strings.write_string(&b, escape_html(tune.placeholder, context.temp_allocator))
					strings.write_string(&b, `" data-hint="`)
					strings.write_string(&b, escape_html(tune.hint, context.temp_allocator))
					strings.write_string(&b, `">`)
				} else if tune.font {
					strings.write_string(&b, `<input type="text" class="tune tune-font" id="`)
					strings.write_string(&b, id)
					strings.write_string(&b, `" placeholder="`)
					strings.write_string(&b, escape_html(tune.placeholder if tune.placeholder != "" else "Georgia, serif", context.temp_allocator))
					strings.write_string(&b, `" data-hint="`)
					if tune.hint != "" {
						strings.write_string(&b, escape_html(tune.hint, context.temp_allocator))
					} else {
						strings.write_string(&b, escape_html(tune.label, context.temp_allocator))
						strings.write_string(&b, `: font names, first choice first, ending in serif or sans-serif - a page read on another machine uses the first it has. Empty keeps the look's.`)
					}
					strings.write_string(&b, `">`)
				} else {
					strings.write_string(&b, `<input|color class="tune-pick" id="`)
					strings.write_string(&b, id)
					strings.write_string(&b, `" data-hint="`)
					strings.write_string(&b, escape_html(tune.label, context.temp_allocator))
					strings.write_string(&b, `: type #rrggbb, or pick one with the button. Empty keeps the look's own.">`)
				}
				// The reset is shown only on a SET row (below): on an empty one it would be a second button beside the
				// colour input's own picker button, doing nothing.
				strings.write_string(&b, `<button class="ghost small tune-reset" id="`)
				strings.write_string(&b, id)
				strings.write_string(&b, `-reset" `)
				strings.write_string(&b, set.reset_attr)
				strings.write_string(&b, `="`)
				strings.write_string(&b, tune.token)
				strings.write_string(&b, `" title="Back to the look above" data-hint="Back to the look chosen above.">&#x21BA;</button></span></span>`)
			}
			strings.write_string(&b, `</div></div>`)
		}
		sa.set_html(list, strings.to_string(b))
	}
	count := 0
	for tune, index in set.rows {
		id := strings.concatenate({set.field_prefix, tune.token}, context.temp_allocator)
		value := values[index]
		if value != "" {
			count += 1
		}
		if reset := find(app, strings.concatenate({"#", id, "-reset"}, context.temp_allocator)); reset != nil {
			// By CLASS, not an inline style: a `style` attribute set here did not stay on the button (measured - and in
			// the window no reset showed even on a set row, reported). `unset` hides it, keeping its room: nothing moves.
			sa.set_attribute(reset, "class", "ghost small tune-reset" if value != "" else "ghost small tune-reset unset")
		}
		if tune.percent {
			set_input(app, strings.concatenate({"#", id}, context.temp_allocator), strings.concatenate({value, tune_unit(tune)}, context.temp_allocator) if value != "" else "")
		} else if tune.font {
			set_input(app, strings.concatenate({"#", id}, context.temp_allocator), value)
		} else {
			set_tune_colour(app, id, value)
		}
	}
	set_text_at(app, set.count, fmt.tprintf("%d set", count) if count > 0 else "none set")
}

// Light the remembered word in each of the three rows.
draw_notes_look_prefs :: proc(app: ^App) {
	look := notes_look(&app.prefs)
	draw_tunes(app, notes_tune_set(), look.tuned[:])
	draw_profiles(app, notes_profiles())
	light :: proc(app: ^App, attribute, chosen: string, words: []string) {
		for word in words {
			selector := strings.concatenate({`#prefs-panel [`, attribute, `="`, word, `"]`}, context.temp_allocator)
			if button := find(app, selector); button != nil {
				sa.set_attribute(button, "class", "segbtn on" if word == chosen else "segbtn")
			}
		}
	}
	pages, fonts, bids := NOTES_PAGES, NOTES_FONTS, NOTES_BIDS
	light(app, "data-notes-page", look.page, pages[:])
	light(app, "data-notes-font", look.font, fonts[:])
	light(app, "data-notes-bids", look.bids, bids[:])
	built := "on" if built_pages_use_look(app) else "off"
	light(app, "data-notes-built", built, {"off", "on"})
}
