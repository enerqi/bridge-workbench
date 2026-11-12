package main

/*
	THE LEAD PROBLEM (LEAD_PROBLEM_PLAN.md): the deals view's `lead problems` panel - a panel of its own since
	2026-11-11, with its own seed, status and progress, since at the foot of generate's it read as more options
	of generating. The selected scenario's auction, one hand of it dealt as the leader's, and every lead of that
	hand solved double dummy over `layouts` deals that fit the scenario with that hand fixed - `deal_solve.lead_problem_run`, the same run as
	`sim --lead`.

	THE RESULT is a PAGE in the hand pane (`lead_problem/page.odin`): the hand with each lead's figure beside its
	cards, the ranking, and under each line the layouts where that lead did worst. Each line's layouts are ALSO
	built as a card page by the worker (`deal_solve.lead_layouts_page`, par from one batched solve), and the page's
	`open these as card pages` link (`#lead-row-<n>`, shown only in this engine) puts that one in the pane - the
	carousel, with the play-through and everything else a card page has. `show problem` puts the problem back.
	Both are kept like the analysed page (`App.lead`). The report pane gets one line naming the problem and its seed, never the ranking: beside a pick-first page it gave the answer away.

	PICK FIRST, for a DEALT hand (a hand the scenario fixes with a `holds:` line is answered at once: the user came
	for the answer): the page asks for the lead, and the host hears the pick (`lead-pick` / `lead-skip`, posted by
	the page's script from the framed document) and SCORES it for the session - problems, best leads, the tricks
	given away (`#lead-score`) - and keeps the page answered for its next showing (`lead_problem.answered_page`).
	The answer's `next problem` link (`#lead-next`) deals another from the same scenario with a fresh seed.

	THE SETTINGS: `lead against [contract] by [seat or side]` and `layouts [200]`. An empty contract leaves it to
	the rules (`lead_problem/choose.odin`), and then `by` may be a side ("north-south"): the rules pick which of
	its hands declares. The contract and declarer are remembered PER SCENARIO (`lead.<scenario>` in the prefs
	file), since the contract belongs to the auction; the layouts once for all. Saved when a problem is started
	from them without an error, as the analyse panel's are.
*/

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

import "../deal_solve"
import "../lead_problem"
import "../prefs"
import "norn:cli"
import "norn:norn"
import sa "sciter:sciter_app"

LEAD_LAYOUTS_PREF :: "lead.layouts"
LEAD_SCORING_PREF :: "lead.scoring"
LEAD_DEFAULT_BY :: "south"

@(private = "file")
lead_pref_key :: proc(scenario: string) -> string {
	return fmt.tprintf("lead.%s", scenario)
}

/*
The request the two lead fields spell: `<contract>:<seat>` with a contract, or the seat or side alone. Errors are
worded for the panel.
*/
lead_request_text :: proc(contract_field, by_field: string) -> (text: string, err: string) {
	contract, by := strings.trim_space(contract_field), strings.trim_space(by_field)
	if by == "" {
		by = LEAD_DEFAULT_BY
	}
	if contract == "" {
		return by, ""
	}
	if strings.contains(by, "-") {
		return "", "lead against: with a contract given, name the seat that declares it (south), not a side"
	}
	return fmt.tprintf("%s:%s", contract, by), ""
}

// `fresh`: a new seed whatever the seed field says (`next problem`: the same seed would deal the same problem).
lead_job :: proc(app: ^App, fresh := false) -> (job: Job, err: string) {
	if app.selected < 0 || app.selected >= len(app.scenarios) {
		return {}, "pick a scenario in the list: its auction is the lead problem's"
	}
	contract, by := read_text(app, "#lead-contract"), read_text(app, "#lead-by")
	text, text_err := lead_request_text(contract, by)
	if text_err != "" {
		return {}, text_err
	}
	request, bad := lead_problem.parse_lead_request(text)
	if bad != "" {
		return {}, fmt.tprintf("lead against: %q is not a contract (4S, 3NT)", strings.trim_space(contract))
	}
	request.scoring = lead_scoring(app)
	layouts := lead_depth(app)
	layouts_text := fmt.tprintf("%d", layouts)
	seed: Maybe(u64)
	if seed_text := strings.trim_space(read_text(app, "#lead-seed")); seed_text != "" && !fresh {
		n, seed_ok := strconv.parse_u64(seed_text)
		if !seed_ok {
			return {}, fmt.tprintf("seed: %q is not a number", seed_text)
		}
		seed = n
	}
	name := app.scenarios[app.selected].name
	remember_lead_settings(app, name, contract, by, layouts_text)
	names := []string{name}
	return Job {
			kind = .Lead,
			scenarios = clone_strings(names, app.allocator),
			lead = request,
			lead_layouts = layouts,
			lead_seed = seed,
		},
		""
}

start_lead :: proc(app: ^App, fresh := false) {
	job, err := lead_job(app, fresh)
	if err != "" {
		set_lead_status(app, err)
		return
	}
	start_job(app, job, fmt.tprintf("%d layouts…", job.lead_layouts))
}

/*
The worker's half: the run and its report, into the transcript. `app.scenarios` is safe to read here for the same
reason `work_generate` reads it: the registry is rebuilt only by `reload_scenarios`, which refuses during a job.
Terminal on every path.
*/
work_lead :: proc(app: ^App) {
	name := app.job.scenarios[0]
	scenario, found := cli.lookup(app.scenarios, name)
	if !found {
		fail(app, fmt.tprintf("no scenario %q", name))
		return
	}
	seed := app.job.lead_seed.? or_else cli.fresh_seed()
	state: rand.Xoshiro256_Random_State
	context.random_generator = norn.seeded_xoshiro(&state, seed)

	deal_solve.init()
	defer deal_solve.shutdown()
	started := time.tick_now()
	sa.post_callback(app.window, PROGRESS, 1)
	progress := deal_solve.Lead_Progress {
		report = proc(user: rawptr, stage: deal_solve.Lead_Stage, done, total: int) {
			app := (^App)(user)
			packed := uintptr(stage) << 28 | uintptr(min(done, 0x3fff)) << 14 | uintptr(min(total, 0x3fff))
			sa.post_callback(app.window, LEAD_STEP, packed)
		},
		user = app,
	}
	title := cli.scenario_title(scenario)
	note := fmt.tprintf("%s · seed %d", name, seed)

	// 1. THE QUESTION: dealt, the contract the rules choose, no solver yet - shown at once, so the reader thinks
	// while the leads are solved.
	result := deal_solve.lead_problem_deal(scenario.predicate, app.job.lead, app.job.lead_layouts, context.temp_allocator, progress)
	if result.problem != "" {
		fail(app, fmt.tprintf("%s: %s", name, result.problem))
		return
	}
	question := strings.builder_make(app.allocator)
	deal_solve.write_lead_question(&question, result, title, note)
	heading := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&heading, "lead problem: %s against ", lead_problem.SEAT_WORDS[lead_problem.leader(result.contract)])
	lead_problem.write_contract(&heading, result.contract)
	sync.lock(&app.mutex)
	free_lead_pages(&app.lead_ready, app.allocator)
	app.lead_ready.question = strings.to_string(question)
	app.lead_ready.title = strings.clone(strings.to_string(heading), app.allocator)
	app.lead_ready.scenario = strings.clone(name, app.allocator)
	sync.unlock(&app.mutex)
	sa.post_callback(app.window, LEAD_QUESTION)

	// 2. THE ANSWER: every lead solved and ranked.
	if !deal_solve.lead_problem_leads(&result, context.temp_allocator, progress) {
		fail(app, fmt.tprintf("%s: %s", name, result.problem))
		return
	}
	answer := build_lead_answer(result, title, note, app.allocator)
	answer.scenario = strings.clone(name, app.allocator)
	sync.lock(&app.mutex)
	free_lead_pages(&app.lead_ready, app.allocator)
	app.lead_ready = answer
	sync.unlock(&app.mutex)
	sa.post_callback(app.window, LEAD_PAGE)

	// 3. PAR AND THE CARD PAGES: a chosen contract's par on every layout (most of its time), then each row's worst
	// layouts as a card page with its par captions. Without par the problem stands, and the boards show uncaptioned.
	par_ok := deal_solve.lead_problem_par(&result, context.temp_allocator, progress)
	rows := make([]string, len(result.rows), app.allocator)
	tables, _ := deal_solve.solve_shown_layouts(result, context.temp_allocator)
	for _, r in result.rows {
		rows[r] = deal_solve.lead_layouts_page(result, r, tables, app.allocator)
	}
	choices := strings.builder_make(app.allocator)
	if !par_ok {
		result.choice.pars = 0
	}
	deal_solve.write_lead_choices(&choices, result)
	sync.lock(&app.mutex)
	for row in app.lead_ready_rows {
		delete(row, app.allocator)
	}
	delete(app.lead_ready_rows, app.allocator)
	delete(app.lead_ready_choices, app.allocator)
	app.lead_ready_rows, app.lead_ready_choices = rows, strings.to_string(choices)
	sync.unlock(&app.mutex)
	sa.post_callback(app.window, LEAD_PAR)

	// ONE LINE in the report, to find the problem again by its seed - not the ranking: the page is the answer,
	// and the report beside a pick-first page gave it away (reported, 2026-11-11). `sim --lead` writes the text.
	transcribe(
		app,
		fmt.tprintf(
			"\nlead problem · %s · seed %d · %d layouts (%.1fs)\n",
			title,
			seed,
			result.layouts,
			time.duration_seconds(time.tick_since(started)),
		),
	)
	sa.post_callback(app.window, PROGRESS, 100)
	sa.post_callback(app.window, FINISHED, 0)
}

/*
A lead problem as the pane shows it, all in one allocator: the QUESTION (before the leads are solved), the problem's
page once they are, and each row's worst layouts as a card page ("" for a row with none, and for every row until
par and the shown layouts' tables are in - `rows_pending`).
*/
Lead_Pages :: struct {
	question:     string,
	page:         string,
	rows:         []string,
	rows_pending: bool,
	title:        string, // the problem's pane title
	leads:        []string, // each row's lead, `♦7`, for its pane title
	costs:        []f64, // each row's tricks below the best lead's, for the score
	imps:         []f64, // each row's IMPs a board against the field's lead
	mps:          []f64, // each row's matchpoints (0..1) against it
	scoring:      lead_problem.Scoring, // what the rows were ranked by
	best:         []bool, // each row is as good as the best (`lead_problem.is_best`)
	lead_of:      []lead_problem.Lead, // each row's suit and cards: a card picked on the question finds its row
	scenario:     string, // whose problem it is: `show problem` is for that scenario only
}

// The drill's session: problems answered (a skip is not one), how many with the best lead, the tricks given away.
Lead_Score :: struct {
	problems: int,
	best:     int,
	cost:     f64,
	imps:     f64, // summed: IMPs against the field
	mp:       f64, // summed: each problem's matchpoints, 0..1
}

// The answer's half of `Lead_Pages`: the page and what each row needs, its card pages to come (`rows_pending`).
build_lead_answer :: proc(
	result: deal_solve.Lead_Result,
	title, note: string,
	allocator := context.allocator,
) -> (
	pages: Lead_Pages,
) {
	b := strings.builder_make(allocator)
	deal_solve.write_lead_page(&b, result, title, note)
	pages.page = strings.to_string(b)
	pages.rows = make([]string, len(result.rows), allocator)
	pages.rows_pending = true
	pages.leads = make([]string, len(result.rows), allocator)
	pages.costs = make([]f64, len(result.rows), allocator)
	pages.imps = make([]f64, len(result.rows), allocator)
	pages.mps = make([]f64, len(result.rows), allocator)
	pages.scoring = result.scoring
	pages.best = make([]bool, len(result.rows), allocator)
	pages.lead_of = make([]lead_problem.Lead, len(result.rows), allocator)
	for row, r in result.rows {
		lead := strings.builder_make(context.temp_allocator)
		lead_problem.write_lead(&lead, row.lead)
		pages.leads[r] = strings.clone(strings.to_string(lead), allocator)
		pages.costs[r] = row.cost
		pages.imps[r] = row.imps
		pages.mps[r] = row.mp
		pages.best[r] = lead_problem.is_best(result.rows, r)
		pages.lead_of[r] = row.lead
	}
	heading := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&heading, "lead problem: %s against ", lead_problem.SEAT_WORDS[lead_problem.leader(result.contract)])
	lead_problem.write_contract(&heading, result.contract)
	pages.title = strings.clone(strings.to_string(heading), allocator)
	return
}

// All three steps at once, for a caller that does not show them as they land (the tests): the answer with its
// card pages.
build_lead_pages :: proc(
	result: deal_solve.Lead_Result,
	title, note: string,
	allocator := context.allocator,
) -> (
	pages: Lead_Pages,
) {
	pages = build_lead_answer(result, title, note, allocator)
	tables, _ := deal_solve.solve_shown_layouts(result, context.temp_allocator)
	for _, r in result.rows {
		pages.rows[r] = deal_solve.lead_layouts_page(result, r, tables, allocator)
	}
	pages.rows_pending = false
	return
}

free_lead_pages :: proc(pages: ^Lead_Pages, allocator := context.allocator) {
	delete(pages.question, allocator)
	delete(pages.page, allocator)
	for row in pages.rows {
		delete(row, allocator)
	}
	delete(pages.rows, allocator)
	for lead in pages.leads {
		delete(lead, allocator)
	}
	delete(pages.leads, allocator)
	delete(pages.costs, allocator)
	delete(pages.imps, allocator)
	delete(pages.mps, allocator)
	delete(pages.best, allocator)
	delete(pages.lead_of, allocator)
	delete(pages.title, allocator)
	delete(pages.scenario, allocator)
	pages^ = {}
}

// `LEAD_QUESTION`: a new problem, its question in the pane. What was kept of the last problem goes.
take_lead_question :: proc(app: ^App) {
	sync.lock(&app.mutex)
	ready := app.lead_ready
	app.lead_ready = {}
	sync.unlock(&app.mutex)
	if ready.question == "" {
		free_lead_pages(&ready, app.allocator)
		return
	}
	free_lead_pages(&app.lead, app.allocator)
	app.lead = ready
	app.lead_asking = false
	app.lead_waiting = true
	app.lead_card = {}
	if !show_lead_page(app, -1) {
		set_lead_status(app, "the lead problem's question could not be loaded into the pane")
	}
}

/*
`LEAD_PAGE`: the answer, TAKEN (not copied). It joins the question already kept, and goes in the pane - at the lead
of the card picked meanwhile, scored, when there was one. Put in the pane only while the pane shows this problem:
something else asked for since is left where it is (`show problem` brings the answer).
*/
take_lead_pages :: proc(app: ^App) {
	sync.lock(&app.mutex)
	ready := app.lead_ready
	app.lead_ready = {}
	sync.unlock(&app.mutex)
	if ready.page == "" {
		free_lead_pages(&ready, app.allocator)
		return
	}
	question := app.lead.question
	app.lead.question = ""
	free_lead_pages(&app.lead, app.allocator)
	app.lead = ready
	app.lead.question = question
	was_waiting := app.lead_waiting
	app.lead_waiting = false
	app.lead_asking = strings.contains(ready.page, lead_problem.PICK_BODY)
	if card, picked := app.lead_card.?; picked {
		app.lead_card = {}
		if row := lead_row_of_card(app.lead.lead_of, card); row >= 0 {
			lead_answered(app, row)
		}
	}
	if !was_waiting || (app.showing_lead && app.lead_row < 0) {
		if !show_lead_page(app, -1) {
			set_lead_status(app, "the lead problem's page could not be loaded into the pane")
		}
	}
	refresh_lead_show(app)
}

// `LEAD_PAR`: each row's card page, and the choice block with par in it - swapped into the kept page, and into the
// pane's document when the pane shows it (a block, not a reload: the reader may be part way down the answer).
take_lead_par :: proc(app: ^App) {
	sync.lock(&app.mutex)
	rows, choices := app.lead_ready_rows, app.lead_ready_choices
	app.lead_ready_rows, app.lead_ready_choices = nil, ""
	sync.unlock(&app.mutex)
	defer delete(choices, app.allocator)
	if len(rows) != len(app.lead.rows) {
		for row in rows {
			delete(row, app.allocator)
		}
		delete(rows, app.allocator)
		return
	}
	for row in app.lead.rows {
		delete(row, app.allocator)
	}
	delete(app.lead.rows, app.allocator)
	app.lead.rows = rows
	app.lead.rows_pending = false
	updated := lead_problem.with_choices(app.lead.page, choices, app.allocator)
	delete(app.lead.page, app.allocator)
	app.lead.page = updated
	if app.showing_lead && app.lead_row < 0 {
		if root, ok := lead_frame_root(app); ok {
			if block, err := sa.select_first(root, ".choices"); err == nil && block != nil {
				inner := choices[len(lead_problem.CHOICES_OPEN):len(choices) - len("</div>")]
				_ = sa.set_html(block, inner)
			}
		}
	}
	refresh_lead_browser(app)
}

// The row of `card` (a picked card of the question) in the answer: the row whose lead holds it. -1 if none does.
lead_row_of_card :: proc(leads: []lead_problem.Lead, card: Lead_Card) -> int {
	for lead, r in leads {
		if lead.suit == card.suit && card.rank in lead.cards {
			return r
		}
	}
	return -1
}

// A card of the question's hand, as `data-card` names it.
Lead_Card :: struct {
	suit: norn.Suit,
	rank: norn.Rank,
}

// `"2:12"` -> spades... ; false for anything else.
parse_lead_card :: proc(text: string) -> (card: Lead_Card, ok: bool) {
	colon := strings.index_byte(text, ':')
	if colon < 0 {
		return {}, false
	}
	suit := strconv.parse_int(text[:colon]) or_return
	rank := strconv.parse_int(text[colon + 1:]) or_return
	if suit < 0 || suit > int(max(norn.Suit)) || rank < 0 || rank > int(max(norn.Rank)) {
		return {}, false
	}
	return {norn.Suit(suit), norn.Rank(rank)}, true
}

// Everything the lead problem keeps, freed (the window's teardown).
free_lead_state :: proc(app: ^App) {
	free_lead_pages(&app.lead, app.allocator)
	free_lead_pages(&app.lead_ready, app.allocator)
	for row in app.lead_ready_rows {
		delete(row, app.allocator)
	}
	delete(app.lead_ready_rows, app.allocator)
	delete(app.lead_ready_choices, app.allocator)
	app.lead_ready_rows, app.lead_ready_choices = nil, ""
}

/*
THE DEPTH, `layouts`: one of a few stops (`#lead-depth`), the lit one the setting - read from the document, as the
other segmented controls are drawn into it. The note under it says what the stop buys.
*/
LEAD_DEPTHS := [?]int{50, 100, 200, 400, 1000}
LEAD_DEFAULT_DEPTH :: 200

lead_depth :: proc(app: ^App) -> int {
	for depth in LEAD_DEPTHS {
		button := find(app, fmt.tprintf(`#lead-depth [data-lead-layouts="%d"]`, depth))
		if button == nil {
			continue
		}
		if class, _ := sa.attribute(button, "class", context.temp_allocator); strings.contains(class, "on") {
			return depth
		}
	}
	return LEAD_DEFAULT_DEPTH
}

// Light the stop nearest `layouts` (a remembered number need not be a stop) and say what it buys.
choose_lead_depth :: proc(app: ^App, layouts: int) {
	chosen := LEAD_DEPTHS[0]
	for depth in LEAD_DEPTHS {
		if abs(depth - layouts) < abs(chosen - layouts) {
			chosen = depth
		}
	}
	for depth in LEAD_DEPTHS {
		if button := find(app, fmt.tprintf(`#lead-depth [data-lead-layouts="%d"]`, depth)); button != nil {
			sa.set_attribute(button, "class", "segbtn on" if depth == chosen else "segbtn")
		}
	}
	// The widest 95% margin, at a 50% lead: 1.96 * sqrt(0.25 / n).
	margin := 98 / math.sqrt(f64(chosen))
	speed := "quick" if chosen <= 50 else "slow" if chosen >= 1000 else "slower" if chosen >= 400 else ""
	note := fmt.tprintf("margins up to ±%.0f%%", margin)
	if speed != "" {
		note = fmt.tprintf("%s · %s", note, speed)
	}
	set_text_at(app, "#lead-depth-note", note)
}

// THE SCORING (`#lead-scoring`): the lit stop is the setting, read from the document as the depth is.
lead_scoring :: proc(app: ^App) -> lead_problem.Scoring {
	for scoring in lead_problem.Scoring {
		button := find(app, fmt.tprintf(`#lead-scoring [data-lead-scoring="%s"]`, lead_problem.SCORING_WORDS[scoring]))
		if button == nil {
			continue
		}
		if class, _ := sa.attribute(button, "class", context.temp_allocator); strings.contains(class, "on") {
			return scoring
		}
	}
	return .Beats
}

choose_lead_scoring :: proc(app: ^App, chosen: lead_problem.Scoring) {
	for scoring in lead_problem.Scoring {
		if button := find(app, fmt.tprintf(`#lead-scoring [data-lead-scoring="%s"]`, lead_problem.SCORING_WORDS[scoring])); button != nil {
			sa.set_attribute(button, "class", "segbtn on" if scoring == chosen else "segbtn")
		}
	}
}

// The lead panel's own status line: a refusal, or what a run did (during one, `set_job_status` routes here).
set_lead_status :: proc(app: ^App, text: string) {
	set_text_at(app, "#lead-status", text)
}

// WHILE A PROBLEM IS SOLVED, a spinner and a small bar stand where the status line was, as the analyse panel's do
// (`set_analyse_busy`): the stage is its text. The spin is a class, on only while shown (an animation on a hidden
// element still burns the UI thread).
set_lead_busy :: proc(app: ^App, busy: bool) {
	set_text_at(app, "#lead-busy-text", "solving…")
	if element := find(app, "#lead-busy"); element != nil {
		sa.set_attribute(element, "class", "busy running" if busy else "busy")
	}
	set_shown(app, "#lead-busy", busy)
	set_shown(app, "#lead-status", !busy)
}

// The run's progress, from from `LEAD_STEP`: dealing the layouts, then par (a chosen contract), the leads.
lead_step :: proc(app: ^App, packed: int) {
	stage := deal_solve.Lead_Stage(packed >> 28)
	done, total := (packed >> 14) & 0x3fff, packed & 0x3fff
	if total <= 0 {
		return
	}
	// THE BAR'S SHARES follow where the time goes (measured: dealing ~1%, par 75-85% of a chosen contract) and the
	// order (the leads, then par): with a contract chosen the leads fill 5-25 and par the rest; with one given
	// there is no par.
	chosen := app.job.lead.contract == nil
	leads_to := 25 if chosen else 100
	switch stage {
	case .Layouts:
		set_progress(app, 5 * done / total)
		set_text_at(app, "#lead-busy-text", fmt.tprintf("dealing layouts, %d of %d", done, total))
	case .Par:
		set_progress(app, 25 + 75 * done / total)
		set_text_at(app, "#lead-busy-text", fmt.tprintf("par, %d of %d layouts", done, total))
	case .Leads:
		set_progress(app, 5 + (leads_to - 5) * done / total)
		set_text_at(app, "#lead-busy-text", fmt.tprintf("solving the leads, %d of %d", done, total))
	}
}

// What of the lead problem is in the pane, as html: the problem, or a row's layouts. "" when nothing of it is.
shown_lead_html :: proc(app: ^App) -> string {
	if !app.showing_lead {
		return ""
	}
	if app.lead_row < 0 {
		return app.lead.page if app.lead.page != "" else app.lead.question
	}
	if app.lead_row < len(app.lead.rows) {
		return app.lead.rows[app.lead_row]
	}
	return ""
}

/*
Put the problem (`row` -1) or a row's layouts in the pane. The problem's page has no boards, so `share link` and
`QR` are for the layouts only; `browser` writes either to the temp folder first, as it does the analysed page.
*/
show_lead_page :: proc(app: ^App, row: int) -> bool {
	html, title := app.lead.page, app.lead.title
	if html == "" {
		html = app.lead.question // the answer is not in yet
	}
	if row >= 0 {
		if row >= len(app.lead.rows) || app.lead.rows[row] == "" {
			return false
		}
		html = app.lead.rows[row]
		title = fmt.tprintf("%s: the layouts %s did worst on", app.lead.title, app.lead.leads[row])
	}
	if html == "" {
		return false
	}
	// A load under way makes this one WAIT (`queue_page_request`), and the waiting load, when it goes in, clears
	// what the pane is said to show like any other - so the queue carries that it is a lead page, and which.
	waits := page_load_under_way(app)
	if !show_page_html(app, html, title, take_keyboard = row >= 0) {
		return false
	}
	if waits {
		app.page_queued_lead, app.page_queued_lead_row = true, row
		return true
	}
	lead_page_shown(app, row)
	return true
}

// The pane now shows the lead problem (`row` -1) or a row's layouts.
lead_page_shown :: proc(app: ^App, row: int) {
	app.showing_lead, app.lead_row = true, row
	refresh_lead_show(app)
	refresh_lead_browser(app)
	set_enabled(app, "#page-share", row >= 0)
	set_enabled(app, "#page-qr", row >= 0)
}

/*
`↗ browser` waits for the run: every answer and number on a lead page is worked out HERE, not in the page, so a
copy opened in a browser while the leads or par are still coming would say "your answer opens here" or "being
worked out" for ever. A row's card page exists only once par is in, so only the problem's page waits.
*/
refresh_lead_browser :: proc(app: ^App) {
	if !app.showing_lead {
		return
	}
	calculating := app.lead.page == "" || app.lead.rows_pending
	set_enabled(app, "#page-browser", !(app.running && app.job.kind == .Lead && calculating))
}

show_lead_row :: proc(app: ^App, row: int) {
	if app.lead.rows_pending {
		set_lead_status(app, "the layouts' card pages are still being made (par on every board): a moment")
		return
	}
	if !show_lead_page(app, row) {
		set_lead_status(app, "that lead has no layouts to show")
	}
}

// `show problem` is alive when there is a problem OF THE SELECTED SCENARIO (reported: it stayed lit after picking
// another, and showed the old one's problem) and the pane is not already showing it.
refresh_lead_show :: proc(app: ^App) {
	selected := app.scenarios[app.selected].name if app.selected >= 0 && app.selected < len(app.scenarios) else ""
	mine := app.lead.scenario == "" || app.lead.scenario == selected
	set_enabled(app, "#lead-show", mine && (app.lead.page != "" || app.lead.question != "") && !(app.showing_lead && app.lead_row < 0 && page_pane_shown(app)))
}

// `↗ browser` for a lead page: written to one file in the temp folder, replaced each time. False when the pane
// shows no lead page, and the caller goes on.
open_lead_in_browser :: proc(app: ^App) -> bool {
	html := shown_lead_html(app)
	if html == "" {
		return false
	}
	dir, derr := os.temp_directory(context.temp_allocator)
	path, jerr := filepath.join({dir, "workbench-lead.html"}, context.temp_allocator)
	if derr != nil || jerr != nil || os.write_entire_file(path, transmute([]u8)html) != nil {
		set_note(app, "the lead problem could not be written to the temp folder")
		return true
	}
	open_in_browser(path)
	set_note(app, fmt.tprintf("opened the lead problem in your browser (%s)", path))
	return true
}

/*
THE ROWS' LINKS. The hand page is another document, so its clicks are heard on ITS root (as the notes preview's
are, `watch_preview_clicks`), attached on every `DOCUMENT_COMPLETE` of the pane: a new document is a new root, so
once a document is once. Every page gets it; only a `#lead-row-<n>` link is answered.
*/
init_lead_clicks :: proc(app: ^App) {
	app.lead_click_handler = sa.Event_Handler {
		subscription = {.BEHAVIOR_EVENT},
		on_event     = on_lead_click,
		user_data    = app,
	}
}

watch_lead_clicks :: proc(app: ^App) {
	if app.lead_click_handler.on_event == nil {
		return
	}
	if root, ok := lead_frame_root(app); ok {
		_ = sa.attach_handler(root, &app.lead_click_handler)
	}
}

// The hand pane's document root, through the frame behavior.
lead_frame_root :: proc(app: ^App) -> (root: sa.Element, ok: bool) {
	element := find(app, "#page")
	if element == nil {
		return nil, false
	}
	asset, aerr := sa.element_asset(element, "frame")
	if aerr != nil {
		return nil, false
	}
	document, derr := sa.asset_get(asset, "document")
	defer sa.value_clear(&document)
	if derr != nil {
		return nil, false
	}
	found, rerr := sa.element_from_value(&document)
	return found, rerr == nil && found != nil
}

on_lead_click :: proc(handler: ^sa.Event_Handler, event: sa.Event) -> bool {
	app := (^App)(handler.user_data)
	be, ok := sa.behavior_event(event)
	if !ok || be.phase != .Bubbling {
		return false
	}
	// THE PICK, posted by the page's script from the group clicked (or `show the answer`). It changes no
	// document, so it is answered here.
	if be.code == .CUSTOM {
		switch sa.event_name(be, context.temp_allocator) {
		case "lead-pick":
			text, _ := sa.attribute(be.target, "data-row", context.temp_allocator)
			if row, is_row := strconv.parse_int(text); is_row {
				lead_answered(app, row)
			}
			return true
		case "lead-skip":
			lead_answered(app, -1)
			return true
		case "lead-pick-card":
			// A card picked on the QUESTION: kept for the answer, which opens at its lead (`take_lead_pages`).
			// Answered already (the question's click crossed the answer's arrival): answered now, the same way.
			text, _ := sa.attribute(be.target, "data-card", context.temp_allocator)
			if card, is_card := parse_lead_card(text); is_card {
				if app.lead_waiting {
					app.lead_card = card
				} else if app.lead_asking {
					if row := lead_row_of_card(app.lead.lead_of, card); row >= 0 {
						lead_answered(app, row)
						_ = show_lead_page(app, -1)
					}
				}
			}
			return true
		}
		return false
	}
	if be.code != .HYPERLINK_CLICK {
		return false
	}
	href, _ := sa.attribute(be.target, "href", context.temp_allocator)
	if strings.trim_space(href) == LEAD_NEXT_LINK {
		// Posted: a job starting from inside the page's own click. Never in the windowless tests, which have no
		// worker to run it.
		when !ODIN_TEST {
			sa.post_callback(app.window, LEAD_NEXT)
		}
		return true
	}
	row, is_row := lead_row_link(href)
	if !is_row {
		return false
	}
	app.lead_clicked = row
	// POSTED: the load replaces the document this click is being delivered in. A post segfaults in the windowless
	// tests (see `on_frame_event`), so there it runs at once.
	when ODIN_TEST {
		show_lead_row(app, row)
	} else {
		sa.post_callback(app.window, LEAD_ROW)
	}
	return true
}

LEAD_NEXT_LINK :: "#lead-next"

/*
The page's question answered: `row` the lead picked, -1 skipped. Scored once per problem (a page shown again keeps
its answer, so it cannot ask twice), and the kept page swapped for its answered copy.
*/
lead_answered :: proc(app: ^App, row: int) {
	if !app.lead_asking {
		return
	}
	app.lead_asking = false
	answered := lead_problem.answered_page(app.lead.page, row, app.allocator)
	delete(app.lead.page, app.allocator)
	app.lead.page = answered
	if row < 0 || row >= len(app.lead.costs) {
		return
	}
	app.lead_score.problems += 1
	if app.lead.best[row] {
		app.lead_score.best += 1
	}
	app.lead_score.cost += app.lead.costs[row]
	if row < len(app.lead.imps) {
		app.lead_score.imps += app.lead.imps[row]
		app.lead_score.mp += app.lead.mps[row]
	}
	draw_lead_score(app)
	if app.lead.best[row] {
		set_note(app, fmt.tprintf("%s: the best lead", app.lead.leads[row]))
	} else {
		set_note(app, fmt.tprintf("%s: %.2f tricks below the best lead", app.lead.leads[row], app.lead.costs[row]))
	}
}

// `#lead-score`: the session so far, "" before the first answer.
draw_lead_score :: proc(app: ^App) {
	s := app.lead_score
	text := ""
	if s.problems > 0 {
		text = fmt.tprintf(
			"%d problem%s · %d best lead%s · %.2f tricks given away",
			s.problems,
			"" if s.problems == 1 else "s",
			s.best,
			"" if s.best == 1 else "s",
			s.cost,
		)
		// The scoring of the problem last answered: a session may change it, and the sums are kept for both.
		switch app.lead.scoring {
		case .Beats:
		case .Imps:
			text = fmt.tprintf("%s · %+.1f IMPs against the field", text, s.imps)
		case .Matchpoints:
			text = fmt.tprintf("%s · %.0f%% at matchpoints", text, 100 * s.mp / f64(s.problems))
		}
	}
	if element := find(app, "#lead-score"); element != nil {
		_ = sa.set_text(element, text)
	}
}

// `#lead-row-3` -> 3.
lead_row_link :: proc(href: string) -> (row: int, ok: bool) {
	PREFIX :: "#lead-row-"
	text := strings.trim_space(href)
	if !strings.has_prefix(text, PREFIX) {
		return -1, false
	}
	return strconv.parse_int(text[len(PREFIX):])
}

@(private = "file")
remember_lead_settings :: proc(app: ^App, scenario, contract, by, layouts: string) {
	if app.prefs.values == nil {
		return
	}
	text, _ := lead_request_text(contract, by)
	prefs.set(&app.prefs, lead_pref_key(scenario), text)
	prefs.set(&app.prefs, LEAD_LAYOUTS_PREF, layouts)
	prefs.set(&app.prefs, LEAD_SCORING_PREF, lead_problem.SCORING_WORDS[lead_scoring(app)])
	if app.prefs_path != "" {
		_ = prefs.save(&app.prefs, app.prefs_path)
	}
}

/*
Fill the lead fields for the selected scenario: what was last used with it, or an empty contract by South (the
rules choose, the usual seat of a built-in auction's opener) when it has never been run. The layouts are not per
scenario. Called at startup and on every selection.
*/
restore_lead_settings :: proc(app: ^App) {
	depth := LEAD_DEFAULT_DEPTH
	if remembered, found := prefs.get(&app.prefs, LEAD_LAYOUTS_PREF); found {
		depth = strconv.parse_int(remembered) or_else LEAD_DEFAULT_DEPTH
	}
	choose_lead_depth(app, depth)
	scoring := lead_problem.Scoring.Beats
	if remembered, found := prefs.get(&app.prefs, LEAD_SCORING_PREF); found {
		scoring, _ = lead_problem.parse_scoring(remembered)
	}
	choose_lead_scoring(app, scoring)
	if app.selected < 0 || app.selected >= len(app.scenarios) {
		return
	}
	contract, by := "", LEAD_DEFAULT_BY
	if remembered, found := prefs.get(&app.prefs, lead_pref_key(app.scenarios[app.selected].name)); found {
		if colon := strings.index_byte(remembered, ':'); colon >= 0 {
			contract, by = remembered[:colon], remembered[colon + 1:]
		} else {
			by = remembered
		}
	}
	set_input(app, "#lead-contract", contract)
	set_input(app, "#lead-by", by)
	refresh_lead_show(app)
}
