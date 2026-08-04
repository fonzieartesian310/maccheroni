import Foundation
import MaccheroniCore
import Testing
@testable import MaccheroniApp

struct TranscriptionProgressTests {
    @Test
    func stageTransitionFreezesPriorDurationAndAdvancesCurrentDuration() {
        var accumulator = RunProgressAccumulator()

        #expect(accumulator.observe(stage: .preparing, atElapsedS: 0) == [.preparing: 0])
        #expect(accumulator.observe(stage: .preprocessing, atElapsedS: 2) == [
            .preparing: 2,
            .preprocessing: 0,
        ])
        #expect(accumulator.observe(stage: .preprocessing, atElapsedS: 5) == [
            .preparing: 2,
            .preprocessing: 3,
        ])
        #expect(accumulator.observe(stage: .asr, atElapsedS: 9) == [
            .preparing: 2,
            .preprocessing: 7,
            .asr: 0,
        ])
        #expect(accumulator.observe(stage: .asr, atElapsedS: 12) == [
            .preparing: 2,
            .preprocessing: 7,
            .asr: 3,
        ])
    }

    @Test
    func stageDurationsClampNegativeAndNonFiniteElapsedValues() {
        var accumulator = RunProgressAccumulator()

        _ = accumulator.observe(stage: .preprocessing, atElapsedS: -3)
        #expect(accumulator.observe(stage: .preprocessing, atElapsedS: .infinity)[.preprocessing] == 0)
        #expect(accumulator.observe(stage: .preprocessing, atElapsedS: .nan)[.preprocessing] == 0)
        #expect(accumulator.observe(stage: .preprocessing, atElapsedS: 4)[.preprocessing] == 4)
        #expect(accumulator.observe(stage: .preprocessing, atElapsedS: 2)[.preprocessing] == 4)
        #expect(accumulator.observe(stage: .preprocessing, atElapsedS: 5)[.preprocessing] == 5)
    }

    @Test
    func modelProjectionMatchesCurrentPipelineStage() {
        #expect(PostprocessChoice.codex.requestedModelID == "gpt-5.6-sol")
        #expect(PostprocessChoice.local.requestedModelID == "mlx-community/gemma-4-12B-it-qat-4bit")
        #expect(PostprocessChoice.none.requestedModelID == nil)

        let models = [
            ModelDescriptor(role: .vad, hfModelID: "fixture/vad", revision: "a", quantization: "int8"),
            ModelDescriptor(role: .diarization, hfModelID: "fixture/diarization", revision: "b", quantization: "int8"),
            ModelDescriptor(role: .asr, hfModelID: "fixture/asr", revision: "c", quantization: "int8"),
        ]
        let postprocess = ManifestPostprocess(
            backend: BackendDescriptor(name: "fixture", version: "1"),
            modelID: "fixture/postprocess"
        )

        #expect(RunProgressSnapshot.modelID(for: .preprocessing, models: models, postprocess: postprocess) == "fixture/vad")
        #expect(RunProgressSnapshot.modelID(for: .diarization, models: models, postprocess: postprocess) == "fixture/diarization")
        #expect(RunProgressSnapshot.modelID(for: .asr, models: models, postprocess: postprocess) == "fixture/asr")
        #expect(RunProgressSnapshot.modelID(for: .postprocess, models: models, postprocess: postprocess) == "fixture/postprocess")
        #expect(RunProgressSnapshot.modelID(
            for: .postprocess,
            models: models,
            postprocess: nil,
            requestedPostprocessModelID: "fixture/requested-postprocess"
        ) == "fixture/requested-postprocess")
        #expect(RunProgressSnapshot.modelID(
            for: .postprocess,
            models: models,
            postprocess: postprocess,
            requestedPostprocessModelID: "fixture/requested-postprocess"
        ) == "fixture/postprocess")

        for stage in [PipelineStage.preparing, .merge, .complete, .cancelled, .failed] {
            #expect(RunProgressSnapshot.modelID(for: stage, models: models, postprocess: postprocess) == nil)
        }
    }

    @Test
    func requestedPostprocessModelStaysProvisionalUntilTheManifestConfirmsIt() {
        let models = [
            ModelDescriptor(role: .vad, hfModelID: "fixture/vad", revision: "a", quantization: "int8"),
            ModelDescriptor(role: .diarization, hfModelID: "fixture/diarization", revision: "b", quantization: "int8"),
            ModelDescriptor(role: .asr, hfModelID: "fixture/asr", revision: "c", quantization: "int8"),
        ]
        let postprocess = ManifestPostprocess(
            backend: BackendDescriptor(name: "fixture", version: "1"),
            modelID: "fixture/postprocess"
        )

        let requested = RunProgressSnapshot.modelProjection(
            for: .postprocess,
            models: models,
            postprocess: nil,
            requestedPostprocessModelID: "fixture/requested-postprocess"
        )
        #expect(requested == RunProgressSnapshot.ModelProjection(
            modelID: "fixture/requested-postprocess",
            isProvisional: true
        ))

        let confirmed = RunProgressSnapshot.modelProjection(
            for: .postprocess,
            models: models,
            postprocess: postprocess,
            requestedPostprocessModelID: "fixture/requested-postprocess"
        )
        #expect(confirmed == RunProgressSnapshot.ModelProjection(
            modelID: "fixture/postprocess",
            isProvisional: false
        ))

        #expect(RunProgressSnapshot.modelProjection(
            for: .postprocess,
            models: models,
            postprocess: nil
        ) == RunProgressSnapshot.ModelProjection(modelID: nil, isProvisional: false))
        #expect(RunProgressSnapshot.modelProjection(
            for: .asr,
            models: models,
            postprocess: nil,
            requestedPostprocessModelID: "fixture/requested-postprocess"
        ) == RunProgressSnapshot.ModelProjection(modelID: "fixture/asr", isProvisional: false))

        for stage in [PipelineStage.preparing, .merge, .complete, .cancelled, .failed] {
            #expect(RunProgressSnapshot.modelProjection(
                for: stage,
                models: models,
                postprocess: postprocess,
                requestedPostprocessModelID: "fixture/requested-postprocess"
            ) == .unavailable)
        }
    }

    @Test
    func provisionalModelUsesThePlannedLabelAndConfirmedModelUsesTheCurrentLabel() {
        func snapshot(provisional: Bool) -> RunProgressSnapshot {
            RunProgressSnapshot(
                stage: .postprocess,
                completedChunks: 0,
                plannedChunks: 0,
                elapsedS: 0,
                modelID: "fixture/postprocess",
                modelIDIsProvisional: provisional,
                message: nil,
                runURL: nil
            )
        }

        let planned = snapshot(provisional: true)
        let current = snapshot(provisional: false)

        #expect(String(localized: planned.modelLabel(locale: Locale(identifier: "en"))) == "Planned Model")
        #expect(String(localized: current.modelLabel(locale: Locale(identifier: "en"))) == "Current Model")
        #expect(String(localized: planned.modelLabel(locale: Locale(identifier: "ko"))) == "예정 모델")
        #expect(String(localized: current.modelLabel(locale: Locale(identifier: "ko"))) == "현재 모델")
        #expect(String(localized: planned.modelLabel(locale: Locale(identifier: "it"))) == "Modello previsto")
        #expect(String(localized: current.modelLabel(locale: Locale(identifier: "it"))) == "Modello attuale")
    }
}
