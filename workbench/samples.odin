package main

/*
	samples.odin — the SAMPLE NOTES and the EXAMPLE SCENARIOS an installed copy starts with.

	An installed copy has no notes: the notes folder is found through `BML_DOCS_DIRECTORY` or by walking up
	from the working directory (`bml_docs_dir`), and a double-clicked exe in Program Files has neither. Nor
	has it a scenario folder, which `load_user_scenarios` deliberately never invents. So the first run puts
	a copy of each sample in the user's Documents and registers the folder, the same way `add…` would:

	  * `Documents\Bridge notes\squad-system.bml` - a whole system (the English U16 squad agreements), so
	    the notes view, its preview and the quiz have something real to show. Registered in `notes.dirs` and
	    opened (`notes.dir`).
	  * `Documents\Bridge scenarios\guides.scenario` - worked examples in 2/1 meanings, tagged `guide` and so
	    hidden in the deals list until that group is picked.
	  * `Documents\Bridge scenarios\examples.scenario` - a few scenarios in the text language, using only
	    the generic atoms (the named helpers belong to this repository's own system). Registered in
	    `scenarios.dirs`, before the scenarios are loaded, so they are in the deals list from the start.

	ONCE, and only when nothing is set up: a kind is installed when its folders are empty (nothing found,
	nothing remembered, nothing in the environment) and its `samples.*` pref is not yet set. The pref is set
	either way, so forgetting the sample folder later does not bring it back at the next start.

	NEVER OVERWRITES. The copies are the user's to edit; a file that is already there is left alone, by the
	first run and by Settings > Samples > restore, which only puts back what is missing and registers the
	folders again.

	The files are #loaded from `samples/` in this repository. The notes are a COPY of the notes checkout's
	`squad-system.bml`: refresh it with `just vendor-samples` when that file changes enough to matter.
*/

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../prefs"

Sample_File :: struct {
	name, text: string,
}

// Package variables, not constants: a constant array cannot be sliced.
sample_notes := [?]Sample_File{{"squad-system.bml", #load("../samples/notes/squad-system.bml", string)}}
sample_scenarios := [?]Sample_File {
	{"examples.scenario", #load("../samples/scenarios/examples.scenario", string)},
	// Worked examples of the language in 2/1 meanings, tagged `guide`: hidden in the deals list until that group
	// is picked (`OPT_IN_GROUPS`).
	{"guides.scenario", #load("../samples/scenarios/guides.scenario", string)},
}

SAMPLE_NOTES_DIR :: "Bridge notes"
SAMPLE_SCENARIOS_DIR :: "Bridge scenarios"

// Set once each kind has been offered, installed or not (see the header).
SAMPLES_NOTES_PREF :: "samples.notes"
SAMPLES_SCENARIOS_PREF :: "samples.scenarios"

// The folder the samples go in: the user's Documents, or "" when there is none to be had.
samples_home :: proc() -> string {
	documents, err := os.user_documents_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	return documents
}

/*
THE FIRST RUN. Called by startup between reading the prefs and loading the scenarios, with `home` the
user's Documents (`samples_home`); "" does nothing, which is what the tests' startup passes. `notes_found`
is the notes folder found without the prefs (`bml_docs_dir`) and `scenarios_named` the `BRIDGE_SCENARIOS`
folders - passed in, so a test is not at the mercy of the environment it runs in. Returns what it did ("" for
nothing).
*/
install_samples :: proc(app: ^App, home, notes_found, scenarios_named: string) -> string {
	if home == "" || app.prefs.values == nil {
		return ""
	}
	done := make([dynamic]string, 0, 2, context.temp_allocator)

	if offered, _ := prefs.get(&app.prefs, SAMPLES_NOTES_PREF); offered == "" {
		remembered, _ := prefs.get(&app.prefs, NOTES_DIRS_PREF)
		last, _ := prefs.get(&app.prefs, NOTES_DIR_PREF)
		if notes_found == "" && strings.trim_space(remembered) == "" && last == "" {
			if dir, ok := place_samples(home, SAMPLE_NOTES_DIR, sample_notes[:]); ok {
				register_sample_notes(app, dir)
				append(&done, fmt.tprintf("sample notes in %s", dir))
			}
		}
		prefs.set(&app.prefs, SAMPLES_NOTES_PREF, "1")
	}

	if offered, _ := prefs.get(&app.prefs, SAMPLES_SCENARIOS_PREF); offered == "" {
		remembered, _ := prefs.get(&app.prefs, SCENARIO_DIRS_PREF)
		if strings.trim_space(remembered) == "" && strings.trim_space(scenarios_named) == "" {
			if dir, ok := place_samples(home, SAMPLE_SCENARIOS_DIR, sample_scenarios[:]); ok {
				remember_scenario_dir(app, dir)
				append(&done, fmt.tprintf("example scenarios in %s", dir))
			}
		}
		prefs.set(&app.prefs, SAMPLES_SCENARIOS_PREF, "1")
	}

	if app.prefs_path != "" {
		_ = prefs.save(&app.prefs, app.prefs_path)
	}
	if len(done) == 0 {
		return ""
	}
	return strings.concatenate({"first run: ", strings.join(done[:], "; ", context.temp_allocator)}, context.temp_allocator)
}

/*
Settings > Samples > restore: put back any sample file that is missing, never touching one that is there,
and list both folders again (the notes folder is opened, the scenarios are read again). Says what it did.
*/
restore_samples :: proc(app: ^App, home: string) -> string {
	if home == "" {
		return "no Documents folder to put the samples in"
	}
	notes, notes_ok := place_samples(home, SAMPLE_NOTES_DIR, sample_notes[:])
	scenarios, scenarios_ok := place_samples(home, SAMPLE_SCENARIOS_DIR, sample_scenarios[:])
	if !notes_ok && !scenarios_ok {
		return fmt.tprintf("could not write the samples into %s", home)
	}
	if notes_ok {
		register_sample_notes(app, notes)
		if app.window != nil {
			use_bml_dir(app, notes)
		}
	}
	if scenarios_ok {
		remember_scenario_dir(app, scenarios)
		if app.window != nil {
			if ok, why := reload_scenarios(app); !ok {
				return fmt.tprintf("samples are in %s and %s - %s", notes, scenarios, why)
			}
		}
	}
	return fmt.tprintf("samples are in %s and %s (files already there were kept)", notes, scenarios)
}

// Write each file into `home/folder` unless it is there already. The folder's path (scratch), and whether the
// folder now holds every file.
@(private = "file")
place_samples :: proc(home, folder: string, files: []Sample_File) -> (dir: string, ok: bool) {
	joined, err := filepath.join({home, folder}, context.temp_allocator)
	if err != nil {
		return "", false
	}
	if !os.is_dir(joined) && os.make_directory_all(joined) != nil {
		return joined, false
	}
	for file in files {
		path, _ := filepath.join({joined, file.name}, context.temp_allocator)
		if os.exists(path) {
			continue
		}
		if os.write_entire_file(path, transmute([]byte)file.text) != nil {
			return joined, false
		}
	}
	return joined, true
}

// The sample notes folder in the folders list, and the one to open.
@(private = "file")
register_sample_notes :: proc(app: ^App, dir: string) {
	remember_notes_dir(app, dir)
	prefs.set(&app.prefs, NOTES_DIR_PREF, dir)
	if app.prefs_path != "" {
		_ = prefs.save(&app.prefs, app.prefs_path)
	}
}
