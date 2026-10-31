package main

/*
	editor_look.odin — how the NOTES EDITOR looks: its font, size and line height, the caret, and the colours of
	the syntax highlighting, picked in Settings under "Notes editor".

	THE NOTES LOOK'S MACHINERY, REUSED: one fine-tuning row per setting (`EDITOR_TUNES`, drawn and checked by
	`draw_tunes` / `remember_tune` in `notes_look.odin`) and profiles of the whole set (`Profile_Set`). There are no
	presets: the theme is the editor's preset, and every row starts empty, which is the theme's own value.

	COLOURS ARE KEPT PER THEME (`editor.dark.<token>`, `editor.light.<token>`): the editor is part of the window and
	follows its theme, and a colour picked against the dark background is rarely the one wanted on the light one.
	Settings shows the rows of the theme in use. The font, size, line height and the caret line are one setting
	for both (`editor.<token>`).

	HOW IT REACHES THE EDITOR. The editor is the window's own document, not a page loaded into a frame, so nothing
	is re-rendered: the page script's `wbEditorLook` sets the font, size and line height as the editor's inline
	style, and each colour as a variable on the editor element - `--ed-<token>`, which the `::mark` rules in
	`ui/workbench.css` read. The sheet declares each one on `#bml-text` as the theme's token (`var(--syn-<token>)`),
	so the editor has its colours before the first apply; a `var(--ed-x, var(--syn-x))` fallback in the rule did not
	work for the caret (it came out the engine's black).

	A VARIABLE SET FROM SCRIPT CANNOT BE UNSET (measured 2026-10-29: `style.variable(name, null)` leaves the
	variable invalid rather than absent, and `removeAttribute("style")` / `cssText = ""` leave it in place). So an
	empty row is not a removed variable but one pointing back at the theme's token, `var(--syn-<token>)` - a value
	the engine resolves when it paints, so it follows a theme change by itself. Every row is written on every apply,
	which makes applying idempotent.

	THE CARET. The engine has no caret width or shape property - `text-selection-caret-color` is the only one it
	knows (`strings` of sciter.dll lists no other) - so a caret that is easier to find is a colour row and the
	CARET LINE: the line holding the caret tinted (`#bml-text > text.wb-caret-line`, kept by the page script's
	`bmlCaretLine`), on by default.
*/

import "core:strings"

import "../prefs"
import sa "sciter:sciter_app"

EDITOR_PREF_PREFIX :: "editor."
EDITOR_CARET_LINE_PREF :: "editor.caret-line"
EDITOR_PROFILE_PREF_PREFIX :: "editor.profile."
EDITOR_PROFILE_TRASH_PREFIX :: "editor.profile-trash."
EDITOR_FIELD_PREFIX :: "prefs-etune-"

// The groups the rows are shown in, in order.
EDITOR_TUNE_GROUPS :: [?]string{"text", "caret", "headings", "calls", "marks"}

// In the order Settings shows them. A colour row's token is `--ed-<token>` on the editor, falling back to
// `--<base>` (`--syn-<token>` when `base` is empty).
EDITOR_TUNES :: [?]Notes_Tune {
	{
		token = "font",
		label = "font",
		font = true,
		placeholder = "Consolas, monospace",
		hint = "The editor's font: names, first choice first, ending in monospace. Empty keeps the window's monospace font.",
	},
	{
		token = "size",
		label = "size",
		percent = true,
		unit = "px",
		low = 8,
		high = 40,
		placeholder = "14px",
		hint = "The editor's text size in pixels (8 to 40); empty keeps the window's.",
	},
	{
		token = "line",
		label = "line height",
		percent = true,
		low = 100,
		high = 300,
		placeholder = "100%",
		hint = "The space a line takes, as a percentage of the text size (100 to 300); empty keeps the font's own.",
	},
	{group = 1, token = "caret", label = "caret", base = "accent"},
	{group = 1, token = "caret-line", label = "caret line", base = "syn-caret-line", alpha = "0.14"},
	{group = 2, token = "head", label = "*"},
	{group = 2, token = "h2", label = "**"},
	{group = 2, token = "h3", label = "***"},
	{group = 2, token = "h4", label = "**** +"},
	{group = 3, token = "bid", label = "call"},
	{group = 3, token = "bid-odd", label = "nested call"},
	{group = 3, token = "opp", label = "their call"},
	{group = 3, token = "alert", label = "alert * ^1"},
	{group = 4, token = "suit", label = "suit !h"},
	{group = 4, token = "link", label = "link"},
	{group = 4, token = "name", label = "convention"},
	{group = 4, token = "num", label = "number"},
	{group = 4, token = "cond", label = "seat / vul", alpha = "0.2"},
	{group = 4, token = "comment", label = "// comment"},
	{group = 4, token = "key", label = "#directive"},
	{group = 4, token = "class", label = "{.class}"},
	{group = 4, token = "list", label = "list mark"},
	{group = 4, token = "code", label = "=mono="},
	{group = 4, token = "seat", label = "seat N:"},
	{group = 4, token = "hand", label = "holding"},
}

editor_tune_rows := EDITOR_TUNES
editor_tune_groups := EDITOR_TUNE_GROUPS

// A colour row (as against the font, size and line height).
@(private = "file")
editor_colour_row :: proc(tune: Notes_Tune) -> bool {
	return !tune.percent && !tune.font
}

// The theme whose colours are in use: `dark` or `light`.
editor_theme_word :: proc(app: ^App) -> string {
	return "light" if effective_theme(chosen_theme(app)) == .Light else "dark"
}

// A row's prefs key: `editor.<theme>.<token>` for a colour, `editor.<token>` for the rest.
editor_pref_key :: proc(tune: Notes_Tune, theme: string) -> string {
	if !editor_colour_row(tune) {
		return strings.concatenate({EDITOR_PREF_PREFIX, tune.token}, context.temp_allocator)
	}
	return strings.concatenate({EDITOR_PREF_PREFIX, theme, ".", tune.token}, context.temp_allocator)
}

// A row's prefs key in the theme in use.
editor_tune_pref :: proc(app: ^App, tune: Notes_Tune) -> string {
	return editor_pref_key(tune, editor_theme_word(app))
}

editor_tune_set :: proc() -> Tune_Set {
	return {
		rows = editor_tune_rows[:],
		groups = editor_tune_groups[:],
		field_prefix = EDITOR_FIELD_PREFIX,
		list = "#prefs-editor-tune",
		count = "#prefs-editor-tune-count",
		note = "#prefs-editor-tune-note",
		reset_attr = "data-editor-tune-reset",
		pref = proc(app: ^App, tune: Notes_Tune) -> string {return editor_tune_pref(app, tune)},
		changed = editor_look_changed,
	}
}

// Is the caret line on? It is unless turned off.
editor_caret_line :: proc(p: ^prefs.Prefs) -> bool {
	word, _ := prefs.get(p, EDITOR_CARET_LINE_PREF)
	return word != "off"
}

// ---- applying it --------------------------------------------------------------------------------------------

// A JavaScript string literal of `text` (the values are checked, but a font list may hold either quote).
@(private = "file")
js_quoted :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for ch in transmute([]u8)text {
		if ch == '"' || ch == '\\' {
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, ch)
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

/*
The call that puts the look on the editor: `wbEditorLook({...})` with the font, size and line height ("" for the
window's own), whether the caret line is on, and EVERY colour variable - the row's colour, or `var(--<base>)` for
an empty row (see the header: a variable cannot be unset). Scratch memory.
*/
editor_look_script :: proc(app: ^App) -> string {
	values := tune_values(app, editor_tune_set())
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "wbEditorLook({")
	vars := strings.builder_make(context.temp_allocator)
	for tune, index in EDITOR_TUNES {
		value := values[index]
		if !editor_colour_row(tune) {
			if tune.percent && value != "" {
				value = strings.concatenate({value, tune_unit(tune)}, context.temp_allocator)
			}
			strings.write_string(&b, tune.token)
			strings.write_string(&b, ": ")
			strings.write_string(&b, js_quoted(value))
			strings.write_string(&b, ", ")
			continue
		}
		if value == "" {
			base := tune.base if tune.base != "" else strings.concatenate({"syn-", tune.token}, context.temp_allocator)
			value = strings.concatenate({"var(--", base, ")"}, context.temp_allocator)
		} else if tune.alpha != "" {
			value = rgba_of(value, tune.alpha, context.temp_allocator)
		}
		if strings.builder_len(vars) > 0 {
			strings.write_string(&vars, ", ")
		}
		strings.write_string(&vars, js_quoted(strings.concatenate({"ed-", tune.token}, context.temp_allocator)))
		strings.write_string(&vars, ": ")
		strings.write_string(&vars, js_quoted(value))
	}
	strings.write_string(&b, "caretLine: ")
	strings.write_string(&b, "true" if editor_caret_line(&app.prefs) else "false")
	strings.write_string(&b, ", vars: {")
	strings.write_string(&b, strings.to_string(vars))
	strings.write_string(&b, "}})")
	return strings.to_string(b)
}

// Put the look on the editor, now. Called at start and on every theme change (`apply_theme`: the colours are the
// theme's), and whenever a row, the caret line or a profile changes it.
apply_editor_look :: proc(app: ^App) {
	if app.window == nil {
		return
	}
	result, _ := sa.eval(app.window, editor_look_script(app))
	sa.value_clear(&result)
}

editor_look_changed :: proc(app: ^App) {
	apply_editor_look(app)
	draw_editor_look_prefs(app)
	look_changed(app, .Editor)
}

// The caret line button: remember it and show it.
choose_editor_caret_line :: proc(app: ^App, on: bool) {
	if app.prefs.values != nil {
		prefs.set(&app.prefs, EDITOR_CARET_LINE_PREF, "on" if on else "off")
		if app.prefs_path != "" {
			_ = prefs.save(&app.prefs, app.prefs_path)
		}
	}
	editor_look_changed(app)
}

// ---- profiles -------------------------------------------------------------------------------------------------

// Every prefs key an editor profile holds: each colour in BOTH themes, the rest once, and the caret line.
@(private = "file")
editor_profile_keys :: proc() -> []string {
	keys := make([dynamic]string, context.temp_allocator)
	for tune in EDITOR_TUNES {
		if editor_colour_row(tune) {
			append(&keys, editor_pref_key(tune, "dark"), editor_pref_key(tune, "light"))
		} else {
			append(&keys, editor_pref_key(tune, ""))
		}
	}
	append(&keys, EDITOR_CARET_LINE_PREF)
	return keys[:]
}

// The editor's look as a profile's value: its set rows (checked), in a fixed order, and the caret line.
editor_look_snapshot :: proc(p: ^prefs.Prefs) -> string {
	b := strings.builder_make(context.temp_allocator)
	for key in editor_profile_keys() {
		text, _ := prefs.get(p, key)
		value := text
		if key == EDITOR_CARET_LINE_PREF {
			value = "on" if editor_caret_line(p) else "off"
		} else {
			for tune in EDITOR_TUNES {
				if strings.has_suffix(key, strings.concatenate({".", tune.token}, context.temp_allocator)) {
					value, _ = tune_value(tune, text, context.temp_allocator)
					break
				}
			}
		}
		if value == "" {
			continue
		}
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, ';')
		}
		strings.write_string(&b, key)
		strings.write_byte(&b, '=')
		strings.write_string(&b, value)
	}
	return strings.to_string(b)
}

editor_profiles :: proc() -> Profile_Set {
	return {
		word = "editor",
		prefix = EDITOR_PROFILE_PREF_PREFIX,
		trash_prefix = EDITOR_PROFILE_TRASH_PREFIX,
		list = "#prefs-editor-profiles",
		trash = "#prefs-editor-trash",
		trash_line = "#prefs-editor-trash-line",
		snapshot = editor_look_snapshot,
		load = load_editor_look,
		redraw = draw_editor_look_prefs,
		builtin = "theme",
	}
}

// Every setting an editor profile holds, and every one it does not hold emptied.
@(private = "file")
load_editor_look :: proc(app: ^App, saved: map[string]string) {
	for key in editor_profile_keys() {
		prefs.set(&app.prefs, key, saved[key] or_else "")
	}
	if app.prefs_path != "" {
		_ = prefs.save(&app.prefs, app.prefs_path)
	}
	editor_look_changed(app)
}

// ---- Settings ---------------------------------------------------------------------------------------------------

draw_editor_look_prefs :: proc(app: ^App) {
	set := editor_tune_set()
	draw_tunes(app, set, tune_values(app, set))
	draw_profiles(app, editor_profiles())
	on := editor_caret_line(&app.prefs)
	for word in ([]string{"off", "on"}) {
		selector := strings.concatenate({`#prefs-panel [data-editor-caret-line="`, word, `"]`}, context.temp_allocator)
		if button := find(app, selector); button != nil {
			sa.set_attribute(button, "class", "segbtn on" if (word == "on") == on else "segbtn")
		}
	}
	set_text_at(
		app,
		"#prefs-editor-theme-note",
		strings.concatenate({"The colours below are the ", editor_theme_word(app), " theme's; the other theme keeps its own."}, context.temp_allocator),
	)
}
