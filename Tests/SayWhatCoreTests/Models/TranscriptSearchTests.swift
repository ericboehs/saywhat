import Foundation
import Testing
@testable import SayWhatCore

/// Find-in-transcript over the current meeting: hits are recomputed on every
/// query/transcript change, and the Find-bar selection wraps and sticks to the
/// hit it was on when the live transcript grows underneath it.
@Suite("Transcript search")
struct TranscriptSearchTests {
    @Test("finds every occurrence across entries, in transcript order")
    func findsAcrossEntries() {
        var state = TranscriptSearchState()

        state.update(query: "the", texts: ["the roadmap, then the budget", "neither", "The end"])

        #expect(state.hits == [
            TranscriptSearchHit(entry: 0, offsets: 0 ..< 3),
            TranscriptSearchHit(entry: 0, offsets: 13 ..< 16), // [the]n — substring find
            TranscriptSearchHit(entry: 0, offsets: 18 ..< 21),
            TranscriptSearchHit(entry: 1, offsets: 3 ..< 6), // nei[the]r
            TranscriptSearchHit(entry: 2, offsets: 0 ..< 3),
        ])
        #expect(state.current == 0)
    }

    @Test("matching is case- and diacritic-insensitive")
    func caseAndDiacriticInsensitive() {
        var state = TranscriptSearchState()

        state.update(query: "resume", texts: ["Send the Résumé over"])

        #expect(state.hits.count == 1)
        #expect(state.hits[0].offsets == 9 ..< 15)
    }

    @Test("an empty or whitespace-only query matches nothing")
    func emptyQueryMatchesNothing() {
        var state = TranscriptSearchState()
        state.update(query: "budget", texts: ["the budget"])

        state.update(query: "   ", texts: ["the budget"])

        #expect(state.hits.isEmpty)
        #expect(state.current == nil)
        #expect(state.currentHit == nil)
        #expect(state.positionLabel == nil)
    }

    @Test("next and previous wrap around the hit list")
    func nextPreviousWrap() {
        var state = TranscriptSearchState()
        state.update(query: "a", texts: ["a b a b a"])
        #expect(state.hits.count == 3)

        state.next()
        #expect(state.current == 1)
        state.next()
        #expect(state.current == 2)
        state.next()
        #expect(state.current == 0)
        state.previous()
        #expect(state.current == 2)
    }

    @Test("next and previous are inert with no hits")
    func navigationInertWhenEmpty() {
        var state = TranscriptSearchState()
        state.update(query: "missing", texts: ["nothing here"])

        state.next()
        state.previous()

        #expect(state.current == nil)
    }

    @Test("a changed query snaps the selection back to the first hit")
    func changedQuerySelectsFirst() {
        var state = TranscriptSearchState()
        state.update(query: "a", texts: ["a a a"])
        state.next()
        #expect(state.current == 1)

        state.update(query: "a ", texts: ["a a a"]) // trims to the same query
        #expect(state.current == 1)

        state.update(query: "aa", texts: ["a aa a"])
        #expect(state.current == 0)
    }

    @Test("the selection sticks to its hit while the live transcript grows")
    func selectionSurvivesAppend() {
        var state = TranscriptSearchState()
        state.update(query: "plan", texts: ["the plan", "no plan survives"])
        state.next()
        let selected = state.currentHit
        #expect(selected == TranscriptSearchHit(entry: 1, offsets: 3 ..< 7))

        // New speech lands: an earlier entry grows a new match ahead of the
        // selection, and a new entry appends below. The selected hit is now
        // third of four — but still the same hit.
        state.update(
            query: "plan",
            texts: ["the plan and the plan B", "no plan survives", "planning next"]
        )

        #expect(state.hits.count == 4)
        #expect(state.currentHit == selected)
        #expect(state.current == 2)
        #expect(state.positionLabel == "3 of 4")
    }

    @Test("a vanished hit clamps the selection instead of dropping it")
    func vanishedHitClamps() {
        var state = TranscriptSearchState()
        // The volatile tail is entry 2; its guess currently matches.
        state.update(query: "sure", texts: ["sure thing", "for sure", "sure—"])
        state.previous() // wrap to the last hit, in the volatile tail
        #expect(state.current == 2)

        // The recognizer revises the volatile guess and the tail's match vanishes.
        state.update(query: "sure", texts: ["sure thing", "for sure", "shore"])

        #expect(state.current == 1)
        #expect(state.currentHit == TranscriptSearchHit(entry: 1, offsets: 4 ..< 8))
    }

    @Test("hits for one entry come back as ranges for block highlighting")
    func offsetsForEntry() {
        var state = TranscriptSearchState()
        state.update(query: "so", texts: ["so, so far", "also"])

        #expect(state.offsets(inEntry: 0) == [0 ..< 2, 4 ..< 6])
        #expect(state.offsets(inEntry: 1) == [2 ..< 4])
        #expect(state.offsets(inEntry: 5).isEmpty)
    }

    @Test("adjacent occurrences don't overlap: the scan resumes past each match")
    func adjacentMatches() {
        var state = TranscriptSearchState()
        state.update(query: "aa", texts: ["aaaa"])

        #expect(state.hits == [
            TranscriptSearchHit(entry: 0, offsets: 0 ..< 2),
            TranscriptSearchHit(entry: 0, offsets: 2 ..< 4),
        ])
    }
}
