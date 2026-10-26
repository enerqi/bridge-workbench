package main

/*
	notes_export.odin — the notes as web pages to keep: `page ↗` writes the open file's document and opens it
	in the browser, `zip` packs it into one file to send, `zip all` packs every document in the folder.

	WHAT IS EXPORTED IS THE DOCUMENT THE OPEN FILE BELONGS TO (decided 2026-10-26): a chapter is exported as
	the root that `#INCLUDE`s it, because a chapter alone loses every `[label](#Anchor)` into its siblings -
	those headings only exist in the assembled root. ONLY that include tree: a page in another tree is another
	document, even when this one links to it (`[..](alternatives.html)`), and that link is left pointing at a
	page the export does not have. `zip all` is the export in which every link lands: every root in the
	folder. The unsaved text in the editor is what is exported for the open file, as `make quiz` does; the
	rest is read from disk.

	EACH PAGE STANDS ALONE: the stylesheet and the look chosen in Settings are inlined and the webfont link
	dropped (`standalone_notes_page`, which the quiz's notes panel uses too), so one page can be copied
	anywhere and opened offline. The pages go to `<deals folder>/notes/<root>/` (`zip all`: `.../notes/<the
	notes folder's name>/`); an export overwrites the pages of the same name from an earlier one.

	THE ZIP IS STORED, NOT COMPRESSED. Odin's `core:compress` only inflates; `vendor:zlib` would deflate, at
	the price of another linked library, for a few hundred KB of html. A stored zip is headers, bytes, and a
	directory at the end, with a CRC-32 from `core:hash` - every unzipper reads it. Its entries sit in a
	folder named as the export is, so unpacking it gives one folder, not loose pages.
*/

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import win "core:sys/windows"

import bml "markup:."

// One file of a zip, or of an export: its name inside the archive and its bytes.
Zip_Entry :: struct {
	name: string,
	data: []u8,
}

// What `export_notes` wrote: its name (the root's, or for `all` the notes folder's), every page as its
// `.bml` name, and where.
Notes_Export :: struct {
	name:   string,
	all:    bool,
	pages:  []string,
	dir:    string,
	files:  []Zip_Entry, // the pages as written, named as in the folder
	shared: int, // how many OTHER roots include the open file too (it is exported under the first)
}

/*
The document a file belongs to: the first root, in the file list's order, whose include tree holds it. A
root is itself. `shared` counts the other roots that include it too - a chapter of two systems is exported
with the first, and the status line says there are others.
*/
notes_root_of :: proc(docs: string, names: []string, file: string) -> (root: string, shared: int) {
	current := ""
	for row in bml_file_tree(docs, names, context.temp_allocator) {
		if row.depth == 0 {
			current = row.name
		}
		if strings.equal_fold(row.name, file) {
			if root == "" {
				root = current
			} else if !strings.equal_fold(current, root) {
				shared += 1
			}
		}
	}
	return root if root != "" else file, shared
}

/*
A notes page that stands alone: the library's html with the stylesheet and the look INLINED and its
`<link>`s gone - a relative `bml.css` would resolve to nothing beside a copied page, and the webfont is a
request the page should not need (it falls back to the stylesheet's other fonts). Pure, so it is tested
without a window; `notes_css` and `notes_look_css` supply the two sheets.
*/
standalone_notes_page :: proc(html, css, look: string, allocator := context.allocator) -> string {
	stripped := strip_link_tags(html, context.temp_allocator)
	head := strings.index(stripped, "<head>")
	if head < 0 || css == "" {
		return strings.clone(stripped, allocator)
	}
	cut := head + len("<head>")
	return strings.concatenate({stripped[:cut], "<style>", css, "</style>", look, stripped[cut:]}, allocator)
}

// The notes folder's `bml.css`, or "" when it has none. Scratch memory.
notes_css :: proc(app: ^App) -> string {
	if app.docs == "" {
		return ""
	}
	path, jerr := filepath.join({app.docs, "bml.css"}, context.temp_allocator)
	if jerr != nil {
		return ""
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	return string(data) if err == nil else ""
}

@(private = "file")
Export_Source :: struct {
	docs:   string,
	open:   string,
	buffer: string,
}

// The include resolver for an export: the open file is the editor's text (unsaved edits included, as the
// export of the file itself has them), everything else is read from the notes folder.
@(private = "file")
export_include :: proc(name: string, user: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool) {
	source := cast(^Export_Source)user
	if strings.equal_fold(filepath.base(name), source.open) {
		return strings.clone(source.buffer, allocator), true
	}
	path, jerr := filepath.join({source.docs, name}, context.temp_allocator)
	if jerr != nil {
		return "", false
	}
	data, err := os.read_entire_file_from_path(path, allocator)
	return string(data), err == nil
}

/*
Render and write the export of `open` (whose current text is `buffer`) from the notes folder `docs` into
`<out>/notes/<name>/`: the root of `open`'s include tree, or with `all` every root in the folder. `css` and
`look` are inlined into every page. Everything in the result is scratch memory. Without a window, so the
tests drive it directly.
*/
export_notes :: proc(
	docs, open, buffer, out, css, look: string,
	all := false,
) -> (
	export: Notes_Export,
	why: string,
) {
	names := list_bml_files(docs, context.temp_allocator)
	source := Export_Source{docs, open, buffer}
	pages := make([dynamic]string, 0, 4, context.temp_allocator)
	export.all = all
	if all {
		for row in bml_file_tree(docs, names, context.temp_allocator) {
			if row.depth == 0 && !slice.contains(pages[:], row.name) {
				append(&pages, row.name)
			}
		}
		export.name = filepath.base(strings.trim_right(docs, "/\\"))
	} else {
		root: string
		root, export.shared = notes_root_of(docs, names, open)
		append(&pages, root)
		export.name = strings.trim_suffix(root, ".bml")
	}

	files := make([dynamic]Zip_Entry, 0, len(pages), context.temp_allocator)
	for page_name in pages {
		text, read := export_include(page_name, &source, context.temp_allocator)
		if !read {
			return export, fmt.tprintf("could not read %s", page_name)
		}
		doc := bml.parse(text, {resolve_include = export_include, include_user = &source})
		html := bml.render_html(doc, context.temp_allocator)
		bml.destroy(doc)
		page := standalone_notes_page(html, css, look, context.temp_allocator)
		name := fmt.tprintf("%s.html", strings.trim_suffix(page_name, ".bml"))
		append(&files, Zip_Entry{name = name, data = transmute([]u8)page})
	}
	export.pages = pages[:]
	export.files = files[:]

	dir, jerr := filepath.join({out, "notes", export.name}, context.temp_allocator)
	if jerr != nil {
		return export, "could not make the export's folder name"
	}
	if mkerr := os.make_directory_all(dir); mkerr != nil && !os.is_dir(dir) {
		return export, fmt.tprintf("could not create %s: %v", dir, mkerr)
	}
	export.dir = dir
	for file in files {
		path, _ := filepath.join({dir, file.name}, context.temp_allocator)
		if werr := os.write_entire_file(path, file.data); werr != nil {
			return export, fmt.tprintf("could not write %s: %v", path, werr)
		}
	}
	return export, ""
}

// What the status line says an export holds: "bidding-system (the document nt-bidding is part of)", or for
// `zip all` "3 documents: alternatives bidding-system squad-system".
export_summary :: proc(export: Notes_Export, open: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	if export.all {
		fmt.sbprintf(&b, "%d document%s:", len(export.pages), "" if len(export.pages) == 1 else "s")
		for page in export.pages {
			fmt.sbprintf(&b, " %s", strings.trim_suffix(page, ".bml"))
		}
		return strings.to_string(b)
	}
	strings.write_string(&b, export.name)
	if !strings.equal_fold(fmt.tprintf("%s.bml", export.name), open) {
		fmt.sbprintf(&b, " (the document %s is part of)", strings.trim_suffix(open, ".bml"))
	}
	if export.shared > 0 {
		fmt.sbprintf(&b, " · %d other document%s include%s it too", export.shared, "" if export.shared == 1 else "s", "s" if export.shared == 1 else "")
	}
	return strings.to_string(b)
}

/*
A STORED zip of `entries`, each under `folder/` when `folder` is not "". Names are flagged UTF-8 (bit 11),
and every entry carries `stamp` as its DOS time, which has 2-second resolution and no time zone.
*/
stored_zip :: proc(entries: []Zip_Entry, folder: string, stamp: time.Time, allocator := context.allocator) -> []u8 {
	put16 :: proc(b: ^[dynamic]u8, v: u16) {append(b, u8(v), u8(v >> 8))}
	put32 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}
	UTF8_NAMES :: u16(1 << 11)
	VERSION :: u16(20) // 2.0: what a stored entry needs

	year, month, day := time.date(stamp)
	hour, minute, second := time.clock(stamp)
	dos_time := u16(hour << 11 | minute << 5 | second / 2)
	dos_date := u16(max(year - 1980, 0) << 9 | int(month) << 5 | day)

	b := make([dynamic]u8, 0, 1024, allocator)
	names := make([]string, len(entries), context.temp_allocator)
	crcs := make([]u32, len(entries), context.temp_allocator)
	offsets := make([]u32, len(entries), context.temp_allocator)
	for entry, i in entries {
		names[i] = entry.name if folder == "" else fmt.tprintf("%s/%s", folder, entry.name)
		crcs[i] = hash.crc32(entry.data)
		offsets[i] = u32(len(b))
		put32(&b, 0x04034b50) // local file header
		put16(&b, VERSION)
		put16(&b, UTF8_NAMES)
		put16(&b, 0) // stored
		put16(&b, dos_time)
		put16(&b, dos_date)
		put32(&b, crcs[i])
		put32(&b, u32(len(entry.data))) // compressed size = size
		put32(&b, u32(len(entry.data)))
		put16(&b, u16(len(names[i])))
		put16(&b, 0) // no extra field
		append(&b, ..transmute([]u8)names[i])
		append(&b, ..entry.data)
	}
	directory := len(b)
	for entry, i in entries {
		put32(&b, 0x02014b50) // central directory header
		put16(&b, VERSION) // made by
		put16(&b, VERSION) // needed
		put16(&b, UTF8_NAMES)
		put16(&b, 0)
		put16(&b, dos_time)
		put16(&b, dos_date)
		put32(&b, crcs[i])
		put32(&b, u32(len(entry.data)))
		put32(&b, u32(len(entry.data)))
		put16(&b, u16(len(names[i])))
		put16(&b, 0) // extra
		put16(&b, 0) // comment
		put16(&b, 0) // disk
		put16(&b, 0) // internal attributes
		put32(&b, 0) // external attributes
		put32(&b, offsets[i])
		append(&b, ..transmute([]u8)names[i])
	}
	directory_size := len(b) - directory // measured before the end record adds to `b`
	put32(&b, 0x06054b50) // end of central directory
	put16(&b, 0)
	put16(&b, 0)
	put16(&b, u16(len(entries)))
	put16(&b, u16(len(entries)))
	put32(&b, u32(directory_size))
	put32(&b, u32(directory))
	put16(&b, 0) // comment length
	return b[:]
}

// The notes view's export, from either button: the pages for the open file's document, in the deals folder.
@(private = "file")
export_open_notes :: proc(app: ^App, all := false) -> (export: Notes_Export, why: string) {
	if app.bml_open == "" {
		return {}, "nothing is open"
	}
	buffer, got := bml_source(app, context.temp_allocator)
	if !got {
		return {}, "the editor's text could not be read"
	}
	out, out_err := resolve_out_dir(read_text(app, "#outdir"))
	if out_err != "" {
		return {}, out_err
	}
	look := notes_look_css(notes_look(&app.prefs), context.temp_allocator)
	return export_notes(app.docs, app.bml_open, buffer, out, notes_css(app), look, all)
}

// `page ↗`: write the pages and open the document's in the browser.
export_notes_to_browser :: proc(app: ^App) {
	export, why := export_open_notes(app)
	if why != "" {
		bml_status(app, why)
		return
	}
	root_page, _ := filepath.join({export.dir, export.files[0].name}, context.temp_allocator)
	open_in_browser(root_page)
	bml_status(app, fmt.tprintf("%s · written to %s", export_summary(export, app.bml_open), export.dir))
}

// `zip` / `zip all`: write the pages, pack them beside their folder as `<name>-notes.zip`, and show it in
// Explorer.
export_notes_to_zip :: proc(app: ^App, all := false) {
	export, why := export_open_notes(app, all)
	if why != "" {
		bml_status(app, why)
		return
	}
	zip := stored_zip(export.files, export.name, time.now(), context.temp_allocator)
	path, _ := filepath.join({filepath.dir(export.dir), fmt.tprintf("%s-notes.zip", export.name)}, context.temp_allocator)
	if werr := os.write_entire_file(path, zip); werr != nil {
		bml_status(app, fmt.tprintf("could not write %s: %v", path, werr))
		return
	}
	show_in_explorer(path)
	bml_status(app, fmt.tprintf("%s · zipped to %s", export_summary(export, app.bml_open), path))
}

// Open Explorer on the folder holding `path`, with the file selected.
show_in_explorer :: proc(path: string) {
	when ODIN_OS == .Windows {
		windows_path, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
		args := fmt.tprintf(`/select,"%s"`, windows_path)
		win.ShellExecuteW(nil, win.utf8_to_wstring("open"), win.utf8_to_wstring("explorer.exe"), win.utf8_to_wstring(args), nil, win.SW_SHOWNORMAL)
	}
}
