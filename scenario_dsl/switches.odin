package scenario_dsl

/*
	switches.odin — A MEANING'S ALTERNATIVE SWITCHED ON OR OFF by editing the file's TEXT.

	A system that extends another amends an inherited meaning by naming it with no condition, and `without "<name>"`
	under it turns one of its alternatives off (systems.odin):

		system ours extends 2over1 "2/1 as we play it"
		  meaning nt-opening
		    without "4441, singleton honour"

	The workbench's switches (a tick per alternative, under the system picker) are that line written or taken out
	for the person, in their own file, so the file stays the one record of what they play: what a tick did is there
	to read, edit by hand, or share. Only the lines a switch owns are touched - a `meaning x` amendment and its
	`without` lines - and everything else (comments, `also` lines, the order of the block) is left as it was.
*/

import "core:strings"

/*
`text` with `alternative` of `meaning` switched `on` or off in the system block `system`, or why it cannot be.

Off: a `without "<alternative>"` line under the block's `meaning <meaning>` amendment, which is added at the end of
the block when there is none. On: that line taken out, and the amendment too when nothing is left under it. Asking
for what already holds changes nothing. Refused when the block DEFINES the meaning (`meaning x: ...`): an
alternative of its own is an `also` line to edit, not a switch. The file's line endings are kept.
*/
set_alternative_switch :: proc(
	text, system, meaning, alternative: string,
	on: bool,
	allocator := context.allocator,
) -> (
	result: string,
	why: string,
	ok: bool,
) {
	crlf := strings.contains(text, "\r\n")
	plain := text
	if crlf {
		plain, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	}
	lines := make([dynamic]string, 0, 64, context.temp_allocator)
	for line in strings.split(plain, "\n", context.temp_allocator) {
		append(&lines, line)
	}

	// The block: its header, and the first line after it at the left margin (the next block, or a comment
	// heading one), with the blank lines before that left outside it.
	header := -1
	for line, i in lines {
		trimmed := strings.trim_space(strip_comment(line))
		if !is_system_header(trimmed) || indent_of(line) > 0 {
			continue
		}
		fields := strings.fields(trimmed, context.temp_allocator)
		if len(fields) >= 2 && fields[1] == system {
			header = i
			break
		}
	}
	if header < 0 {
		return "", strings.concatenate({"there is no system `", system, "` in this file"}, context.temp_allocator), false
	}
	end := len(lines)
	for i in header + 1 ..< len(lines) {
		if strings.trim_space(lines[i]) != "" && indent_of(lines[i]) == 0 {
			end = i
			break
		}
	}
	for end > header + 1 && strings.trim_space(lines[end - 1]) == "" {
		end -= 1
	}

	// The block's own indentation for a meaning line, and for the lines under one.
	indent, child := "  ", ""
	amendment := -1
	for i in header + 1 ..< end {
		trimmed := strings.trim_space(strip_comment(lines[i]))
		if !strings.has_prefix(trimmed, "meaning ") {
			continue
		}
		indent = lines[i][:indent_of(lines[i])]
		named := strings.trim_space(trimmed[len("meaning "):])
		if named == meaning {
			amendment = i
		} else if colon := strings.index_byte(named, ':'); colon >= 0 && strings.trim_space(named[:colon]) == meaning {
			return "", strings.concatenate(
				{"`", meaning, "` is defined in ", system, " itself - its alternatives are its `also` lines, edit them in the file"},
				context.temp_allocator,
			), false
		}
	}

	// The lines under the amendment: deeper than it, up to the next line that is not.
	under_end := amendment + 1
	switched := -1
	if amendment >= 0 {
		for under_end < end {
			line := lines[under_end]
			if strings.trim_space(line) != "" && indent_of(line) <= len(indent) {
				break
			}
			trimmed := strings.trim_space(strip_comment(line))
			if child == "" && trimmed != "" {
				child = line[:indent_of(line)]
			}
			if strings.has_prefix(trimmed, "without") {
				if name, _, quoted := quoted_name(strings.trim_space(trimmed[len("without"):])); quoted && name == alternative {
					switched = under_end
				}
			}
			under_end += 1
		}
	}
	if child == "" {
		child = strings.concatenate({indent, "  "}, context.temp_allocator)
	}
	without := strings.concatenate({child, `without "`, alternative, `"`}, context.temp_allocator)

	switch {
	case !on && switched >= 0, on && switched < 0:
		// Already so.
		return strings.clone(text, allocator), "", true
	case !on && amendment >= 0:
		inject_at(&lines, amendment + 1, without)
	case !on:
		inject_at(&lines, end, without)
		inject_at(&lines, end, strings.concatenate({indent, "meaning ", meaning}, context.temp_allocator))
	case:
		ordered_remove(&lines, switched)
		// The amendment goes too when it no longer says anything.
		left := false
		for i in amendment + 1 ..< under_end - 1 {
			left ||= strings.trim_space(strip_comment(lines[i])) != ""
		}
		if !left {
			ordered_remove(&lines, amendment)
		}
	}
	joined := strings.join(lines[:], "\r\n" if crlf else "\n", context.temp_allocator)
	return strings.clone(joined, allocator), "", true
}

// The width of a line's leading spaces and tabs.
@(private)
indent_of :: proc(line: string) -> int {
	n := 0
	for n < len(line) && (line[n] == ' ' || line[n] == '\t') {
		n += 1
	}
	return n
}
