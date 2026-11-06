package scenario_dsl

/*
	systems.odin — SYSTEMS and their NAMED MEANINGS: what a call means, written once and used by name.

	WHY. The same auction is a different hand in each partnership: a 1NT response to 1M is 6-9 in Acol, 6-12
	semi-forcing in 2/1; a 1NT opening is 12-14, 15-17 or 16-18. Writing the hand into every scenario that uses
	it means a partnership's one difference is an edit in every file. So a system names its meanings, a
	scenario uses them by name, and a system can EXTEND another and override only what differs:

			system 2over1 "2/1 game forcing"
			  meaning major-opening: (spades >= 5 or hearts >= 5) and hcp in 12..21
			  meaning nt-opening: hcp in 15..17 and balanced

			system ours extends 2over1 "2/1 as we play it"
			  meaning nt-opening: hcp in 14..16 and balanced

			scenario 1nt-stayman "1NT, responder has a four-card major"
			  system: 2over1
			  north: nt-opening
			  south: hcp >= 8 and (spades = 4 or hearts = 4)

	WHICH SYSTEM'S MEANING. A scenario is read in a system: its own (`system:`), or, when the list is set to a
	system that EXTENDS its own, that one - so with `ours` chosen, every 2over1 scenario above uses ours'
	14-16 notrump and nobody copies a file. A meaning is looked up from that system up through what it extends,
	the nearest definition winning. A scenario of no system uses no meanings.

	A MEANING IS A CONDITION, the right-hand side of a seat line, and may use other meanings (not itself, even
	through others). It is EXPANDED where it is used (`Meaning_Node` keeps the name, so a scenario prints back as
	written), which is why the evaluator needed nothing new beyond one node. On a partnership line it reads the
	side's two hands like everything else there, so a meaning with `balanced` in it is refused on one.

	TWO PASSES, because a meaning can be defined in another file from the scenarios that use it: the loader reads
	every file's system blocks first (`read_systems`), checks them as a whole (`check_systems`), and only then
	parses the scenarios against them (`parse(..., systems)`).
*/

import "base:runtime"
import "core:strings"

// One `meaning <name>: <condition>` line. `text` is the condition's source; `line`/`col` where it starts in
// `file`, for diagnostics.
Meaning_Def :: struct {
	name: string,
	text: string,
	file: string,
	line: int, // 0-based line index
	col:  int, // 1-based column of `text`
}

// One `system <name> [extends <parent>] ["<description>"]` block.
System_Def :: struct {
	name:        string,
	parent:      string, // "" for none
	description: string,
	file:        string,
	line:        int, // 0-based, the header
	meanings:    [dynamic]Meaning_Def,
	// Set by `check_systems` when this block is unusable (a second definition of a name, an unknown parent, a
	// cycle): it then defines nothing.
	broken:      bool,
}

// Every system block read so far. Owned: `destroy_systems` gives it back.
Systems :: struct {
	defs:      [dynamic]System_Def,
	allocator: runtime.Allocator,
}

make_systems :: proc(allocator := context.allocator) -> Systems {
	return Systems{defs = make([dynamic]System_Def, 0, 4, allocator), allocator = allocator}
}

destroy_systems :: proc(systems: ^Systems) {
	for &def in systems.defs {
		delete(def.name, systems.allocator)
		delete(def.parent, systems.allocator)
		delete(def.description, systems.allocator)
		delete(def.file, systems.allocator)
		for meaning in def.meanings {
			delete(meaning.name, systems.allocator)
			delete(meaning.text, systems.allocator)
			delete(meaning.file, systems.allocator)
		}
		delete(def.meanings)
	}
	delete(systems.defs)
	systems^ = {}
}

// The usable definition of a system, or nil.
find_system :: proc(systems: ^Systems, name: string) -> ^System_Def {
	if systems == nil || name == "" {
		return nil
	}
	for &def in systems.defs {
		if def.name == name && !def.broken {
			return &def
		}
	}
	return nil
}

// Is `ancestor` the system `name` extends, directly or further up? (A system is not its own ancestor.)
extends_system :: proc(systems: ^Systems, name, ancestor: string) -> bool {
	if ancestor == "" {
		return false
	}
	at := find_system(systems, name)
	for steps := 0; at != nil && steps < len(systems.defs); steps += 1 {
		if at.parent == ancestor {
			return true
		}
		at = find_system(systems, at.parent)
	}
	return false
}

/*
The system a scenario's meanings are read in: the ACTIVE one (the list's choice) when it is the scenario's own
system or extends it, else the scenario's own. "" when there is none.
*/
reading_system :: proc(systems: ^Systems, own, active: string) -> string {
	if own == "" {
		return ""
	}
	if active != "" && (active == own || extends_system(systems, active, own)) {
		return active
	}
	return own
}

/*
A meaning looked up from `system` up through what it extends: the nearest definition, the system it is in,
and the next system further up that defines it too ("" if none) - what this one OVERRIDES.
*/
find_meaning :: proc(
	systems: ^Systems,
	system: string,
	name: string,
) -> (
	meaning: ^Meaning_Def,
	defined_in: string,
	overrides: string,
	ok: bool,
) {
	at := find_system(systems, system)
	for steps := 0; at != nil && steps <= len(systems.defs); steps += 1 {
		for &m in at.meanings {
			if m.name == name {
				if !ok {
					meaning, defined_in, ok = &m, at.name, true
				} else {
					overrides = at.name
					return
				}
			}
		}
		at = find_system(systems, at.parent)
	}
	return
}

// Is this line a system block's header (`system 2over1 ...`), rather than a scenario's `system:` line?
@(private)
is_system_header :: proc(line: string) -> bool {
	lowered := folded(line)
	if !strings.has_prefix(lowered, "system") || len(line) == len("system") {
		return false
	}
	rest := line[len("system"):]
	if rest[0] != ' ' && rest[0] != '\t' {
		return false
	}
	return !strings.has_prefix(strings.trim_space(rest), ":")
}

// Does a scenario or a system start on this line?
@(private)
is_block_header :: proc(line: string) -> bool {
	return strings.has_prefix(folded(line), "scenario") || is_system_header(line)
}

/*
Read every system block in `source` into `systems`, reporting what is wrong with a block's own lines. Scenario
blocks are skipped. What a block refers to - its parent, other meanings - is `check_systems`'s, once every file
has been read.
*/
read_systems :: proc(source, file: string, systems: ^Systems, diagnostics: ^[dynamic]Diagnostic) {
	lines := strings.split_lines(source, context.temp_allocator)
	p := Parser {
		source      = source,
		file        = file,
		lines       = lines,
		diagnostics = diagnostics,
		allocator   = systems.allocator,
	}
	for p.line_index < len(lines) {
		line := strings.trim_space(strip_comment(lines[p.line_index]))
		if line == "" || !is_system_header(line) {
			p.line_index += 1
			continue
		}
		read_system_block(&p, systems)
	}
}

@(private)
read_system_block :: proc(p: ^Parser, systems: ^Systems) {
	header_index := p.line_index
	header := strings.trim_space(strip_comment(p.lines[header_index]))
	p.line_index += 1

	// `system <name> [extends <parent>] ["<description>"]`
	rest := strings.trim_space(header[len("system"):])
	description := ""
	if quote := strings.index_byte(rest, '"'); quote >= 0 {
		description = strings.trim(rest[quote:], "\"")
		rest = strings.trim_space(rest[:quote])
	}
	words := strings.fields(rest, context.temp_allocator)
	name, parent := "", ""
	usable := true
	switch {
	case len(words) == 1:
		name = words[0]
	case len(words) == 3 && folded(words[1]) == "extends":
		name, parent = words[0], words[2]
	case:
		report(p, header_index, 1, "expected `system <name>`, `system <name> extends <other>`, then an optional \"description\"")
		usable = false
	}
	if usable && (!is_system_name(name) || (parent != "" && !is_system_name(parent))) {
		report(p, header_index, 1, "a system's name is one word of letters, digits and dashes, like `2over1`")
		usable = false
	}

	def := System_Def {
		name        = strings.clone(name, systems.allocator),
		parent      = strings.clone(parent, systems.allocator),
		description = strings.clone(description, systems.allocator),
		file        = strings.clone(p.file, systems.allocator),
		line        = header_index,
		meanings    = make([dynamic]Meaning_Def, 0, 4, systems.allocator),
		broken      = !usable,
	}

	for p.line_index < len(p.lines) {
		raw := strip_comment(p.lines[p.line_index])
		line := strings.trim_space(raw)
		if line == "" {
			p.line_index += 1
			continue
		}
		if is_block_header(line) {
			break
		}
		read_meaning_line(p, raw, line, &def, systems.allocator)
		p.line_index += 1
	}
	append(&systems.defs, def)
}

// `meaning <name>: <condition>`, the one kind of line a system block holds.
@(private)
read_meaning_line :: proc(p: ^Parser, raw, line: string, def: ^System_Def, allocator: runtime.Allocator) {
	if !strings.has_prefix(folded(line), "meaning ") {
		report(p, p.line_index, 1, "a system holds `meaning <name>: <condition>` lines")
		return
	}
	rest := line[len("meaning "):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 {
		report(p, p.line_index, 1, "expected `meaning <name>: <condition>`")
		return
	}
	name := strings.trim_space(rest[:colon])
	text := strings.trim_space(rest[colon + 1:])
	if !is_meaning_name(name) {
		report(p, p.line_index, 1, "a meaning's name is one word of letters, digits, dashes and underscores")
		return
	}
	if is_reserved_word(name) {
		report(p, p.line_index, 1, fmt_message(p, "`%s` is already a word of the language - name the meaning something else", name))
		return
	}
	if text == "" {
		report(p, p.line_index, 1, "a meaning needs a condition after its colon")
		return
	}
	for existing in def.meanings {
		if existing.name == name {
			report(p, p.line_index, 1, fmt_message(p, "`%s` is already a meaning of this system", name))
			return
		}
	}
	col := strings.index(raw, text) + 1
	append(
		&def.meanings,
		Meaning_Def {
			name = strings.clone(name, allocator),
			text = strings.clone(text, allocator),
			file = strings.clone(p.file, allocator),
			line = p.line_index,
			col = col,
		},
	)
}

@(private)
is_meaning_name :: proc(name: string) -> bool {
	if name == "" {
		return false
	}
	for i in 0 ..< len(name) {
		if !is_word_byte(name[i]) {
			return false
		}
	}
	return true
}

// A word the grammar already gives a meaning to: an operator, an atom, or a name in the vocabulary.
@(private)
is_reserved_word :: proc(name: string) -> bool {
	lowered := folded(name)
	switch lowered {
	case "and", "or", "not", "in", "balanced", "holds":
		return true
	}
	if _, is_quantity := quantity_of(lowered); is_quantity {
		return true
	}
	if _, is_vulnerability := vulnerability_word_of(lowered); is_vulnerability {
		return true
	}
	return is_vocabulary_word(name)
}

/*
Check the systems as a whole, once every file's blocks are read: a name defined twice (the second is ignored),
a parent nobody defines, a cycle of `extends`, and every meaning's condition - parsed in its own system, so a
typo or a meaning that uses itself is reported where it is written. Diagnostics only for blocks in `only_file`
when it is given (the editor checks one file against the rest).
*/
check_systems :: proc(systems: ^Systems, diagnostics: ^[dynamic]Diagnostic, only_file := "") {
	mine := proc(def: System_Def, only_file: string) -> bool {
		return only_file == "" || def.file == only_file
	}
	say := proc(systems: ^Systems, diagnostics: ^[dynamic]Diagnostic, file: string, line, col: int, message: string) {
		append(
			diagnostics,
			Diagnostic {
				pos = {file = strings.clone(file, systems.allocator), line = line + 1, col = col},
				message = strings.clone(message, systems.allocator),
			},
		)
	}

	for &def, i in systems.defs {
		if def.broken {
			continue
		}
		for other in systems.defs[:i] {
			if other.name == def.name && !other.broken {
				def.broken = true
				if mine(def, only_file) {
					say(
						systems,
						diagnostics,
						def.file,
						def.line,
						1,
						strings.concatenate({"the system `", def.name, "` is defined already, in ", other.file}, context.temp_allocator),
					)
				}
				break
			}
		}
	}
	for &def in systems.defs {
		if def.broken || def.parent == "" {
			continue
		}
		if find_system(systems, def.parent) == nil {
			def.broken = true
			if mine(def, only_file) {
				say(systems, diagnostics, def.file, def.line, 1, strings.concatenate({"no system called `", def.parent, "` to extend"}, context.temp_allocator))
			}
		}
	}
	for &def in systems.defs {
		if def.broken || def.parent == "" {
			continue
		}
		if extends_system(systems, def.name, def.name) || cycles(systems, def.name) {
			def.broken = true
			if mine(def, only_file) {
				say(systems, diagnostics, def.file, def.line, 1, strings.concatenate({"`", def.name, "` extends itself, through the systems it extends"}, context.temp_allocator))
			}
		}
	}

	// Every meaning, parsed where it is written and in its own system.
	for &def in systems.defs {
		if def.broken || !mine(def, only_file) {
			continue
		}
		for meaning in def.meanings {
			scratch := make([dynamic]Node, 0, 8, context.temp_allocator)
			p := Parser {
				file        = meaning.file,
				lines       = {},
				diagnostics = diagnostics,
				allocator   = systems.allocator,
				nodes       = scratch,
				systems     = systems,
				reading     = def.name,
				expanding   = make([dynamic]string, 0, 4, context.temp_allocator),
			}
			p.line_index = meaning.line
			p.text = meaning.text
			p.col = meaning.col
			append(&p.expanding, meaning.name)
			if _, ok := parse_whole_condition(&p); !ok {
				continue
			}
		}
	}
}

// Does walking up from `name` ever come back round? (`extends_system` stops after as many steps as there are
// systems, so a cycle not through `name` itself shows up as a walk that never reaches a root.)
@(private)
cycles :: proc(systems: ^Systems, name: string) -> bool {
	at := find_system(systems, name)
	for steps := 0; at != nil; steps += 1 {
		if steps > len(systems.defs) {
			return true
		}
		if at.parent == "" {
			return false
		}
		at = find_system(systems, at.parent)
	}
	return false
}

/*
A shallow copy of `systems` without the blocks from `file`, for the editor: it checks the BUFFER of one file
against the systems the other files define, then reads the buffer's own blocks into the copy. The strings are
borrowed, so give it a scratch allocator and never `destroy_systems` it.
*/
systems_without_file :: proc(systems: ^Systems, file: string, allocator := context.allocator) -> Systems {
	copy := Systems{defs = make([dynamic]System_Def, 0, len(systems.defs) + 2, allocator), allocator = allocator}
	for def in systems.defs {
		if def.file == file {
			continue
		}
		kept := def
		kept.broken = false
		append(&copy.defs, kept)
	}
	return copy
}
