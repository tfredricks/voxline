import Testing
@testable import voxline

@Suite struct LiveTranscriptAssemblerTests {

    private typealias Track = MeetingRecorder.Track

    @Test func growing_stable_text_becomes_one_line() {
        var assembler = LiveTranscriptAssembler()
        let transcript = assembler.apply(TranscriptPartial(stable: " Hello there."), track: .mic)
        #expect(transcript.lines == [LiveLine(id: 0, track: .mic, text: "Hello there.")])
        #expect(transcript.volatile.isEmpty)
    }

    @Test func same_track_growth_joins_the_newest_line() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.apply(TranscriptPartial(stable: "Hello there."), track: .mic)
        let transcript = assembler.apply(TranscriptPartial(stable: "Hello there. How are you?"), track: .mic)
        #expect(transcript.lines == [LiveLine(id: 0, track: .mic, text: "Hello there. How are you?")])
    }

    @Test func other_track_growth_starts_a_new_line() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.apply(TranscriptPartial(stable: "Hello."), track: .mic)
        _ = assembler.apply(TranscriptPartial(stable: "Hi."), track: .system)
        let transcript = assembler.apply(TranscriptPartial(stable: "Hello. Ready?"), track: .mic)
        #expect(transcript.lines == [
            LiveLine(id: 0, track: .mic, text: "Hello."),
            LiveLine(id: 1, track: .system, text: "Hi."),
            LiveLine(id: 2, track: .mic, text: "Ready?"),
        ])
    }

    @Test func volatile_is_kept_per_track_and_cleared_when_it_settles() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.apply(TranscriptPartial(stable: "", volatile: "I thi"), track: .mic)
        let both = assembler.apply(TranscriptPartial(stable: "", volatile: "So "), track: .system)
        #expect(both.volatile == [.mic: "I thi", .system: "So"])
        #expect(both.lines.isEmpty)
        let settled = assembler.apply(TranscriptPartial(stable: "I think so.", volatile: ""), track: .mic)
        #expect(settled.volatile == [.system: "So"])
        #expect(settled.lines == [LiveLine(id: 0, track: .mic, text: "I think so.")])
    }

    @Test func non_extending_stable_text_is_a_fresh_segment() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.apply(TranscriptPartial(stable: "First session."), track: .mic)
        _ = assembler.apply(TranscriptPartial(stable: "Reply."), track: .system)
        let transcript = assembler.apply(TranscriptPartial(stable: "New session."), track: .mic)
        #expect(transcript.lines.map(\.text) == ["First session.", "Reply.", "New session."])
    }

    @Test func blank_growth_is_ignored() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.apply(TranscriptPartial(stable: "Hello."), track: .mic)
        let transcript = assembler.apply(TranscriptPartial(stable: "Hello.  \n"), track: .mic)
        #expect(transcript.lines == [LiveLine(id: 0, track: .mic, text: "Hello.")])
        let empty = LiveTranscriptAssembler().transcript
        #expect(empty == LiveTranscript())
    }

    @Test func oldest_line_is_dropped_past_the_cap_and_ids_stay_monotonic() {
        var assembler = LiveTranscriptAssembler(maxLines: 3)
        var stable: [Track: String] = [.mic: "", .system: ""]
        for i in 0..<4 {
            let track: Track = i % 2 == 0 ? .mic : .system
            stable[track]! += " line \(i)."
            _ = assembler.apply(TranscriptPartial(stable: stable[track]!), track: track)
        }
        let transcript = assembler.transcript
        #expect(transcript.lines.map(\.id) == [1, 2, 3])
        #expect(transcript.lines.map(\.text) == ["line 1.", "line 2.", "line 3."])
    }

    @Test func default_cap_is_fifty() {
        #expect(LiveTranscriptAssembler.defaultMaxLines == 50)
        #expect(LiveTranscriptAssembler().maxLines == 50)
    }

    @Test func track_labels() {
        #expect(Track.mic.liveLabel == "Me")
        #expect(Track.system.liveLabel == "Them")
    }
}
