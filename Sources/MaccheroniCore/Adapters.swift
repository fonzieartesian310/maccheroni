import Foundation

public enum LanguagePin: Equatable, Sendable {
    case automatic
    case fixed(String)
}

extension LanguagePin: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "auto" ? .automatic : .fixed(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .automatic:
            try container.encode("auto")
        case let .fixed(identifier):
            try container.encode(identifier)
        }
    }
}

public struct DiarizationRequest: Sendable {
    public var audioURL: URL
    public var speakerCountHint: ClosedRange<Int>?

    public init(audioURL: URL, speakerCountHint: ClosedRange<Int>? = nil) {
        self.audioURL = audioURL
        self.speakerCountHint = speakerCountHint
    }
}

public protocol DiarizerBackend: Sendable {
    var descriptor: BackendDescriptor { get }
    var model: ModelDescriptor { get }
    func diarize(_ request: DiarizationRequest) async throws -> Timeline
}

public struct ASRRequest: Sendable {
    public var audioURL: URL
    public var startS: Double
    public var endS: Double
    public var language: LanguagePin
    public var glossary: Glossary?
    public var injectionMode: GlossaryInjectionMode

    public init(
        audioURL: URL,
        startS: Double,
        endS: Double,
        language: LanguagePin = .automatic,
        glossary: Glossary? = nil,
        injectionMode: GlossaryInjectionMode = .none
    ) {
        self.audioURL = audioURL
        self.startS = startS
        self.endS = endS
        self.language = language
        self.glossary = glossary
        self.injectionMode = injectionMode
    }
}

public struct ASRResult: Codable, Equatable, Sendable {
    public var rawText: String
    public var segments: [Segment]
    public var glossaryApplied: Bool

    public init(rawText: String, segments: [Segment], glossaryApplied: Bool) {
        self.rawText = rawText
        self.segments = segments
        self.glossaryApplied = glossaryApplied
    }

    enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
        case segments
        case glossaryApplied = "glossary_applied"
    }
}

public protocol ASRBackend: Sendable {
    var descriptor: BackendDescriptor { get }
    var model: ModelDescriptor { get }
    func transcribe(_ request: ASRRequest) async throws -> ASRResult
}
