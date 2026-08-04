import Foundation
import Testing
@testable import MaccheroniCore
@testable import MaccheroniMerge

@Suite struct MaccheroniMergeTests {
    private let source = SourceAudio(
        fileName: "synthetic.wav",
        sha256: String(repeating: "a", count: 64),
        durationS: 20
    )

    private func hypothesis(
        _ source: String,
        _ segments: [Segment]
    ) -> ASRHypothesis {
        ASRHypothesis(source: source, segments: segments)
    }

    @Test func keepsGlobalSpeakerIdentityAcrossChunkBoundaryAndUsesDominantOverlap() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 12),
            TimelineSegment(speaker: "SPEAKER_01", startS: 12, endS: 20),
        ])
        let chunks = [
            ChunkTranscript(
                index: 0,
                startS: 0,
                endS: 10,
                primary: hypothesis("primary", [
                    Segment(speaker: "UNASSIGNED", startS: 9, endS: 10, text: "before"),
                ])
            ),
            ChunkTranscript(
                index: 1,
                startS: 10,
                endS: 20,
                primary: hypothesis("primary", [
                    Segment(speaker: "UNASSIGNED", startS: 10, endS: 11, text: "after"),
                    Segment(speaker: "UNASSIGNED", startS: 11, endS: 14, text: "crossing"),
                ])
            ),
        ]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)

        #expect(result.segmentsDocument.segments.map(\.speaker) == [
            "SPEAKER_00", "SPEAKER_00", "SPEAKER_01",
        ])
        #expect(result.segmentsDocument.numSpeakers == 2)
        #expect(result.conflicts.isEmpty)
    }

    @Test func overlappingSpeechPreservesCandidatesAndDoesNotGuessSpeaker() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 4),
            TimelineSegment(speaker: "SPEAKER_01", startS: 1, endS: 3),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("primary", [
                Segment(speaker: "UNASSIGNED", startS: 1, endS: 3, text: "simultaneous"),
            ])
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let merged = try #require(result.segmentsDocument.segments.first)

        #expect(merged.speaker == "UNKNOWN")
        #expect(merged.flags == ["conflict", "uncertain"])
        #expect(result.conflicts.map(\.kind) == [.ambiguousSpeaker, .overlappingSpeech])
        #expect(result.conflicts.allSatisfy {
            $0.candidates == ["SPEAKER_00", "SPEAKER_01"]
        })
    }

    @Test func equalSequentialOverlapIsAnExplicitAmbiguousAssignment() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 1),
            TimelineSegment(speaker: "SPEAKER_01", startS: 1, endS: 2),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("primary", [
                Segment(speaker: "UNASSIGNED", startS: 0, endS: 2, text: "boundary"),
            ])
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)

        #expect(result.segmentsDocument.segments.first?.speaker == "UNKNOWN")
        #expect(result.segmentsDocument.segments.first?.flags == ["conflict", "uncertain"])
        #expect(result.conflicts.map(\.kind) == [.ambiguousSpeaker])
        #expect(result.segmentsDocument.numSpeakers == 0)
    }

    @Test func asrDisagreementFlagsPrimaryWithoutReplacingItsText() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 20),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("vibevoice", [
                Segment(
                    speaker: "UNASSIGNED",
                    startS: 2,
                    endS: 4,
                    text: "Maccheroni is ready."
                ),
            ]),
            comparisons: [hypothesis("qwen3", [
                Segment(
                    speaker: "UNASSIGNED",
                    startS: 2,
                    endS: 4,
                    text: "Maccheroni is not ready."
                ),
            ])]
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let merged = try #require(result.segmentsDocument.segments.first)
        let conflict = try #require(result.conflicts.first)
        let conflictsData = try JSONEncoder().encode(result.conflicts)
        let conflictsArray = try #require(
            JSONSerialization.jsonObject(with: conflictsData) as? [[String: Any]]
        )

        #expect(merged.text == "Maccheroni is ready.")
        #expect(merged.flags == ["conflict"])
        #expect(conflict.kind == .asrDisagreement)
        #expect(conflict.candidates == [
            "vibevoice: Maccheroni is ready.",
            "qwen3: Maccheroni is not ready.",
        ])
        #expect(conflictsArray.first?["segment_index"] as? Int == 0)
        #expect(conflictsArray.first?["kind"] as? String == "asr_disagreement")
    }

    @Test func caseAndPunctuationOnlyDifferencesAreNotASRConflicts() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 20),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("primary", [
                Segment(speaker: "UNASSIGNED", startS: 2, endS: 4, text: "Maccheroni READY!"),
            ]),
            comparisons: [hypothesis("verifier", [
                Segment(speaker: "UNASSIGNED", startS: 2, endS: 4, text: "maccheroni ready"),
            ])]
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)

        #expect(result.conflicts.isEmpty)
        #expect(result.segmentsDocument.segments.first?.flags == nil)
    }

    @Test func mossSpeakerEvidenceCannotOverrideTheGlobalTimeline() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_04", startS: 0, endS: 20),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("moss", [
                Segment(
                    speaker: "S01",
                    startS: 0,
                    endS: 1,
                    text: "Va bene.",
                    language: "it",
                    flags: ["backend_speaker_evidence"]
                ),
            ])
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let merged = try #require(result.segmentsDocument.segments.first)
        let encoded = try JSONEncoder().encode(result.segmentsDocument)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(merged.speaker == "SPEAKER_04")
        #expect(merged.flags == ["backend_speaker_evidence"])
        #expect(result.segmentsDocument.numSpeakers == 1)
        #expect(object["schema_version"] as? String == MaccheroniSchema.version)
        #expect(object["num_speakers"] as? Int == 1)
    }

    @Test func emptyTimelineProducesUnassignedSegmentsForDiarizationOff() throws {
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("primary", [
                Segment(speaker: "S01", startS: 0, endS: 1, text: "solo"),
            ])
        )]

        let result = try TimelineMerger().merge(
            chunks: chunks,
            timeline: Timeline(segments: []),
            source: source
        )

        #expect(result.segmentsDocument.segments.first?.speaker == "UNASSIGNED")
        #expect(result.segmentsDocument.numSpeakers == 0)
        #expect(result.conflicts.isEmpty)
    }

    @Test func rejectsSegmentsOutsideTheirChunkInsteadOfClampingTimestamps() throws {
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 5,
            primary: hypothesis("primary", [
                Segment(speaker: "UNASSIGNED", startS: 4, endS: 6, text: "outside"),
            ])
        )]

        #expect(throws: TimelineMergeError.invalidPrimarySegment(chunk: 0, segment: 0)) {
            _ = try TimelineMerger().merge(
                chunks: chunks,
                timeline: Timeline(segments: []),
                source: source
            )
        }
    }
}
