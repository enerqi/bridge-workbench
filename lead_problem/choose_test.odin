#+build !js
package lead_problem

import "core:strings"
import "core:testing"
import "norn:norn"
import "../par_caption"

// `KJ32.A54.Q987.T3`: a hand from its dotted form, spades first.
@(private = "file")
hand_of :: proc(text: string) -> (hand: norn.Hand_Summary) {
	suits := [4]norn.Suit{.Spades, .Hearts, .Diamonds, .Clubs}
	for part, i in strings.split(text, ".", context.temp_allocator) {
		for ch in part {
			for r in norn.Rank {
				if norn.rank_char(r) == ch {
					hand.suits[suits[i]] += {r}
				}
			}
		}
	}
	return
}

/*
THE STRAIN RULES, each deciding one pair of hands: a 9-card major fit plays the major even with every suit stopped;
an 8-card one too; ten clubs with a singleton play clubs; every suit stopped and no major fit plays notrump; a
heart hole and a 5-2 spade fit plays spades; a heart hole and no major fit plays the longer minor; ten clubs
with no shortage and every suit stopped play notrump.
*/
@(test)
test_each_strain_rule_decides :: proc(t: ^testing.T) {
	cases := []struct {
		a, b: string,
		want: norn.Contract_Strain,
		why:  string,
	} {
		{"AQ532.K2.A32.K32", "KJ64.A43.K54.Q54", .Spades, "a 9-card spade fit, every suit stopped"},
		{"A432.K32.A32.K32", "KQ65.A54.K54.Q54", .Spades, "an 8-card spade fit"},
		{"AK32.K654.A2.32", "QJ54.AQ32.K3.A54", .Spades, "two 8-card major fits: spades"},
		{"A2.K32.32.AKJ432", "K43.54.A54.QT9876", .NoTrumps, "ten clubs, no shortage, every suit stopped"},
		{"A.K32.432.AKJ432", "K432.54.A5.QT987", .Clubs, "ten clubs and a singleton spade"},
		{"A32.K32.A32.K432", "K54.A54.K54.Q765", .NoTrumps, "every suit stopped, no major fit"},
		{"AK532.32.A32.K32", "Q4.654.KQ54.A654", .Spades, "a heart hole and a 5-2 spade fit"},
		{"AK5.32.AQ32.K432", "Q43.654.KJ54.A65", .Diamonds, "a heart hole, no major fit: the longer minor"},
	}
	for c in cases {
		got := choose_strain(hand_of(c.a), hand_of(c.b))
		testing.expectf(t, got == c.want, "%s (%s %s): %v", c.why, c.a, c.b, got)
	}
}

@(test)
test_a_stopper_is_a_kx_qxx_or_jxxx :: proc(t: ^testing.T) {
	none := hand_of("...")
	cases := []struct {
		hand: string,
		want: bool,
	} {
		{"A...", true},
		{"K2...", true},
		{"K...", false},
		{"Q32...", true},
		{"Q2...", false},
		{"J432...", true},
		{"J32...", false},
		{"T9876...", false},
	}
	for c in cases {
		testing.expectf(t, stopped(hand_of(c.hand), none, .Spades) == c.want, "%s", c.hand)
	}
}

/*
THE LEVEL: game is reached at the table's lower count and is a ceiling; partscores below it; a slam needs its
count AND the controls. The hands are built so their combined OPC lands where each case needs it, and the case
checks the count it relies on, so a change to norn's OPC shows here as a count, not a mystery.
*/
@(test)
test_the_level_follows_the_opc_table_with_game_a_ceiling :: proc(t: ^testing.T) {
	cases := []struct {
		a, b: string,
		want: Bid,
	} {
		// 25 hcp, flat, every suit stopped: game in notrump.
		{"A32.K32.A32.K432", "K54.A54.K54.Q765", {3, .NoTrumps}},
		// A weak 4-4 spade fit: a partscore.
		{"A432.KJ2.KQ2.K32", "K765.Q54.J54.765", {2, .Spades}},
		// Strong, with a spade fit, one ace missing and every suit controlled: a small slam, not the grand.
		{"AKQ32.A2.AK2.K32", "J654.432.Q543.54", {6, .Spades}},
		// The same strength missing two aces' worth of controls in clubs: the game.
		{"AKQ32.A2.KQ2.Q32", "J654.K43.AJ43.J4", {4, .Spades}},
	}
	for c in cases {
		a, b := hand_of(c.a), hand_of(c.b)
		got := choose_bid(a, b)
		trump: Maybe(norn.Suit)
		if c.want.strain == .Spades {
			trump = norn.Suit.Spades
		}
		testing.expectf(
			t,
			got == c.want,
			"%s %s: %v, want %v (opc %.1f)",
			c.a,
			c.b,
			got,
			c.want,
			norn.combined_opc(a, b, trump),
		)
	}
}

@(test)
test_slam_controls :: proc(t: ^testing.T) {
	a, b := hand_of("AKQ32.A2.AK2.K32"), hand_of("J654.K43.Q543.A4")
	testing.expect(t, slam_controls(a, b, .Spades, false), "every suit controlled, all four aces")
	testing.expect(t, slam_controls(a, b, .Spades, true), "and the trump king and queen")
	// Clubs with neither the ace nor the king, and no shortage: a hole.
	testing.expect(t, !slam_controls(hand_of("AKQ32.A2.AK2.432"), hand_of("J654.K43.Q543.Q5"), .Spades, false), "a club hole")
	// The same holding with a singleton club opposite is controlled, in spades and not in notrump.
	c, d := hand_of("AKQ32.A2.AK2.432"), hand_of("J6543.K43.Q543.5")
	testing.expect(t, slam_controls(c, d, .Spades, false), "a singleton controls a suit")
	testing.expect(t, !slam_controls(c, d, .NoTrumps, false), "not in notrump")
	// Two aces missing: no small slam.
	testing.expect(t, !slam_controls(hand_of("KQJ32.KQ.AK2.K32"), hand_of("T654.J43.Q543.Q4"), .Spades, false), "two aces missing")
}

@(test)
test_the_declarer_has_the_longer_trumps :: proc(t: ^testing.T) {
	deal: norn.Deal_Summary
	deal[.North] = hand_of("A432.K32.A32.K32")
	deal[.South] = hand_of("KQ765.A54.K4.Q54")
	testing.expect_value(t, choose_declarer(deal, {.North, .South}, .Spades), norn.Seat.South)
	// In notrump the stronger hand (North's 14 against South's 14: equal, so the first named).
	testing.expect_value(t, choose_declarer(deal, {.North, .South}, .NoTrumps), norn.Seat.North)
	deal[.South] = hand_of("KQ765.A54.K4.AQ5")
	testing.expect_value(t, choose_declarer(deal, {.North, .South}, .NoTrumps), norn.Seat.South)
}

// The choice's counts, its par comparison, and the report line.
@(test)
test_the_choice_counts_and_compares_with_par :: proc(t: ^testing.T) {
	choice: Choice
	a, b := hand_of("A432.K32.A32.K32"), hand_of("KQ65.A54.K54.Q54") // 4♠
	choice_add(&choice, a, b)
	choice_add(&choice, a, b)
	choice_add(&choice, hand_of("A32.K32.A32.K432"), hand_of("K54.A54.K54.Q765")) // 3NT
	bid, count := most_common(choice.counts)
	testing.expect_value(t, bid, Bid{4, .Spades})
	testing.expect_value(t, count, 2)

	agree: par_caption.Par
	agree.number = 2
	agree.contracts[0] = {level = 3, denom = .NT, seats = .NS}
	agree.contracts[1] = {level = 4, denom = .Spades, seats = .S}
	choice_add_par(&choice, agree, bid, .South)
	other: par_caption.Par
	other.number = 1
	other.contracts[0] = {level = 4, denom = .Hearts, seats = .EW}
	choice_add_par(&choice, other, bid, .South)
	sacrifice: par_caption.Par
	sacrifice.number = 1
	sacrifice.contracts[0] = {under_tricks = 2, level = 5, denom = .Clubs, seats = .NS}
	choice_add_par(&choice, sacrifice, bid, .South)
	testing.expect_value(t, choice.par_agrees, 1)
	testing.expect_value(t, choice.par_other, 2)
	testing.expect_value(t, choice.par_counts[3][.NoTrumps], 1)

	b2 := strings.builder_make(context.temp_allocator)
	write_choice(&b2, choice, .South)
	testing.expect_value(
		t,
		strings.to_string(b2),
		"The contract, chosen by simple bidding rules from North-South's cards on each layout: 4♠ 67%, 3NT 33%\nPar agrees on 33% of the layouts; par itself: 3NT 33%, the other side's or a sacrifice 67%\n",
	)
}

@(test)
test_a_lead_request_reads_a_seat_a_side_or_a_contract :: proc(t: ^testing.T) {
	r, bad := parse_lead_request("south")
	testing.expect(t, bad == "" && r.one_seat && r.seats[0] == .South && r.contract == nil, "a seat")
	r, bad = parse_lead_request("North-South")
	testing.expect(t, bad == "" && !r.one_seat && r.seats == {.North, .South}, "a side")
	r, bad = parse_lead_request("4S:west")
	c, given := r.contract.?
	testing.expect(t, bad == "" && given && c == Lead_Contract{4, .Spades, .West}, "a contract")
	_, bad = parse_lead_request("somewhere")
	testing.expect(t, bad != "", "nonsense is refused")
}
