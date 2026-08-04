import AudioCommon
import CryptoKit
import Darwin
import Foundation
import MossTranscribe

private let modelID = "aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8"
private let modelRevision = "90aa65287111a327db98eb83e325bd5332945edd"
private let modelQuantization = "int8-decoder+fp16-audio-vq-kv"
private let contextHardCap = 131_072
private let defaultMaxTokens = 5_120

private struct Options {
    let audio: URL
    let modelDirectory: URL
    let glossary: URL?
    let output: URL
    let maxTokens: Int
    let language: String

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard [
                "--audio", "--model-dir", "--glossary", "--output",
                "--max-tokens", "--language",
            ].contains(key), index + 1 < arguments.count else {
                throw HarnessError.usage
            }
            guard values[key] == nil else { throw HarnessError.usage }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard
            let audio = values["--audio"],
            let modelDirectory = values["--model-dir"],
            let output = values["--output"]
        else { throw HarnessError.usage }
        let maxTokens = try Self.parseMaxTokens(values["--max-tokens"])
        let language = try Self.parseLanguage(values["--language"])
        self.audio = URL(fileURLWithPath: audio)
        self.modelDirectory = URL(fileURLWithPath: modelDirectory, isDirectory: true)
        self.glossary = values["--glossary"].map { URL(fileURLWithPath: $0) }
        self.output = URL(fileURLWithPath: output)
        self.maxTokens = maxTokens
        self.language = language
    }

    private static func parseMaxTokens(_ value: String?) throws -> Int {
        guard let value else { return defaultMaxTokens }
        guard let parsed = Int(value), parsed > 0, parsed <= contextHardCap else {
            throw HarnessError.invalidMaxTokens(value)
        }
        return parsed
    }

    private static func parseLanguage(_ value: String?) throws -> String {
        let normalized = (value ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty,
              normalized.count <= 64,
              normalized.unicodeScalars.allSatisfy({
                  $0.properties.isAlphabetic || $0.value == 45
              })
        else { throw HarnessError.invalidLanguage(value ?? "") }
        return normalized
    }
}

private enum HarnessError: LocalizedError {
    case usage
    case outputExists(URL)
    case invalidGlossary(URL, String)
    case invalidMaxTokens(String)
    case invalidLanguage(String)
    case emptyTranscript
    case noSegments

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: MaccheroniMossHarness --audio <wav> --model-dir <directory> [--glossary <txt>] [--max-tokens <1...131072>] [--language <auto|BCP-47>] --output <json>"
        case .outputExists(let url):
            return "refusing to overwrite existing output: \(url.path)"
        case .invalidGlossary(let url, let reason):
            return "invalid glossary \(url.path): \(reason)"
        case .invalidMaxTokens(let value):
            return "invalid --max-tokens \(value); expected 1...\(contextHardCap)"
        case .invalidLanguage(let value):
            return "invalid --language \(value); expected auto or a BCP-47 language tag"
        case .emptyTranscript:
            return "MOSS emitted an empty transcript after endOfSequence"
        case .noSegments:
            return "MOSS emitted no inspectable segments after endOfSequence"
        }
    }
}

private struct HarnessOutput: Encodable {
    struct Model: Encodable {
        let hf_id: String
        let revision: String
        let quantization: String
    }
    struct Glossary: Encodable {
        let raw_sha256: String?
        let item_count: Int
        let applied: Bool
        let instruction_sha256: String
    }
    struct Language: Encodable {
        let requested: String
        let instruction_sha256: String
        let prompt_guidance_applied: Bool
    }
    struct Audio: Encodable {
        let duration_s: Double
    }
    struct Segment: Encodable {
        let start_s: Double
        let end_s: Double
        let speaker: String
        let text: String
    }
    struct Metrics: Encodable {
        let preprocessing_s: Double
        let audio_encoder_s: Double
        let decoder_prefill_s: Double
        let token_decode_s: Double
        let total_s: Double
        let model_load_s: Double
        let audio_duration_s: Double
        let prompt_tokens: Int
        let generated_tokens: Int
        let max_tokens: Int
        let context_hard_cap_tokens: Int
        let peak_rss_bytes: Int64
        let stop_reason: String
    }
    struct Failure: Encodable {
        let code: String
        let message: String
        let prompt_tokens: Int?
        let context_hard_cap_tokens: Int?
    }

    let status: String
    let model: Model
    let glossary: Glossary
    let language: Language
    let audio: Audio
    let raw_text: String
    let text: String
    let segments: [Segment]
    let metrics: Metrics
    let failure: Failure?
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func peakRSSBytes() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    // Darwin reports ru_maxrss in bytes. This is host RSS, not MLX allocation.
    return Int64(usage.ru_maxrss)
}

private func readGlossary(_ url: URL) throws -> (raw: Data, items: [String]) {
    let raw = try Data(contentsOf: url)
    guard var text = String(data: raw, encoding: .utf8) else {
        throw HarnessError.invalidGlossary(url, "not valid UTF-8")
    }
    if text.unicodeScalars.first?.value == 0xFEFF {
        text.removeFirst()
    }
    var seen = Set<String>()
    var items: [String] = []
    for line in text
        .split(whereSeparator: \.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    {
        if line.isEmpty || line.hasPrefix("#") { continue }
        let item = line.precomposedStringWithCanonicalMapping
        if item.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw HarnessError.invalidGlossary(url, "control character in entry")
        }
        guard (1...256).contains(item.unicodeScalars.count) else {
            throw HarnessError.invalidGlossary(url, "entry has \(item.unicodeScalars.count) Unicode scalars; expected 1...256")
        }
        if seen.insert(item).inserted { items.append(item) }
    }
    guard !items.isEmpty else { throw HarnessError.invalidGlossary(url, "no usable entries") }
    return (raw, items)
}

private func makeInstruction(glossary: [String], language: String) -> String {
    var instruction = MossMLXModel.defaultInstruction
        + " Preserve the transcript strictly according to acoustic evidence."
    if language != "auto" {
        let baseLanguage = language.lowercased().split(
            separator: "-",
            maxSplits: 1
        )
            .first.map(String.init) ?? language
        let displayName = [
            "de": "German",
            "en": "English",
            "es": "Spanish",
            "fr": "French",
            "it": "Italian",
            "ja": "Japanese",
            "ko": "Korean",
            "pt": "Portuguese",
            "ru": "Russian",
            "zh": "Chinese",
        ][baseLanguage] ?? "the language identified by BCP-47 tag '\(language)'"
        instruction += " Language: \(displayName)."
    }
    if !glossary.isEmpty {
        instruction += " The following terms are candidate spellings only; emit a term only when the audio supports it: \(glossary.joined(separator: ", "))."
    }
    return instruction
}

private func writeCreateOnly(_ output: HarnessOutput, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONEncoder.pretty.encode(output)
    try data.write(to: url, options: .withoutOverwriting)
}

private func exitStatus(for stopReason: MossGenerationStopReason) -> Int {
    switch stopReason {
    case .endOfSequence: return 0
    case .maximumTokens: return 75
    case .contextLimit: return 76
    }
}

@main
private struct MaccheroniMossHarness {
    static func main() async {
        do {
            let status = try await run(options: Options(arguments: CommandLine.arguments))
            exit(Int32(status))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(options: Options) async throws -> Int {
        if FileManager.default.fileExists(atPath: options.output.path) {
            throw HarnessError.outputExists(options.output)
        }

        let glossary = try options.glossary.map(readGlossary)
        let instruction = makeInstruction(
            glossary: glossary?.items ?? [],
            language: options.language
        )
        let instructionSHA = sha256(Data(instruction.utf8))
        let audio = try AudioFileLoader.load(
            url: options.audio,
            targetSampleRate: MossMLXModel.inputSampleRate
        )
        let audioDuration = Double(audio.count) / Double(MossMLXModel.inputSampleRate)
        let modelLoadStarted = CFAbsoluteTimeGetCurrent()
        let model = try await MossMLXModel.fromDirectory(
            options.modelDirectory,
            modelId: modelID
        )
        let modelLoadSeconds = CFAbsoluteTimeGetCurrent() - modelLoadStarted
        var decoding = MossMLXDecodingOptions(maxTokens: options.maxTokens)
        decoding.kvCachePrecision = .float16

        do {
            let transcription = try model.transcribeDetailed(
                audio: audio,
                sampleRate: MossMLXModel.inputSampleRate,
                options: decoding,
                instruction: instruction
            )
            let stopReason = transcription.metrics.stopReason
            let eosValidationError: HarnessError? = {
                guard stopReason == .endOfSequence else { return nil }
                if transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .emptyTranscript
                }
                if transcription.segments.isEmpty { return .noSegments }
                return nil
            }()
            let output = HarnessOutput(
                status: eosValidationError != nil ? "failed" : (
                    stopReason == .endOfSequence ? "complete" : "incomplete"
                ),
                model: .init(hf_id: modelID, revision: modelRevision, quantization: modelQuantization),
                glossary: .init(
                    raw_sha256: glossary.map { sha256($0.raw) },
                    item_count: glossary?.items.count ?? 0,
                    applied: glossary != nil,
                    instruction_sha256: instructionSHA
                ),
                language: .init(
                    requested: options.language,
                    instruction_sha256: instructionSHA,
                    prompt_guidance_applied: options.language != "auto"
                ),
                audio: .init(duration_s: audioDuration),
                raw_text: transcription.rawText,
                text: transcription.text,
                segments: transcription.segments.map {
                    .init(start_s: $0.startTime, end_s: $0.endTime, speaker: $0.speaker, text: $0.text)
                },
                metrics: .init(
                    preprocessing_s: transcription.metrics.preprocessingSeconds,
                    audio_encoder_s: transcription.metrics.audioEncoderSeconds,
                    decoder_prefill_s: transcription.metrics.decoderPrefillSeconds,
                    token_decode_s: transcription.metrics.tokenDecodeSeconds,
                    total_s: transcription.metrics.totalSeconds,
                    model_load_s: modelLoadSeconds,
                    audio_duration_s: transcription.metrics.audioDurationSeconds,
                    prompt_tokens: transcription.metrics.promptTokens,
                    generated_tokens: transcription.metrics.generatedTokens,
                    max_tokens: options.maxTokens,
                    context_hard_cap_tokens: contextHardCap,
                    peak_rss_bytes: peakRSSBytes(),
                    stop_reason: stopReason.rawValue
                ),
                failure: eosValidationError.map {
                    .init(
                        code: "invalid_eos_output",
                        message: $0.localizedDescription,
                        prompt_tokens: transcription.metrics.promptTokens,
                        context_hard_cap_tokens: contextHardCap
                    )
                }
            )
            try writeCreateOnly(output, to: options.output)

            let status = exitStatus(for: stopReason)
            guard status == 0 else {
                FileHandle.standardError.write(Data("error: MOSS stopped at \(stopReason.rawValue); output is incomplete\n".utf8))
                return status
            }
            if let eosValidationError {
                FileHandle.standardError.write(Data("error: \(eosValidationError.localizedDescription)\n".utf8))
                return 1
            }
            print("wrote \(options.output.path): \(output.segments.count) segments, stop=\(output.metrics.stop_reason)")
            return 0
        } catch let MossTranscribeError.promptTooLong(actual, maximum) {
            let output = HarnessOutput(
                status: "incomplete",
                model: .init(hf_id: modelID, revision: modelRevision, quantization: modelQuantization),
                glossary: .init(raw_sha256: glossary.map { sha256($0.raw) }, item_count: glossary?.items.count ?? 0, applied: glossary != nil, instruction_sha256: instructionSHA),
                language: .init(requested: options.language, instruction_sha256: instructionSHA, prompt_guidance_applied: options.language != "auto"),
                audio: .init(duration_s: audioDuration),
                raw_text: "",
                text: "",
                segments: [],
                metrics: .init(preprocessing_s: 0, audio_encoder_s: 0, decoder_prefill_s: 0, token_decode_s: 0, total_s: 0, model_load_s: modelLoadSeconds, audio_duration_s: audioDuration, prompt_tokens: actual, generated_tokens: 0, max_tokens: options.maxTokens, context_hard_cap_tokens: contextHardCap, peak_rss_bytes: peakRSSBytes(), stop_reason: MossGenerationStopReason.contextLimit.rawValue),
                failure: .init(code: "prompt_too_long", message: "MOSS prompt has \(actual) tokens, exceeding the model context limit of \(maximum)", prompt_tokens: actual, context_hard_cap_tokens: maximum)
            )
            try writeCreateOnly(output, to: options.output)
            FileHandle.standardError.write(Data("error: MOSS stopped at contextLimit; prompt has \(actual) tokens\n".utf8))
            return 76
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
