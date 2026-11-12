package lead_problem

/*
THE PROBLEM AS A PAGE (LEAD_PROBLEM_PLAN.md, "A problem"): what the report says, as one self-contained html
document - the workbench's hand pane shows it, and it opens the same in a browser, so a problem can be kept or
sent as a file.

	- the leader's hand as a diagram, its leads as groups of cards, the best one marked;
	- the auction (the scenario's title), the contract and declarer, and where the contract came from when the rules
	  chose it;
	- the ranking, one line a lead, re-sorted by a click on a column's title (beats it is the IMP question, tricks
	  the matchpoint one);
	- a click on a line opens THE WHY: the layouts where that lead did worst against the best one (against the
	  runner-up for the best one itself), each drawn as a small four-hand diagram with both leads' tricks. In the
	  workbench a link there opens the same layouts as card pages in the carousel (`#lead-row-<n>`, which the host
	  answers; a browser never shows the link, `@media sciter` being the only rule that does);
	- the double-dummy footnote;
	- for a DEALT hand, PICK FIRST (below): the answer hidden until a card of the hand is clicked.

The lines and the numbers are in the markup; the script folds, sorts and answers the pick. A fold's DIAGRAMS are
not: they are script strings (`WHY`), built into the fold while it is open, because this engine re-handles every
element of a document on each resize step, hidden or not - with every row's diagrams in, a resize step of the pane
cost ~30ms against ~5ms (measured 2026-11-11, reported as a slow drag). Written for this engine and a browser alike, so the layout is inline blocks, not flex or grid, and
the columns are px wide: the titles and the lines are different sizes, so `em` columns would not line up.
*/

import "core:fmt"
import "core:strings"

import "norn:norn"

// How many of a lead's worst layouts are drawn under it, and opened as card pages.
WORST_SHOWN :: 6

Page :: struct {
	title:    string, // the scenario's: the auction, as a player writes it
	note:     string, // a line under it ("seed 7"), "" for none
	contract: Lead_Contract,
	hand:     norn.Hand_Summary,
	rows:     []Row,
	tally:    Tally,
	deals:    []norn.Deal, // the layouts, as the tally counted them
	dealt:    int,
	short:    bool,
	chosen:   bool,
	choice:   Choice,
	pick:     bool, // PICK FIRST: the page asks for the lead before it shows the answer
	par_pending: bool, // a chosen contract's par is still being worked out (`write_choices_html`)
	scoring:  Scoring, // what the rows are ranked by (scoring.odin)
	vulnerability: norn.Vulnerability, // the problem's table
}

/*
PICK FIRST (the drill). The page opens on the hand, the auction and the contract only, the body carrying
`PICK_BODY`; a click on a group of the hand is the lead, and the script then shows the ranking with that lead
marked and its verdict over it. The host hears the pick as a `lead-pick` event posted from the group (`lead-skip`
from `show the answer`), scores it, and keeps the page as ANSWERED for its next showing by swapping that body
tag for `<body data-picked="<row>">` (`answered_page`), which the script reads on load. A browser has no
`postEvent`, so there the page answers and tells no one.
*/
PICK_BODY :: `<body class="pick">`

// `page` with its question answered by `row` (-1: skipped), in `allocator`; a page that asked nothing comes back
// as a copy.
answered_page :: proc(page: string, row: int, allocator := context.allocator) -> string {
	out, allocated := strings.replace(page, PICK_BODY, fmt.tprintf(`<body data-picked="%d">`, row), 1, allocator)
	return out if allocated else strings.clone(page, allocator)
}

// Whether row `r` is as good as the best lead: the top row, or one level with it on what the ranking is by and
// giving no trick away.
is_best :: proc(rows: []Row, r: int) -> bool {
	if r < 0 || r >= len(rows) {
		return false
	}
	return r == 0 || (rows[r].cost < 0.005 && rows[r].key >= rows[0].key - 1e-9)
}

@(private = "file")
SUIT_ORDER := [4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs}

@(private = "file")
PAGE_CSS :: `
html { background: #fff; color: #1d2230; }
body { font-family: "Segoe UI", system-ui, sans-serif; font-size: 15px; margin: 18px 24px; max-width: 54em; }
h1 { font-size: 21px; font-weight: 600; margin: 0 0 2px 0; }
.auction { color: #4a5160; font-size: 16px; margin: 0 0 2px 0; }
.note { color: #7a8190; font-size: 12px; }
.table { color: #4a5160; font-size: 13px; margin: 0 0 2px 0; }
.r { color: #c0262d; }
.hand { display: inline-block; width: max-content; margin: 14px 0 8px 0; padding: 8px 14px; border: 1px solid #d6dae2; border-radius: 6px; background: #f7f8fa; }
.suit { margin: 2px 0; font-size: 17px; }
.suit .g { display: inline-block; margin-left: 10px; cursor: pointer; }
.suit .g:hover { text-decoration: underline; }
.suit .g.best { font-weight: 600; color: #1a56c4; border-bottom: 2px solid #1a56c4; }
.hand .key { color: #6a7180; font-size: 12px; margin-top: 4px; }
.suit .g.mine { background: #fff1c2; border-radius: 3px; }
.ask { display: none; margin: 2px 0 10px 0; font-size: 15px; }
.ask .skip { display: inline-block; color: #6a7180; font-size: 12px; margin-left: 14px; cursor: pointer; text-decoration: underline; }
.pick .ask { display: block; }
.pick .answer, .pick .hand .key { display: none; }
.pick .g.best { font-weight: normal; color: inherit; border-bottom-color: transparent; }
.pick .suit .g:hover { background: #e4ebf8; text-decoration: none; }
.verdict { display: none; margin: 4px 0 6px 0; font-size: 15px; }
.verdict.on { display: block; }
.verdict .good { color: #1e7b34; font-weight: 600; }
.verdict .cost { color: #b3261e; font-weight: 600; }
.next { display: none; margin: 0 0 8px 0; }
.next a { display: inline-block; padding: 3px 12px; border: 1px solid #1a56c4; border-radius: 4px; color: #1a56c4; text-decoration: none; }
.next a:hover { background: #eaf0fb; }
.yours { display: none; color: #a35a00; font-size: 12px; margin-left: 10px; }
.lead.mine .yours { display: inline-block; }
.lead.mine .line { font-weight: 600; }
.choice { color: #4a5160; font-size: 13px; margin: 2px 0; }
.choice.note { color: #7a8190; font-size: 12px; }
.count { color: #4a5160; font-size: 13px; margin: 10px 0 8px 0; }
.short { color: #a35a00; }
.head, .line { white-space: nowrap; }
.head { color: #6a7180; font-size: 12px; border-bottom: 1px solid #d6dae2; padding: 2px 0; }
.head span { cursor: pointer; text-decoration: underline dotted #b8bfcc; }
.head span:hover { color: #1a56c4; }
.head span.on { color: #1d2230; font-weight: 600; }
.c { display: inline-block; width: 100px; text-align: right; }
.c.lead-c { width: 120px; text-align: left; padding-left: 6px; }
.c.field { color: #7a8190; }
.line { padding: 4px 0; cursor: pointer; border-bottom: 1px solid #eceef2; }
.line:hover { background: #f1f3f6; }
.lead.open .line { background: #eaf0fb; }
.why { display: none; padding: 8px 6px 12px 6px; border-bottom: 1px solid #d6dae2; }
.lead.open .why { display: block; }
.why .say { color: #4a5160; font-size: 13px; margin-bottom: 6px; }
.layout { display: inline-block; vertical-align: top; margin: 0 10px 10px 0; padding: 6px 8px; border: 1px solid #d6dae2; border-radius: 6px; font-size: 12px; }
.layout .cap { font-size: 12px; margin-bottom: 4px; }
.layout .cap b { font-weight: 600; }
.seat { display: inline-block; width: 8.5em; vertical-align: top; }
.seat.me { color: #8a90a0; }
.seat .who { color: #8a90a0; font-size: 10px; }
.gap { display: inline-block; width: 8.5em; }
.host { display: none; }
.foot { color: #7a8190; font-size: 12px; margin-top: 16px; }
@media sciter {
  .host { display: inline-block; margin-top: 4px; }
  .next { display: block; }
}
`

/*
Folding and sorting. Plain DOM calls this engine's card page uses too (querySelectorAll, addEventListener,
classList, appendChild); no dataset, which the engine does not fill.
*/
@(private = "file")
PAGE_SCRIPT :: `
(function () {
  var list = document.querySelector(".leads");
  function leads() {
    var found = list.querySelectorAll(".lead"), out = [];
    for (var i = 0; i < found.length; i++) out.push(found[i]);
    return out;
  }
  var all = leads();
  for (var i = 0; i < all.length; i++) {
    (function (lead) {
      lead.querySelector(".line").addEventListener("click", function () { fold(lead); });
    })(all[i]);
  }
  // A FOLD'S DIAGRAMS ARE BUILT WHILE IT IS OPEN, from WHY (see write_page): kept in the document hidden, they
  // cost every resize step (measured, 2026-11-11: ~30ms a step with all of them in, ~5ms without).
  function fold(lead) {
    var why = lead.querySelector(".why");
    var opening = !lead.classList.contains("open");
    if (why) why.innerHTML = opening ? WHY[+lead.getAttribute("data-row")] : "";
    lead.classList.toggle("open", opening);
  }
  for (var i = 0; i < all.length; i++) if (all[i].classList.contains("open")) { all[i].classList.remove("open"); fold(all[i]); }
  var body = document.querySelector("body");
  var groups = document.querySelectorAll(".hand .g[data-row]");
  function tell(el, name) { if (el.postEvent) el.postEvent(new Event(name, { bubbles: true })); }
  function answer(row) {
    body.classList.remove("pick");
    for (var i = 0; i < groups.length; i++) {
      groups[i].setAttribute("title", groups[i].getAttribute("data-fig"));
      if (groups[i].getAttribute("data-row") == row) groups[i].classList.add("mine");
    }
    var lead = list.querySelector('.lead[data-row="' + row + '"]');
    if (lead) lead.classList.add("mine");
    var verdict = document.querySelector('.verdict[data-row="' + row + '"]');
    if (verdict) verdict.classList.add("on");
  }
  for (var i = 0; i < groups.length; i++) {
    (function (g) {
      g.addEventListener("click", function () {
        var row = g.getAttribute("data-row");
        if (body.classList.contains("pick")) {
          answer(row);
          tell(g, "lead-pick");
          return;
        }
        var lead = list.querySelector('.lead[data-row="' + row + '"]');
        if (lead) fold(lead);
      });
    })(groups[i]);
  }
  var skip = document.querySelector(".ask .skip");
  if (skip) skip.addEventListener("click", function () { answer("-1"); tell(skip, "lead-skip"); });
  var picked = body.getAttribute("data-picked");
  if (picked !== null && picked !== undefined) answer(picked);
  var heads = document.querySelectorAll(".head span");
  for (var i = 0; i < heads.length; i++) {
    (function (h) {
      h.addEventListener("click", function () {
        var key = h.getAttribute("data-key"), items = leads();
        items.sort(function (a, b) {
          var x = parseFloat(a.getAttribute("data-" + key)), y = parseFloat(b.getAttribute("data-" + key));
          return key == "rank" || key == "cost" ? x - y : y - x;
        });
        for (var j = 0; j < items.length; j++) list.appendChild(items[j]);
        for (var j = 0; j < heads.length; j++) heads[j].classList.toggle("on", heads[j] === h);
      });
    })(heads[i]);
  }
})();
`

// The text, safe in an element or an attribute.
@(private = "file")
write_escaped :: proc(b: ^strings.Builder, text: string) {
	for ch in text {
		switch ch {
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '&':
			strings.write_string(b, "&amp;")
		case '"':
			strings.write_string(b, "&quot;")
		case:
			strings.write_rune(b, ch)
		}
	}
}

// A suit's glyph, red for the red suits.
@(private = "file")
write_glyph :: proc(b: ^strings.Builder, suit: norn.Suit) {
	if suit == .Hearts || suit == .Diamonds {
		fmt.sbprintf(b, `<span class="r">%s</span>`, SUIT_GLYPHS[suit])
	} else {
		strings.write_string(b, SUIT_GLYPHS[suit])
	}
}

@(private = "file")
write_ranks :: proc(b: ^strings.Builder, ranks: norn.Rank_Set) {
	if ranks == {} {
		strings.write_string(b, "—")
		return
	}
	for r := int(max(norn.Rank)); r >= 0; r -= 1 {
		if norn.Rank(r) in ranks {
			strings.write_rune(b, norn.rank_char(norn.Rank(r)))
		}
	}
}

// A lead as glyph and cards, the glyph coloured.
@(private = "file")
write_lead_html :: proc(b: ^strings.Builder, lead: Lead) {
	write_glyph(b, lead.suit)
	write_ranks(b, lead.cards)
}

// `4♠ by South`, the glyph coloured.
@(private = "file")
write_contract_html :: proc(b: ^strings.Builder, c: Lead_Contract) {
	fmt.sbprintf(b, "%d", c.level)
	if c.strain == .NoTrumps {
		strings.write_string(b, "NT")
	} else {
		write_glyph(b, norn.Suit(c.strain))
	}
	fmt.sbprintf(b, " by %s", SEAT_WORDS[c.declarer])
}

// Which row holds the leader's card `rank` of `suit`; -1 if none does.
@(private = "file")
row_of :: proc(rows: []Row, suit: norn.Suit, rank: norn.Rank) -> int {
	for row, i in rows {
		if row.lead.suit == suit && rank in row.lead.cards {
			return i
		}
	}
	return -1
}

/*
The hand, a suit a line, each lead's cards a group, high to low, the best lead marked and named under it. The
figures are the ranking's: a figure beside every group read as clutter (a hand of eight leads within 4% of each
other), so a group carries its "beats it" only as a hover title. A click on a group opens its line in the ranking.
*/
@(private = "file")
write_hand_diagram :: proc(b: ^strings.Builder, hand: norn.Hand_Summary, rows: []Row, pick: bool, scoring: Scoring) {
	strings.write_string(b, `<div class="hand">`)
	for suit in SUIT_ORDER {
		strings.write_string(b, `<div class="suit">`)
		write_glyph(b, suit)
		if hand.suits[suit] == {} {
			strings.write_string(b, ` <span class="g">—</span>`)
		}
		done: norn.Rank_Set
		for r := int(max(norn.Rank)); r >= 0; r -= 1 {
			rank := norn.Rank(r)
			if rank not_in hand.suits[suit] || rank in done {
				continue
			}
			i := row_of(rows, suit, rank)
			if i < 0 {
				continue
			}
			done += rows[i].lead.cards
			fig := figure_title(rows[i], scoring)
			fmt.sbprintf(b, `<span class="g%s" data-row="%d" data-fig="%s"`, " best" if i == 0 else "", i, fig)
			if !pick {
				fmt.sbprintf(b, ` title="%s"`, fig) // asked first, the script sets it once answered
			}
			strings.write_string(b, ">")
			write_ranks(b, rows[i].lead.cards)
			strings.write_string(b, `</span>`)
		}
		strings.write_string(b, `</div>`)
	}
	if len(rows) > 0 {
		strings.write_string(b, `<div class="key">best lead: `)
		write_lead_html(b, rows[0].lead)
		strings.write_string(b, `</div>`)
	}
	strings.write_string(b, `</div>`)
}

// A lead's figure as a hover title: `beats it 40%`, `+0.42 IMPs`, `48% at matchpoints`, `the field's lead`.
@(private = "file")
figure_title :: proc(row: Row, scoring: Scoring) -> string {
	switch {
	case scoring == .Beats:
		return fmt.tprintf("beats it %.0f%%", row.beats * 100)
	case row.field:
		return "the field's lead"
	case scoring == .Imps:
		return fmt.tprintf("%+.2f IMPs", row.imps)
	}
	return fmt.tprintf("%.0f%% at matchpoints", row.mp * 100)
}

// One hand of a layout's diagram: its seat, then a suit a line.
@(private = "file")
write_seat :: proc(b: ^strings.Builder, hand: norn.Hand_Summary, seat: norn.Seat, leader: norn.Seat) {
	fmt.sbprintf(b, `<div class="seat%s"><div class="who">%s</div>`, " me" if seat == leader else "", SEAT_WORDS[seat])
	for suit in SUIT_ORDER {
		write_glyph(b, suit)
		write_ranks(b, hand.suits[suit])
		strings.write_string(b, "<br>")
	}
	strings.write_string(b, `</div>`)
}

/*
One layout, small: North over West and East over South, the leader's hand dimmed (it is the problem's, the same on
every layout), under a caption with both leads' tricks.
*/
@(private = "file")
write_layout :: proc(b: ^strings.Builder, p: Page, deal: norn.Deal, layout: int, mine, theirs: Row) {
	s := norn.summarize_deal(deal)
	me := leader(p.contract)
	need := tricks_to_beat(p.contract)
	strings.write_string(b, `<div class="layout"><div class="cap">`)
	for row, i in ([2]Row{mine, theirs}) {
		if i > 0 {
			strings.write_string(b, " · ")
		}
		tricks := row_tricks(p.tally, row, layout)
		strings.write_string(b, "<b>")
		write_lead_html(b, row.lead)
		fmt.sbprintf(b, "</b> %d", tricks)
		if tricks >= need {
			strings.write_string(b, " (beats it)")
		}
	}
	strings.write_string(b, `</div>`)
	strings.write_string(b, `<div class="gap"></div>`)
	write_seat(b, s[.North], .North, me)
	strings.write_string(b, `<br>`)
	write_seat(b, s[.West], .West, me)
	strings.write_string(b, `<div class="gap"></div>`)
	write_seat(b, s[.East], .East, me)
	strings.write_string(b, `<br><div class="gap"></div>`)
	write_seat(b, s[.South], .South, me)
	strings.write_string(b, `</div>`)
}

// A row's fold: what it is compared with, its worst layouts, and the host's link to them as card pages. The inside
// of its `.why`, which the script puts in while it is open.
@(private = "file")
write_why :: proc(b: ^strings.Builder, p: Page, r: int) {
	other := rival(p.rows, r)
	worst := worst_layouts(p.tally, p.contract, p.rows, r, WORST_SHOWN, context.temp_allocator)
	switch {
	case other < 0:
		strings.write_string(b, `<div class="say">The only lead: nothing to compare it with.</div>`)
	case len(worst) == 0:
		strings.write_string(b, `<div class="say">`)
		write_lead_html(b, p.rows[r].lead)
		strings.write_string(b, ` never took fewer tricks than `)
		write_lead_html(b, p.rows[other].lead)
		strings.write_string(b, ` on these layouts.</div>`)
	case:
		strings.write_string(b, `<div class="say">`)
		fmt.sbprintf(b, "The %d layout%s where ", len(worst), "" if len(worst) == 1 else "s")
		write_lead_html(b, p.rows[r].lead)
		strings.write_string(b, ` did worst against `)
		write_lead_html(b, p.rows[other].lead)
		strings.write_string(b, ` (the defence's tricks):</div>`)
		for layout in worst {
			write_layout(b, p, p.deals[layout], layout, p.rows[r], p.rows[other])
		}
		fmt.sbprintf(b, `<br><a class="host" href="#lead-row-%d">open these as card pages</a>`, r)
	}
}

// `text` as a single-quoted script string: a quote, a backslash and a line break escaped, and `</` written `<\/` so
// the markup cannot close the script it is in. Double quotes stay as they are.
@(private = "file")
write_script_string :: proc(b: ^strings.Builder, text: string) {
	strings.write_byte(b, '\'')
	for i := 0; i < len(text); i += 1 {
		switch text[i] {
		case '\'':
			strings.write_string(b, `\'`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
		case '<':
			if i + 1 < len(text) && text[i + 1] == '/' {
				strings.write_string(b, `<\`)
			} else {
				strings.write_byte(b, '<')
			}
		case:
			strings.write_byte(b, text[i])
		}
	}
	strings.write_byte(b, '\'')
}

/*
What the pick of row `r` earned, over the ranking once answered: as good as the best, or its figures against the
best's, with what it gave away. A gap inside the margin is said to be one, since at this many layouts it is not a
verdict.
*/
@(private = "file")
write_verdict :: proc(b: ^strings.Builder, p: Page, r: int) {
	row, best := p.rows[r], p.rows[0]
	fmt.sbprintf(b, `<div class="verdict" data-row="%d">Your lead, `, r)
	write_lead_html(b, row.lead)
	if is_best(p.rows, r) {
		strings.write_string(b, `, is <span class="good">the best lead</span>`)
		write_verdict_figure(b, p, row)
		strings.write_string(b, ".</div>")
		return
	}
	switch p.scoring {
	case .Beats:
		fmt.sbprintf(b, ", sets the contract on %.0f%% of the layouts; the best, ", row.beats * 100)
		write_lead_html(b, best.lead)
		fmt.sbprintf(b, ", on %.0f%%", best.beats * 100)
	case .Imps, .Matchpoints:
		write_verdict_figure(b, p, row)
		strings.write_string(b, "; the best, ")
		write_lead_html(b, best.lead)
		if best.field {
			strings.write_string(b, ", is the field's lead itself")
		} else if p.scoring == .Imps {
			fmt.sbprintf(b, ", %+.2f", best.imps)
		} else {
			fmt.sbprintf(b, ", %.0f%%", best.mp * 100)
		}
	}
	// The paired margin on the gap when the rows were scored; the wider of the two rows' own before.
	margin := row.key_margin
	if margin == 0 && p.scoring == .Beats {
		margin = max(row.margin, best.margin)
	}
	if best.key - row.key <= margin {
		strings.write_string(b, " (inside the margin)")
	}
	if row.cost >= 0.005 {
		fmt.sbprintf(b, `. It gives away <span class="cost">%.2f tricks</span> a layout.</div>`, row.cost)
	} else {
		strings.write_string(b, ".</div>")
	}
}

/*
What a verdict says of `row` under the page's scoring, after "Your lead, ♦7": `: it sets the contract on 40% of the
layouts`, `, scores +0.42 IMPs a board against the field's lead ♠K`, or the field's lead named as such.
*/
@(private = "file")
write_verdict_figure :: proc(b: ^strings.Builder, p: Page, row: Row) {
	field := field_row(p.rows)
	switch {
	case p.scoring == .Beats:
		fmt.sbprintf(b, ": it sets the contract on %.0f%% of the layouts", row.beats * 100)
	case row.field:
		strings.write_string(b, ", the field's lead (the one taking the most tricks)")
	case field < 0:
	case p.scoring == .Imps:
		fmt.sbprintf(b, ", scores %+.2f IMPs a board against the field's lead, ", row.imps)
		write_lead_html(b, p.rows[field].lead)
	case:
		fmt.sbprintf(b, ", scores %.0f%% of the matchpoints against the field's lead, ", row.mp * 100)
		write_lead_html(b, p.rows[field].lead)
	}
}

/*
THE CHOICE LINES, in one block (`.choices`) the host can REPLACE in a page already shown: par arrives last
(`deal_solve.lead_problem_par`), so a chosen contract's page is first written with `par_pending` and a line saying
par is being worked out, and the host swaps the block when it lands (`CHOICES_OPEN` .. `</div>` in the page, the
element in the frame). Nothing for a contract that was given.
*/
CHOICES_OPEN :: `<div class="choices">`

write_choices_html :: proc(b: ^strings.Builder, chosen: bool, choice: Choice, declarer: norn.Seat, par_pending: bool) {
	strings.write_string(b, CHOICES_OPEN)
	if chosen {
		lines := strings.builder_make(context.temp_allocator)
		write_choice(&lines, choice, declarer)
		for line in strings.split_lines(strings.to_string(lines), context.temp_allocator) {
			if line != "" {
				strings.write_string(b, `<div class="choice">`)
				write_escaped(b, line)
				strings.write_string(b, `</div>`)
			}
		}
		if choice.pars > 0 {
			strings.write_string(
				b,
				`<div class="choice note">Par is the contract the two sides would reach bidding perfectly with every card in view: what the cards make, not what players bid.</div>`,
			)
		}
		if par_pending && choice.pars == 0 {
			strings.write_string(b, `<div class="choice pending">Par on the layouts is being worked out…</div>`)
		}
	}
	strings.write_string(b, `</div>`)
}

// `page` with its choice block replaced by `block` (`write_choices_html`), in `allocator`; a copy if it has none.
with_choices :: proc(page, block: string, allocator := context.allocator) -> string {
	at := strings.index(page, CHOICES_OPEN)
	if at < 0 {
		return strings.clone(page, allocator)
	}
	// The block's own divs are flat (`.choice` lines), so its end is the first `</div></div>` after the opening -
	// or `</div>` straight after it when it is empty.
	rest := page[at + len(CHOICES_OPEN):]
	end := len(CHOICES_OPEN) + len("</div>")
	if !strings.has_prefix(rest, "</div>") {
		close := strings.index(rest, "</div></div>")
		if close < 0 {
			return strings.clone(page, allocator)
		}
		end = len(CHOICES_OPEN) + close + len("</div></div>")
	}
	return strings.concatenate({page[:at], block, page[at + end:]}, allocator)
}

/*
THE QUESTION, before the leads are solved (`deal_solve.lead_problem_deal` has run, `lead_problem_leads` not yet):
the heading, the hand, the auction and the contract, and for a dealt hand the question itself. The answer's groups
of cards are not known yet (leads that score alike on every layout are joined), so here every CARD is its own
choice; a click marks it, says the answer is on its way, and posts `lead-pick-card` from the card (`data-card`:
suit and rank as numbers, `norn.Suit` and `norn.Rank`). The host keeps it and opens the answer at that card's
lead when the answer lands. A typed hand (no `pick`) says only that the leads are being solved.
*/
write_question_page :: proc(b: ^strings.Builder, p: Page) {
	strings.write_string(b, `<!DOCTYPE html><html><head><meta charset="utf-8"><title>`)
	fmt.sbprintf(b, "Lead problem: %s", SEAT_WORDS[leader(p.contract)])
	strings.write_string(b, `</title><style>`)
	strings.write_string(b, PAGE_CSS)
	strings.write_string(b, QUESTION_CSS)
	strings.write_string(b, `</style></head><body class="question">`)
	write_heading(b, p)
	strings.write_string(b, `<div class="hand">`)
	for suit in SUIT_ORDER {
		strings.write_string(b, `<div class="suit">`)
		write_glyph(b, suit)
		if p.hand.suits[suit] == {} {
			strings.write_string(b, ` <span class="g">—</span>`)
		}
		for r := int(max(norn.Rank)); r >= 0; r -= 1 {
			rank := norn.Rank(r)
			if rank not_in p.hand.suits[suit] {
				continue
			}
			say := strings.builder_make(context.temp_allocator)
			write_glyph(&say, suit)
			strings.write_rune(&say, norn.rank_char(rank))
			fmt.sbprintf(b, `<span class="k" data-card="%d:%d" data-say="`, int(suit), int(rank))
			write_escaped(b, strings.to_string(say))
			fmt.sbprintf(b, `">%c</span>`, norn.rank_char(rank))
		}
		strings.write_string(b, `</div>`)
	}
	strings.write_string(b, `</div>`)
	if p.pick {
		strings.write_string(b, `<div class="ask">Which card do you lead? Click it in the hand.</div>`)
	} else {
		strings.write_string(b, `<div class="ask">Every lead is being tried on the layouts…</div>`)
	}
	write_choices_html(b, p.chosen, p.choice, p.contract.declarer, false)
	strings.write_string(b, `<div class="count">`)
	if p.short {
		strings.write_string(b, `<span class="short">Only </span>`)
	}
	fmt.sbprintf(b, "%d layouts (%d deals dealt to find them). Each lead is now being tried on every one of them.</div>", len(p.deals), p.dealt)
	strings.write_string(b, `<script>`)
	if p.pick {
		strings.write_string(b, QUESTION_SCRIPT)
	}
	strings.write_string(b, `</script></body></html>`)
}

@(private = "file")
QUESTION_CSS :: `
.suit .k { display: inline-block; margin-left: 8px; padding: 0 2px; cursor: pointer; border-radius: 3px; }
.suit .k:hover { background: #e4ebf8; }
.suit .k.mine { background: #fff1c2; font-weight: 600; }
.question .ask { display: block; }
.ask .wait { color: #6a7180; }
`

@(private = "file")
QUESTION_SCRIPT :: `
(function () {
  var ask = document.querySelector(".ask"), picked = false;
  var cards = document.querySelectorAll(".hand .k");
  for (var i = 0; i < cards.length; i++) {
    (function (k) {
      k.addEventListener("click", function () {
        if (picked) return;
        picked = true;
        k.classList.add("mine");
        ask.innerHTML = "Your lead: <b>" + k.getAttribute("data-say") + "</b>. <span class=\"wait\">The layouts are still being solved; the answer opens here when they are.</span>";
        if (k.postEvent) k.postEvent(new Event("lead-pick-card", { bubbles: true }));
      });
    })(cards[i]);
  }
})();
`

// The page's head: who leads against what, the auction, the note.
@(private = "file")
write_heading :: proc(b: ^strings.Builder, p: Page) {
	fmt.sbprintf(b, `<h1>%s leads against `, SEAT_WORDS[leader(p.contract)])
	write_contract_html(b, p.contract)
	strings.write_string(b, `</h1>`)
	if p.title != "" {
		strings.write_string(b, `<div class="auction">`)
		write_escaped(b, p.title)
		strings.write_string(b, `</div>`)
	}
	strings.write_string(b, `<div class="table">`)
	strings.write_string(b, VULNERABILITY_WORDS[p.vulnerability])
	if SCORING_LINES[p.scoring] != "" {
		fmt.sbprintf(b, " · %s", SCORING_LINES[p.scoring])
	}
	strings.write_string(b, `</div>`)
	if p.note != "" {
		strings.write_string(b, `<div class="note">`)
		write_escaped(b, p.note)
		strings.write_string(b, `</div>`)
	}
}

// The whole page, into `b`.
write_page :: proc(b: ^strings.Builder, p: Page) {
	strings.write_string(b, `<!DOCTYPE html><html><head><meta charset="utf-8"><title>`)
	fmt.sbprintf(b, "Lead problem: %s", SEAT_WORDS[leader(p.contract)])
	strings.write_string(b, `</title><style>`)
	strings.write_string(b, PAGE_CSS)
	strings.write_string(b, `</style></head>`)
	strings.write_string(b, PICK_BODY if p.pick else `<body>`)
	write_heading(b, p)
	write_hand_diagram(b, p.hand, p.rows, p.pick, p.scoring)
	strings.write_string(
		b,
		`<div class="ask">Which card do you lead? Click it in the hand.<span class="skip">show the answer</span></div>`,
	)
	write_choices_html(b, p.chosen, p.choice, p.contract.declarer, p.par_pending)
	strings.write_string(b, `<div class="answer">`)
	for _, r in p.rows {
		write_verdict(b, p, r)
	}
	strings.write_string(b, `<div class="next"><a class="host" href="#lead-next">next problem</a></div>`)
	strings.write_string(b, `<div class="count">`)
	if p.short {
		strings.write_string(b, `<span class="short">Only </span>`)
	}
	fmt.sbprintf(
		b,
		"%d layouts (%d deals dealt to find them). Click a lead to see the layouts where it did worst.</div>",
		p.tally.layouts,
		p.dealt,
	)

	strings.write_string(b, `<div class="head">`)
	strings.write_string(b, `<span class="c lead-c" data-key="rank" title="The leads, best first. Click to sort.">lead</span>`)
	switch p.scoring {
	case .Beats:
	case .Imps:
		strings.write_string(
			b,
			`<span class="c on" data-key="imps" title="IMPs a board against the field, which leads the card taking the most tricks: a set against a game is worth about ten overtricks. Click to sort.">IMPs</span>`,
		)
	case .Matchpoints:
		strings.write_string(
			b,
			`<span class="c on" data-key="mp" title="Matchpoints against the field, which leads the card taking the most tricks: on each layout, a better result than the field's scores 100%, the same 50%, a worse one 0. Click to sort.">MP</span>`,
		)
	}
	fmt.sbprintf(
		b,
		`<span class="c%s" data-key="beats" title="How often this lead sets the contract, and how far that could be off: 40%% ± 7 is somewhere from 33%% to 47%%. Click to sort.">beats it</span>`,
		" on" if p.scoring == .Beats else "",
	)
	strings.write_string(b, `<span class="c" data-key="tricks" title="The defence's tricks, on average over the layouts. Click to sort.">tricks</span>`)
	strings.write_string(
		b,
		`<span class="c" data-key="cost" title="Tricks a layout this lead gives away against the lead that takes the most. Click to sort.">cost</span>`,
	)
	strings.write_string(b, `</div><div class="leads">`)
	for row, i in p.rows {
		fmt.sbprintf(
			b,
			`<div class="lead" data-row="%d" data-rank="%d" data-beats="%.4f" data-tricks="%.4f" data-cost="%.4f" data-imps="%.4f" data-mp="%.4f"><div class="line">`,
			i,
			i,
			row.beats,
			row.tricks,
			row.cost,
			row.imps,
			row.mp,
		)
		strings.write_string(b, `<span class="c lead-c">`)
		write_lead_html(b, row.lead)
		strings.write_string(b, `</span>`)
		switch {
		case p.scoring == .Beats:
		case row.field:
			strings.write_string(b, `<span class="c field" title="The field's lead: the others are measured against it">field</span>`)
		case p.scoring == .Imps:
			fmt.sbprintf(b, `<span class="c">%+.2f ± %.2f</span>`, row.imps, row.imp_margin)
		case:
			fmt.sbprintf(b, `<span class="c">%.0f%% ± %.0f</span>`, row.mp * 100, row.mp_margin * 100)
		}
		fmt.sbprintf(b, `<span class="c">%.0f%% ± %.0f</span>`, row.beats * 100, row.margin * 100)
		fmt.sbprintf(b, `<span class="c">%.2f</span>`, row.tricks)
		if row.cost < 0.005 {
			strings.write_string(b, `<span class="c">—</span>`)
		} else {
			fmt.sbprintf(b, `<span class="c">−%.2f</span>`, row.cost)
		}
		strings.write_string(b, `<span class="yours">your lead</span>`)
		strings.write_string(b, `</div>`)
		strings.write_string(b, `<div class="why"></div></div>`)
	}
	strings.write_string(b, `</div>`)
	strings.write_string(
		b,
		`<div class="foot">Every layout is played double dummy: all 52 cards visible, best play by everyone. That flatters attacking leads, and the defence never has to guess which card to play later. "beats it" is how often the lead sets the contract, give or take the figure after it (a 95% margin: 19 times in 20 the true share is inside it); "tricks" is the defence's average; "cost" is the tricks a layout it gives away against the lead that takes the most. At IMPs and matchpoints each lead is scored against that same lead, the field's, layout by layout, and the margins are on those paired differences.</div>`,
	)
	// THE FOLDS' INSIDES, one string a row, for the script to build while open (`fold`).
	strings.write_string(b, `</div><script>var WHY = [`)
	for _, r in p.rows {
		if r > 0 {
			strings.write_string(b, ",\n")
		}
		why := strings.builder_make(context.temp_allocator)
		write_why(&why, p, r)
		write_script_string(b, strings.to_string(why))
	}
	strings.write_string(b, "];\n")
	strings.write_string(b, PAGE_SCRIPT)
	strings.write_string(b, `</script></body></html>`)
}
