@preconcurrency import AVFoundation
import FluidAudio
import Foundation

private let modelID = "FluidInference/speaker-diarization-coreml"
private let modelRevision = "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
private let modelQuantization = "CoreML storage: segmentation/FBank/PLDA Float32, embedding Float16"

private struct Options {
    let audio: URL
    let modelsRoot: URL
    let output: URL

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard ["--audio", "--models-root", "--output"].contains(key), index + 1 < arguments.count else {
                throw HarnessError.usage
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard
            let audio = values["--audio"],
            let modelsRoot = values["--models-root"],
            let output = values["--output"]
        else { throw HarnessError.usage }
        self.audio = URL(fileURLWithPath: audio)
        self.modelsRoot = URL(fileURLWithPath: modelsRoot, isDirectory: true)
        self.output = URL(fileURLWithPath: output)
    }
}

private enum HarnessError: LocalizedError {
    case usage
    case outputExists(URL)
    case noSegments
    case invalidSegment

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: MaccheroniFluidDiarizationHarness --audio <wav> --models-root <directory> --output <json>"
        case .outputExists(let url):
            return "refusing to overwrite existing output: \(url.path)"
        case .noSegments:
            return "FluidAudio emitted an empty speaker timeline"
        case .invalidSegment:
            return "FluidAudio emitted a speaker segment outside the usable input timeline"
        }
    }
}

private struct SmokeOutput: Encodable {
    struct Model: Encodable {
        let hf_id: String
        let revision: String
        let quantization: String
    }
    struct Audio: Encodable {
        let duration_s: Double
    }
    struct Segment: Encodable {
        let speaker: String
        let start_s: Double
        let end_s: Double
        let raw_start_s: Double
        let raw_end_s: Double
        let quality_score: Double
    }
    struct Metrics: Encodable {
        let model_load_and_compile_s: Double
        let processing_s: Double
    }

    let model: Model
    let audio: Audio
    let segments: [Segment]
    let metrics: Metrics
}

private func audioDuration(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

@main
private struct MaccheroniFluidDiarizationHarness {
    static func main() async {
        do {
            let options = try Options(arguments: CommandLine.arguments)
            if FileManager.default.fileExists(atPath: options.output.path) {
                throw HarnessError.outputExists(options.output)
            }

            // This must precede loading. Any missing model fails instead of reaching HF.
            ModelHub.offlineMode = true
            let models = try await OfflineDiarizerModels.load(from: options.modelsRoot)
            let manager = OfflineDiarizerManager()
            manager.initialize(models: models)

            let processingStart = Date()
            let result = try await manager.process(options.audio)
            guard !result.segments.isEmpty else { throw HarnessError.noSegments }
            let duration = try audioDuration(options.audio)
            let segments: [SmokeOutput.Segment] = result.segments.map {
                let rawStart = Double($0.startTimeSeconds)
                let rawEnd = Double($0.endTimeSeconds)
                return .init(
                    speaker: $0.speakerId,
                    start_s: max(0, min(duration, rawStart)),
                    end_s: max(0, min(duration, rawEnd)),
                    raw_start_s: rawStart,
                    raw_end_s: rawEnd,
                    quality_score: Double($0.qualityScore)
                )
            }
            guard segments.allSatisfy({ $0.end_s > $0.start_s }) else {
                throw HarnessError.invalidSegment
            }

            let output = SmokeOutput(
                model: .init(hf_id: modelID, revision: modelRevision, quantization: modelQuantization),
                audio: .init(duration_s: duration),
                segments: segments,
                metrics: .init(
                    model_load_and_compile_s: models.compilationDuration,
                    processing_s: Date().timeIntervalSince(processingStart)
                )
            )
            let data = try JSONEncoder.pretty.encode(output)
            try FileManager.default.createDirectory(
                at: options.output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: options.output, options: .withoutOverwriting)
            print("wrote \(options.output.path): \(output.segments.count) speaker segments")
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
