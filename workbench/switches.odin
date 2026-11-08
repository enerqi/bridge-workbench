package main

/*
	switches.odin — A MEANING'S ALTERNATIVES TICKED ON AND OFF under the deals list's system picker.

	A meaning can name the hands some players count and others do not (`also "14, five-card suit": ...`), and a
	system that extends another switches an inherited one off with a `without` line. These ticks write that line:
	picked in a system of YOUR OWN (one a scenario folder's file defines) that extends another, the deals list's
	sidebar lists each inherited meaning that has alternatives, a tick each, and a click writes or takes out the
	`without "<name>"` in that system's block (`scenario_dsl.set_alternative_switch`), then reloads the list - so
	every scenario read in the system, the deals it generates and each card's label follow at once.

	THE FILE STAYS THE RECORD. The ticks are drawn from the loaded systems, never kept anywhere else: what a tick
	did is a line in the user's own file, to read, edit by hand or share, and a file edited by hand shows the
	same ticks. A system defined in the built-in file shows its alternatives but takes no clicks (it is read
	only), and says how to get one that does.
*/

import "core:fmt"
import "core:os"
import "core:strings"

import "../scenario_dsl"
import sa "sciter:sciter_app"

// One inherited alternative of a meaning, and whether the picked system keeps it.
Switch :: struct {
	meaning:     string,
	alternative: string,
	on:          bool,
}

/*
The switches of the system the list is set to: each meaning it INHERITS that has alternatives (its own
definition, if it gives one, replaces the inherited one, and its alternatives are `also` lines of its own), with
each of them on or off as the system resolves it. `def` nil when the system has none to show - every system, a
compiled one, or one that extends nothing. `editable` when the block is in a file the user can write.
*/
system_switches :: proc(app: ^App) -> (def: ^scenario_dsl.System_Def, switches: []Switch, editable: bool) {
	if app.system == "" {
		return nil, nil, false
	}
	systems := &app.loaded.systems
	def = scenario_dsl.find_system(systems, app.system)
	if def == nil || def.parent == "" {
		return nil, nil, false
	}
	found := make([dynamic]Switch, 0, 8, context.temp_allocator)
	seen := make(map[string]bool, 8, context.temp_allocator)
	at := scenario_dsl.find_system(systems, def.parent)
	for steps := 0; at != nil && steps <= len(systems.defs); steps += 1 {
		for meaning in at.meanings {
			if seen[meaning.name] {
				continue
			}
			seen[meaning.name] = true
			if defines(def, meaning.name) {
				continue
			}
			inherited := scenario_dsl.resolve_meaning(systems, def.parent, meaning.name)
			if !inherited.ok || len(inherited.alternatives) == 0 {
				continue
			}
			here := scenario_dsl.resolve_meaning(systems, def.name, meaning.name)
			for alternative in inherited.alternatives {
				on := false
				for kept in here.alternatives {
					on ||= kept.name == alternative.name
				}
				append(&found, Switch{meaning = meaning.name, alternative = alternative.name, on = on})
			}
		}
		at = scenario_dsl.find_system(systems, at.parent)
	}
	if len(found) == 0 {
		return nil, nil, false
	}
	return def, found[:], !scenario_dsl.is_builtin_source(def.file)
}

// Does the block define `name` itself, with a condition (not an amendment)?
@(private = "file")
defines :: proc(def: ^scenario_dsl.System_Def, name: string) -> bool {
	for meaning in def.meanings {
		if meaning.name == name && !meaning.amends {
			return true
		}
	}
	return false
}

// The ticks, under the picker; nothing at all when the system has no switches.
draw_system_switches :: proc(app: ^App) {
	box := find(app, "#scenario-switches")
	if box == nil {
		return
	}
	def, switches, editable := system_switches(app)
	if def == nil {
		_ = sa.set_text(box, "") // not set_html(""): see `draw_bml_problems`
		return
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`<div class="sw-head" title="%s">alternatives <span class="sw-from">from %s</span></div>`,
		"Hands some players count and others do not. Untick one and your system leaves it out: every scenario read in it, and the deals it makes, follow at once. The tick is a without line in your file." if editable else "This system is built in, so it cannot be changed here. To switch these, write a system of your own that extends it, in a file of yours, and pick that.",
		escape_html(def.parent, context.temp_allocator),
	)
	last := ""
	for s in switches {
		if s.meaning != last {
			fmt.sbprintf(&b, `<div class="sw-meaning">%s</div>`, escape_html(s.meaning, context.temp_allocator))
			last = s.meaning
		}
		fmt.sbprintf(
			&b,
			`<div class="swrow%s%s" data-meaning="%s" data-alt="%s"><span class="tick">%s</span><span class="name">%s</span></div>`,
			" on" if s.on else "",
			"" if editable else " fixed",
			escape_html(s.meaning, context.temp_allocator),
			escape_html(s.alternative, context.temp_allocator),
			"✓" if s.on else "·",
			escape_html(s.alternative, context.temp_allocator),
		)
	}
	sa.set_html(box, strings.to_string(b))
}

/*
A tick was clicked: switch that alternative in the system's own file, and reload so everything follows.

REFUSED - said on the bar, nothing written - during a run (the list cannot be rebuilt under it), for a built-in
system, and when the scenario editor holds that file with unsaved changes (writing under them would lose one or
the other). When the editor has it open and unchanged, it is reopened from what was written.
*/
toggle_switch :: proc(app: ^App, meaning, alternative: string) -> (ok: bool, why: string) {
	def, switches, editable := system_switches(app)
	if def == nil {
		return false, "this system has no alternatives to switch"
	}
	if !editable {
		return false, fmt.tprintf("%s is built in - write a system of your own that extends it to switch these", def.name)
	}
	if app.running {
		return false, "a run is in progress - switch it when it has finished"
	}
	on := false
	known := false
	for s in switches {
		if s.meaning == meaning && s.alternative == alternative {
			on, known = s.on, true
		}
	}
	if !known {
		return false, fmt.tprintf("%s has no alternative \"%s\"", meaning, alternative)
	}
	file := strings.clone(def.file, context.temp_allocator) // `def` is freed by the reload
	system := strings.clone(def.name, context.temp_allocator)
	open_here := app.scn_open != "" && !editing_builtin(app) && same_dir(loaded_path_of(app), file)
	if open_here && scenario_modified(app) {
		return false, fmt.tprintf("%s has unsaved changes in my scenarios - save them first", app.scn_open)
	}
	data, rerr := os.read_entire_file_from_path(file, context.temp_allocator)
	if rerr != nil {
		return false, fmt.tprintf("could not read %s: %v", file, rerr)
	}
	text, refused, switched := scenario_dsl.set_alternative_switch(string(data), system, meaning, alternative, !on, context.temp_allocator)
	if !switched {
		return false, refused
	}
	if werr := os.write_entire_file(file, transmute([]u8)text); werr != nil {
		return false, fmt.tprintf("could not write %s: %v", file, werr)
	}
	if open_here {
		_, _ = open_scenario_file(app, app.scn_open)
	}
	_, _ = reload_scenarios(app)
	return true, fmt.tprintf("%s: \"%s\" %s in %s", meaning, alternative, "on" if !on else "off", system)
}
