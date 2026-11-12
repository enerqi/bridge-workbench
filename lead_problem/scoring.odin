package lead_problem

/*
THE SCORING FORM (LEAD_PROBLEM_PLAN.md, "Scoring"): what a lead is worth depends on how the board is scored, and the
tricks each lead takes on each layout are all any form needs.

	- `Beats`, the plain question: how often the lead sets the contract.
	- `Imps`: each layout's result scored (level, strain, the declaring side's vulnerability, undoubled), and the
	  difference from the FIELD'S result put on the IMP scale. A set against a game is worth about ten overtricks,
	  so this sits between "beats it" and "tricks", weighted as the scoring weights them.
	- `Matchpoints`: on each layout the lead scores 1 when it does better than the field's lead, ½ when the same,
	  0 when worse. An overtrick counts as much as a set, so a lead that never gives a trick away does well.

THE FIELD leads the best lead by tricks, the one with the most of them on average (`field_of`): what a double-dummy
defender would find, and the same reference `cost` is measured against. Every comparison is made on the SAME
layout, so the margins are paired: the noise of the layouts cancels, and two leads that differ on few layouts are
told apart with fewer of them.
*/

import "core:math"
import "core:slice"
import "core:strings"

import "norn:norn"

Scoring :: enum {
	Beats,
	Imps,
	Matchpoints,
}

// The words a setting and `sim --scoring` take, and write.
SCORING_WORDS := [Scoring]string {
	.Beats       = "beats",
	.Imps        = "imps",
	.Matchpoints = "mp",
}

parse_scoring :: proc(word: string) -> (scoring: Scoring, ok: bool) {
	switch strings.to_lower(strings.trim_space(word), context.temp_allocator) {
	case "", "beats", "beats-it":
		return .Beats, true
	case "imps", "imp", "teams":
		return .Imps, true
	case "mp", "mps", "matchpoints", "pairs":
		return .Matchpoints, true
	}
	return .Beats, false
}

// The DEFENCE's duplicate score when it takes `tricks` against `c`, undoubled; `vulnerable` is the declaring side's.
defence_points :: proc(c: Lead_Contract, tricks: int, vulnerable: bool) -> int {
	contract := norn.Contract {
		level    = c.level,
		strain   = c.strain,
		declarer = c.declarer,
	}
	return -norn.contract_score(contract, norn.HAND_SIZE - tricks, vulnerable)
}

// The field's lead: the row with the most tricks on average, the earlier row on a tie. -1 with no rows.
field_of :: proc(rows: []Row) -> int {
	field := -1
	for row, r in rows {
		if field < 0 || row.tricks > rows[field].tricks + 1e-9 {
			field = r
		}
	}
	return field
}

// The row the field leads, by its mark (the rows are re-sorted after it is found). -1 with none.
field_row :: proc(rows: []Row) -> int {
	for row, r in rows {
		if row.field {
			return r
		}
	}
	return -1
}

/*
On one layout, a lead's IMPs and matchpoints against the field's lead, `mine` and `theirs` being their tricks.
*/
@(private = "file")
against_field :: proc(c: Lead_Contract, vulnerable: bool, mine, theirs: int) -> (imps: f64, mp: f64) {
	imps = f64(norn.imps(defence_points(c, mine, vulnerable) - defence_points(c, theirs, vulnerable)))
	mp = 1.0 if mine > theirs else 0.5 if mine == theirs else 0.0
	return
}

// What `scoring` ranks by, for row `row` on one layout: beating it (0/1), IMPs or matchpoints against the field.
@(private = "file")
measure_at :: proc(t: Tally, c: Lead_Contract, vulnerable: bool, scoring: Scoring, rows: []Row, r, field, layout: int) -> f64 {
	mine := row_tricks(t, rows[r], layout)
	switch scoring {
	case .Beats:
		return 1.0 if mine >= tricks_to_beat(c) else 0.0
	case .Imps:
		imps, _ := against_field(c, vulnerable, mine, row_tricks(t, rows[field], layout))
		return imps
	case .Matchpoints:
		_, mp := against_field(c, vulnerable, mine, row_tricks(t, rows[field], layout))
		return mp
	}
	return 0
}

// The 95% half-width on a mean of `n` values with sum `sum` and sum of squares `squares`.
@(private = "file")
mean_margin :: proc(sum, squares, n: f64) -> f64 {
	if n < 2 {
		return 0
	}
	mean := sum / n
	variance := max(0, (squares - n * mean * mean) / (n - 1))
	return 1.96 * math.sqrt(variance / n)
}

/*
The rows (`rank`'s) scored and ordered for `scoring`: each row's IMPs and matchpoints against the field's lead, its
`key` (what `scoring` ranks by), the rows sorted by it (then by tricks), and each row's PAIRED margin against the
new top row (`key_margin`: on the same layouts, how far the gap could be off). `vulnerable` is the declaring side's.
*/
score_rows :: proc(t: Tally, c: Lead_Contract, vulnerable: bool, scoring: Scoring, rows: []Row) {
	if len(rows) == 0 || t.layouts == 0 {
		return
	}
	n := f64(t.layouts)
	field := field_of(rows)
	for &row, r in rows {
		row.field = r == field
		imps, imps2, mps, mps2: f64
		for layout in 0 ..< t.layouts {
			imp, mp := against_field(c, vulnerable, row_tricks(t, row, layout), row_tricks(t, rows[field], layout))
			imps, imps2 = imps + imp, imps2 + imp * imp
			mps, mps2 = mps + mp, mps2 + mp * mp
		}
		row.imps, row.imp_margin = imps / n, mean_margin(imps, imps2, n)
		row.mp, row.mp_margin = mps / n, mean_margin(mps, mps2, n)
		switch scoring {
		case .Beats:
			row.key = row.beats
		case .Imps:
			row.key = row.imps
		case .Matchpoints:
			row.key = row.mp
		}
	}
	slice.stable_sort_by(rows, proc(a, b: Row) -> bool {
		if math.abs(a.key - b.key) > 1e-9 {
			return a.key > b.key
		}
		return a.tricks > b.tricks
	})
	field = field_row(rows)
	for &row, r in rows {
		sum, squares: f64
		for layout in 0 ..< t.layouts {
			gap := measure_at(t, c, vulnerable, scoring, rows, 0, field, layout) - measure_at(t, c, vulnerable, scoring, rows, r, field, layout)
			sum, squares = sum + gap, squares + gap * gap
		}
		row.key_margin = mean_margin(sum, squares, n)
	}
}
