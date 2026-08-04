@preconcurrency import AVFoundation
@preconcurrency import CoreML
import CryptoKit
import Darwin
import FluidAudio
import Foundation

private let fluidAudioRevision = "5390df9752c8fc583596018360c5fd70d6fa6c75"
private let tdtModelID = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
private let tdtModelRevision = "aed02740059203c4a87495924f685de3722ae9ce"
private let tdtModelQuantization = "coreml-int8-mixed6-fp16"
private let ctcModelID = "FluidInference/parakeet-ctc-110m-coreml"
private let ctcModelRevision = "accdafd8cf8a2ff1cabe3c11e54416b405d409aa"
private let ctcModelQuantization = "coreml-fp16-mixed6-sparse"

private struct Options {
    let tdtModelDirectory: URL
    let ctcModelDirectory: URL
    let glossary: URL?
    let output: URL
    let items: [URL]

    init(arguments: [String]) throws {
        if arguments.dropFirst().contains("--help") || arguments.dropFirst().contains("-h") {
            throw HarnessError.help
        }

        var tdtModelDirectory: String?
        var ctcModelDirectory: String?
        var language: String?
        var glossary: String?
        var output: String?
        var items: [String] = []
        var index = 1

        while index < arguments.count {
            let flag = arguments[index]
            guard ["--tdt-model-dir", "--ctc-model-dir", "--language", "--glossary", "--output", "--item"].contains(flag), index + 1 < arguments.count else {
                throw HarnessError.usage
            }
            let value = arguments[index + 1]
            switch flag {
            case "--tdt-model-dir":
                guard tdtModelDirectory == nil else { throw HarnessError.usage }
                tdtModelDirectory = value
            case "--ctc-model-dir":
                guard ctcModelDirectory == nil else { throw HarnessError.usage }
                ctcModelDirectory = value
            case "--language":
                guard language == nil else { throw HarnessError.usage }
                guard value == "it" else { throw HarnessError.unsupportedLanguage(value) }
                language = value
            case "--glossary":
                guard glossary == nil else { throw HarnessError.usage }
                glossary = value
            case "--output":
                guard output == nil else { throw HarnessError.usage }
                output = value
            case "--item":
                items.append(value)
            default:
                throw HarnessError.usage
            }
            index += 2
        }

        guard
            let tdtModelDirectory,
            let ctcModelDirectory,
            let language,
            let output,
            !items.isEmpty
        else { throw HarnessError.usage }
        guard language == "it" else { throw HarnessError.usage }

        self.tdtModelDirectory = URL(fileURLWithPath: tdtModelDirectory, isDirectory: true)
        self.ctcModelDirectory = URL(fileURLWithPath: ctcModelDirectory, isDirectory: true)
        self.glossary = glossary.map(URL.init(fileURLWithPath:))
        self.output = URL(fileURLWithPath: output)
        self.items = items.map(URL.init(fileURLWithPath:))
    }
}

private enum HarnessError: LocalizedError {
    case help
    case usage
    case unsupportedLanguage(String)
    case outputExists(URL)
    case missingDirectory(URL)
    case invalidModelLeaf(URL, String)
    case missingFile(URL)
    case invalidGlossary(URL, String)
    case emptyTranscription(URL)
    case invalidTiming(URL, String)
    case durationMismatch(URL, input: Double, result: Double)
    case modelOrInputMutated(URL)
    case atomicWriteFailed(URL, Int32)

    var errorDescription: String? {
        switch self {
        case .help, .usage:
            return "usage: MaccheroniParakeetBenchmarkHarness --tdt-model-dir <parakeet-tdt-0.6b-v3-coreml leaf> --ctc-model-dir <parakeet-ctc-110m-coreml leaf> --language it [--glossary <canonical one-term-per-line txt>] --output <new json> --item <wav> [--item <wav> ...]"
        case .unsupportedLanguage(let language):
            return "only the fixed Italian language is supported; received: \(language)"
        case .outputExists(let url):
            return "refusing to overwrite existing output: \(url.path)"
        case .missingDirectory(let url):
            return "required model directory is missing or not a directory: \(url.path)"
        case .invalidModelLeaf(let url, let expected):
            return "model directory must be the exact \(expected) leaf: \(url.path)"
        case .missingFile(let url):
            return "required file is missing or not a regular file: \(url.path)"
        case .invalidGlossary(let url, let reason):
            return "invalid glossary \(url.path): \(reason)"
        case .emptyTranscription(let url):
            return "Parakeet emitted empty final text for: \(url.path)"
        case .invalidTiming(let url, let detail):
            return "Parakeet emitted invalid word timings for \(url.path): \(detail)"
        case .durationMismatch(let url, let input, let result):
            return "duration mismatch exceeds 10ms for \(url.path): input \(input), model \(result)"
        case .modelOrInputMutated(let url):
            return "input or model tree changed during processing: \(url.path)"
        case .atomicWriteFailed(let url, let code):
            return "could not atomically create output \(url.path): errno \(code)"
        }
    }
}

private struct SHA256Digest: Encodable, Equatable {
    let sha256: String
}

private struct ModelIdentity: Encodable {
    let hf_id: String
    let revision: String
    let quantization: String
    let tree_sha256_before: String?
    let tree_sha256_after: String?
}

private struct GlossaryOutput: Encodable {
    let raw_sha256: String?
    let count: Int
    let applied: Bool
    let injection_mode: String
}

private struct WordTimingOutput: Encodable {
    let word: String
    let start_s: Double
    let end_s: Double
}

private struct ReplacementOutput: Encodable {
    let original_word: String
    let original_score: Float
    let replacement_word: String?
    let replacement_score: Float?
    let should_replace: Bool
    let reason: String
}

private struct ItemOutput: Encodable {
    let input_basename: String
    let input_sha256: String
    let input_sha256_after: String
    let duration_s: Double
    let base_text: String
    let final_text: String
    let confidence: Float
    let tdt_word_timings: [WordTimingOutput]
    let replacements: [ReplacementOutput]
    let was_modified: Bool
    let base_processing_s: Double
    let total_item_wall_s: Double
}

private struct HarnessOutput: Encodable {
    struct Models: Encodable {
        let tdt: ModelIdentity
        let ctc: ModelIdentity?
    }

    let harness: String
    let tool_source_revision: String
    let models: Models
    let glossary: GlossaryOutput
    let items: [ItemOutput]
    let total_wall_s: Double
}

private struct PreparedVocabulary {
    let vocabulary: CustomVocabularyContext
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
    let rawHash: String
}

private struct CanonicalGlossary {
    let rawHash: String
    let items: [String]
}

private func requireDirectory(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw HarnessError.missingDirectory(url)
    }
}

private func requireRegularFile(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw HarnessError.missingFile(url)
    }
}

private func hashFile(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func hashDirectoryTree(_ root: URL) throws -> String {
    try requireDirectory(root)
    let fileManager = FileManager.default
    var entries: [URL] = []
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: []
    ) else {
        throw HarnessError.missingDirectory(root)
    }
    for case let url as URL in enumerator {
        entries.append(url)
    }
    entries.sort { $0.path < $1.path }

    var hash = SHA256()
    for url in entries {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let relativePath = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else { continue }
        guard values.isSymbolicLink != true else {
            throw HarnessError.modelOrInputMutated(url)
        }
        hash.update(data: Data(relativePath.utf8))
        hash.update(data: Data([0]))
        if values.isDirectory == true {
            hash.update(data: Data("directory".utf8))
        } else {
            hash.update(data: Data("file".utf8))
            hash.update(data: Data([0]))
            hash.update(data: Data(try hashFile(url).utf8))
        }
        hash.update(data: Data([0]))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func audioDuration(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0, file.processingFormat.sampleRate > 0 else { throw HarnessError.missingFile(url) }
    return Double(file.length) / file.processingFormat.sampleRate
}

private func requireModelLeaf(_ url: URL, named expected: String) throws {
    try requireDirectory(url)
    guard url.lastPathComponent == expected else { throw HarnessError.invalidModelLeaf(url, expected) }
}

private func loadTdtModelsDirect(from directory: URL) throws -> AsrModels {
    let preprocessorURL = directory.appendingPathComponent(ModelNames.ASR.preprocessorFile)
    let encoderURL = directory.appendingPathComponent(ParakeetEncoderPrecision.int8.encoderFileName)
    let decoderURL = directory.appendingPathComponent(ModelNames.ASR.decoderFile)
    let jointURL = directory.appendingPathComponent(ModelNames.ASR.jointV3File)
    let vocabularyURL = directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
    for modelURL in [preprocessorURL, encoderURL, decoderURL, jointURL] {
        try requireDirectory(modelURL)
    }
    try requireRegularFile(vocabularyURL)

    // Match FluidAudio v3 loading: preprocessing is CPU-only, and inference uses ANE.
    let preprocessorConfiguration = MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuOnly)
    let inferenceConfiguration = AsrModels.defaultConfiguration()
    let vocabularyData = try Data(contentsOf: vocabularyURL)
    guard let vocabularyJSON = try JSONSerialization.jsonObject(with: vocabularyData) as? [String: String] else {
        throw AsrModelsError.loadingFailed("Vocabulary file has unexpected format")
    }
    var vocabulary: [Int: String] = [:]
    for (tokenID, token) in vocabularyJSON {
        if let tokenID = Int(tokenID) {
            vocabulary[tokenID] = token
        }
    }
    guard !vocabulary.isEmpty else {
        throw AsrModelsError.loadingFailed("Vocabulary file contained no numeric token IDs")
    }

    return try AsrModels(
        encoder: MLModel(contentsOf: encoderURL, configuration: inferenceConfiguration),
        preprocessor: MLModel(contentsOf: preprocessorURL, configuration: preprocessorConfiguration),
        decoder: MLModel(contentsOf: decoderURL, configuration: inferenceConfiguration),
        joint: MLModel(contentsOf: jointURL, configuration: inferenceConfiguration),
        configuration: inferenceConfiguration,
        vocabulary: vocabulary,
        version: .v3
    )
}

private func loadCanonicalGlossary(at url: URL) throws -> CanonicalGlossary {
    try requireRegularFile(url)
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
            throw HarnessError.invalidGlossary(
                url,
                "entry has \(item.unicodeScalars.count) Unicode scalars; expected 1...256"
            )
        }
        if seen.insert(item).inserted { items.append(item) }
    }
    guard !items.isEmpty else { throw HarnessError.invalidGlossary(url, "no usable entries") }
    return CanonicalGlossary(rawHash: try hashFile(url), items: items)
}

private func prepareVocabulary(glossary: URL, ctcModelDirectory: URL) async throws -> PreparedVocabulary {
    let glossaryURL = glossary
    let canonicalGlossary = try loadCanonicalGlossary(at: glossaryURL)
    let parsedVocabulary = CustomVocabularyContext(
        terms: canonicalGlossary.items.map { CustomVocabularyTerm(text: $0, weight: 10.0) }
    )
    let ctcModels = try await CtcModels.loadDirect(from: ctcModelDirectory, variant: .ctc110m)
    let tokenizer = try await CtcTokenizer.load(from: ctcModelDirectory)
    let tokenizedTerms = parsedVocabulary.terms.compactMap { term -> CustomVocabularyTerm? in
        let tokenIDs = tokenizer.encode(term.text)
        guard !tokenIDs.isEmpty else { return nil }
        return CustomVocabularyTerm(
            text: term.text,
            weight: term.weight,
            aliases: term.aliases,
            tokenIds: term.tokenIds,
            ctcTokenIds: tokenIDs,
            minSimilarity: term.minSimilarity
        )
    }
    guard tokenizedTerms.count == parsedVocabulary.terms.count else {
        throw HarnessError.invalidGlossary(glossaryURL, "one or more entries could not be tokenized")
    }
    let vocabulary = CustomVocabularyContext(
        terms: tokenizedTerms,
        alpha: parsedVocabulary.alpha,
        minCtcScore: parsedVocabulary.minCtcScore,
        minSimilarity: parsedVocabulary.minSimilarity,
        minCombinedConfidence: parsedVocabulary.minCombinedConfidence,
        minTermLength: parsedVocabulary.minTermLength
    )
    let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
    let rescorer = try await VocabularyRescorer.create(
        spotter: spotter,
        vocabulary: vocabulary,
        ctcModelDirectory: ctcModelDirectory
    )
    return PreparedVocabulary(
        vocabulary: vocabulary,
        spotter: spotter,
        rescorer: rescorer,
        rawHash: canonicalGlossary.rawHash
    )
}

private func validateTimings(_ tokenTimings: [TokenTiming], for item: URL, duration: Double) throws -> [WordTimingOutput] {
    guard !tokenTimings.isEmpty else { throw HarnessError.invalidTiming(item, "missing token timings") }
    let timingEpsilon = 1e-9
    // Preserve raw TDT timings; allow only one 80ms encoder-frame quantization overshoot.
    let maximumEndTime = duration + ASRConstants.secondsPerEncoderFrame + timingEpsilon
    var previousStart = -Double.infinity
    for timing in tokenTimings {
        guard timing.startTime.isFinite, timing.endTime.isFinite, timing.startTime >= 0, timing.endTime > timing.startTime else {
            throw HarnessError.invalidTiming(item, "non-finite, negative, or inverted token span")
        }
        guard timing.startTime + timingEpsilon >= previousStart else {
            throw HarnessError.invalidTiming(item, "non-monotonic token start times")
        }
        guard timing.endTime <= maximumEndTime else {
            throw HarnessError.invalidTiming(item, "token end exceeds input by more than one encoder frame")
        }
        previousStart = timing.startTime
    }
    let words = buildWordTimings(from: tokenTimings)
    guard !words.isEmpty else { throw HarnessError.invalidTiming(item, "token timings did not form words") }
    return words.map { .init(word: $0.word, start_s: $0.startTime, end_s: $0.endTime) }
}

private func processItem(
    item: URL,
    manager: AsrManager,
    vocabulary: PreparedVocabulary?
) async throws -> ItemOutput {
    try requireRegularFile(item)
    let wallStart = Date()
    let inputHashBefore = try hashFile(item)
    let inputDuration = try audioDuration(item)
    var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)

    let baseResult: ASRResult
    let audioSamples: [Float]?
    if vocabulary != nil {
        let samples = try AudioConverter().resampleAudioFile(item)
        audioSamples = samples
        baseResult = try await manager.transcribe(samples, decoderState: &decoderState, language: .italian)
    } else {
        audioSamples = nil
        baseResult = try await manager.transcribe(item, decoderState: &decoderState, language: .italian)
    }
    guard abs(baseResult.duration - inputDuration) <= 0.010 else {
        throw HarnessError.durationMismatch(item, input: inputDuration, result: baseResult.duration)
    }
    guard !baseResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw HarnessError.emptyTranscription(item)
    }
    guard let tokenTimings = baseResult.tokenTimings else {
        throw HarnessError.invalidTiming(item, "backend omitted token timings")
    }
    let wordTimings = try validateTimings(tokenTimings, for: item, duration: inputDuration)

    let finalText: String
    let replacements: [ReplacementOutput]
    let wasModified: Bool
    if let vocabulary, let audioSamples {
        let spotResult = try await vocabulary.spotter.spotKeywordsWithLogProbs(
            audioSamples: audioSamples,
            customVocabulary: vocabulary.vocabulary,
            minScore: nil
        )
        guard !spotResult.logProbs.isEmpty, spotResult.frameDuration > 0 else {
            throw HarnessError.invalidTiming(item, "CTC spotter supplied no usable acoustic evidence")
        }
        let config = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.vocabulary.terms.count)
        let rescored = vocabulary.rescorer.ctcTokenRescore(
            transcript: baseResult.text,
            tokenTimings: tokenTimings,
            logProbs: spotResult.logProbs,
            frameDuration: spotResult.frameDuration,
            cbw: config.cbw,
            marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
            minSimilarity: config.minSimilarity
        )
        finalText = rescored.text
        replacements = rescored.replacements.map {
            .init(
                original_word: $0.originalWord,
                original_score: $0.originalScore,
                replacement_word: $0.replacementWord,
                replacement_score: $0.replacementScore,
                should_replace: $0.shouldReplace,
                reason: $0.reason
            )
        }
        wasModified = rescored.wasModified
    } else {
        finalText = baseResult.text
        replacements = []
        wasModified = false
    }
    guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw HarnessError.emptyTranscription(item)
    }

    let inputHashAfter = try hashFile(item)
    guard inputHashBefore == inputHashAfter else { throw HarnessError.modelOrInputMutated(item) }
    return ItemOutput(
        input_basename: item.lastPathComponent,
        input_sha256: inputHashBefore,
        input_sha256_after: inputHashAfter,
        duration_s: inputDuration,
        base_text: baseResult.text,
        final_text: finalText,
        confidence: baseResult.confidence,
        tdt_word_timings: wordTimings,
        replacements: replacements,
        was_modified: wasModified,
        base_processing_s: baseResult.processingTime,
        total_item_wall_s: Date().timeIntervalSince(wallStart)
    )
}

private func writeAtomicallyWithoutOverwrite(_ data: Data, to destination: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destination.path) { throw HarnessError.outputExists(destination) }
    let directory = destination.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    do {
        try data.write(to: temporary, options: [.atomic])
        guard link(temporary.path, destination.path) == 0 else {
            let code = errno
            if code == EEXIST { throw HarnessError.outputExists(destination) }
            throw HarnessError.atomicWriteFailed(destination, code)
        }
        try fileManager.removeItem(at: temporary)
    } catch {
        try? fileManager.removeItem(at: temporary)
        throw error
    }
}

@main
private struct MaccheroniParakeetBenchmarkHarness {
    static func main() async {
        do {
            let options = try Options(arguments: CommandLine.arguments)
            if FileManager.default.fileExists(atPath: options.output.path) {
                throw HarnessError.outputExists(options.output)
            }
            try requireModelLeaf(options.tdtModelDirectory, named: "parakeet-tdt-0.6b-v3-coreml")
            try requireModelLeaf(options.ctcModelDirectory, named: "parakeet-ctc-110m-coreml")
            for item in options.items { try requireRegularFile(item) }

            let runStart = Date()
            var inputHashesBefore: [String: String] = [:]
            for item in options.items where inputHashesBefore[item.path] == nil {
                inputHashesBefore[item.path] = try hashFile(item)
            }
            let tdtHashBefore = try hashDirectoryTree(options.tdtModelDirectory)
            let ctcHashBefore = try options.glossary == nil ? nil : hashDirectoryTree(options.ctcModelDirectory)

            // This is deliberately set before every model operation. Missing artifacts must fail locally.
            ModelHub.offlineMode = true
            let tdtModels = try loadTdtModelsDirect(from: options.tdtModelDirectory)
            let asrConfig = ASRConfig(
                tdtConfig: TdtConfig(blankId: AsrModelVersion.v3.blankId),
                encoderHiddenSize: AsrModelVersion.v3.encoderHiddenSize
            )
            let manager = AsrManager(config: asrConfig)
            try await manager.loadModels(tdtModels)

            let preparedVocabulary: PreparedVocabulary?
            if let glossary = options.glossary {
                preparedVocabulary = try await prepareVocabulary(
                    glossary: glossary,
                    ctcModelDirectory: options.ctcModelDirectory
                )
            } else {
                preparedVocabulary = nil
            }

            var items: [ItemOutput] = []
            for item in options.items {
                items.append(try await processItem(item: item, manager: manager, vocabulary: preparedVocabulary))
            }

            for item in options.items {
                let inputHashAfter = try hashFile(item)
                guard inputHashesBefore[item.path] == inputHashAfter else {
                    throw HarnessError.modelOrInputMutated(item)
                }
            }
            let tdtHashAfter = try hashDirectoryTree(options.tdtModelDirectory)
            guard tdtHashBefore == tdtHashAfter else { throw HarnessError.modelOrInputMutated(options.tdtModelDirectory) }
            let ctcHashAfter = try options.glossary == nil ? nil : hashDirectoryTree(options.ctcModelDirectory)
            if let ctcHashBefore, ctcHashBefore != ctcHashAfter {
                throw HarnessError.modelOrInputMutated(options.ctcModelDirectory)
            }

            let output = HarnessOutput(
                harness: "MaccheroniParakeetBenchmarkHarness",
                tool_source_revision: "FluidInference/FluidAudio@\(fluidAudioRevision)",
                models: .init(
                    tdt: .init(
                        hf_id: tdtModelID,
                        revision: tdtModelRevision,
                        quantization: tdtModelQuantization,
                        tree_sha256_before: tdtHashBefore,
                        tree_sha256_after: tdtHashAfter
                    ),
                    ctc: preparedVocabulary == nil ? nil : .init(
                        hf_id: ctcModelID,
                        revision: ctcModelRevision,
                        quantization: ctcModelQuantization,
                        tree_sha256_before: ctcHashBefore,
                        tree_sha256_after: ctcHashAfter
                    )
                ),
                glossary: .init(
                    raw_sha256: preparedVocabulary?.rawHash,
                    count: preparedVocabulary?.vocabulary.terms.count ?? 0,
                    applied: preparedVocabulary != nil,
                    injection_mode: preparedVocabulary == nil ? "none" : "acoustic_ctc_rescoring"
                ),
                items: items,
                total_wall_s: Date().timeIntervalSince(runStart)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try writeAtomicallyWithoutOverwrite(encoder.encode(output), to: options.output)
            print("wrote \(options.output.path): \(items.count) item(s)")
        } catch HarnessError.help {
            print(HarnessError.usage.localizedDescription)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
