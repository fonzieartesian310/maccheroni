import Foundation

public enum ChunkBoundarySource: String, Codable, Equatable, Sendable {
    case silence
    case deterministicFallback = "deterministic_fallback"
}

public struct ProposedChunk: Codable, Equatable, Sendable {
    public var index: Int
    public var startS: Double
    public var endS: Double
    public var boundarySource: ChunkBoundarySource

    public init(index: Int, startS: Double, endS: Double, boundarySource: ChunkBoundarySource) {
        self.index = index
        self.startS = startS
        self.endS = endS
        self.boundarySource = boundarySource
    }

    enum CodingKeys: String, CodingKey {
        case index
        case startS = "start_s"
        case endS = "end_s"
        case boundarySource = "boundary_source"
    }
}

public struct ChunkPlanningConfiguration: Equatable, Sendable {
    public var targetDurationS: Double
    public var minimumDurationS: Double
    public var maximumDurationS: Double

    public init(
        targetDurationS: Double = 15 * 60,
        minimumDurationS: Double = 10 * 60,
        maximumDurationS: Double = 20 * 60
    ) {
        self.targetDurationS = targetDurationS
        self.minimumDurationS = minimumDurationS
        self.maximumDurationS = maximumDurationS
    }

    public static let `default` = ChunkPlanningConfiguration()
}

public enum ChunkPlanningError: Error, Equatable, Sendable {
    case invalidConfiguration
}

public struct SilenceAwareChunkPlanner: Sendable {
    public init() {}

    public func propose(
        activityMap: VoiceActivityMap,
        configuration: ChunkPlanningConfiguration = .default
    ) throws -> [ProposedChunk] {
        guard configuration.minimumDurationS > 0,
                configuration.minimumDurationS <= configuration.targetDurationS,
                configuration.targetDurationS <= configuration.maximumDurationS else {
            throw ChunkPlanningError.invalidConfiguration
        }
        guard activityMap.durationS > 0 else { return [] }

        var chunks: [ProposedChunk] = []
        var start = 0.0
        while activityMap.durationS - start > configuration.maximumDurationS {
            let lower = start + configuration.minimumDurationS
            let upper = min(start + configuration.maximumDurationS, activityMap.durationS)
            let desired = min(start + configuration.targetDurationS, upper)
            if let silenceCut = bestSilenceCut(
                in: activityMap.silenceRegions,
                lowerBound: lower,
                upperBound: upper,
                desired: desired
            ) {
                chunks.append(ProposedChunk(
                    index: chunks.count,
                    startS: start,
                    endS: silenceCut,
                    boundarySource: .silence
                ))
                start = silenceCut
            } else {
                let fallback = desired
                chunks.append(ProposedChunk(
                    index: chunks.count,
                    startS: start,
                    endS: fallback,
                    boundarySource: .deterministicFallback
                ))
                start = fallback
            }
        }
        chunks.append(ProposedChunk(
            index: chunks.count,
            startS: start,
            endS: activityMap.durationS,
            boundarySource: .silence
        ))
        return chunks
    }

    private func bestSilenceCut(
        in silences: [VoiceActivityRegion],
        lowerBound: Double,
        upperBound: Double,
        desired: Double
    ) -> Double? {
        silences.compactMap { silence -> Double? in
            let start = max(silence.startS, lowerBound)
            let end = min(silence.endS, upperBound)
            guard start <= end else { return nil }
            return min(max(desired, start), end)
        }.min { lhs, rhs in
            let lhsDistance = abs(lhs - desired)
            let rhsDistance = abs(rhs - desired)
            return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
        }
    }
}

/// The provenance of an inference-leaf boundary.  This is deliberately separate
/// from `ChunkBoundarySource`: generic preprocessing chunks describe product-level
/// work units, while inference leaves describe a single backend invocation.
public enum InferenceLeafBoundarySource: String, Codable, Equatable, Sendable {
    case silence
    case deterministicFallback = "deterministic_fallback"
    case inputEnd = "input_end"
}

/// A contiguous, half-open PCM sample range submitted to one ASR invocation.
///
/// Sample indexes avoid representing a cut as a floating point timestamp.  The
/// caller creates the corresponding WAV from `[startSample, endSample)`.
public struct InferenceLeaf: Codable, Equatable, Sendable {
    public var startSample: Int64
    public var endSample: Int64
    public var depth: Int
    public var boundarySource: InferenceLeafBoundarySource

    public init(
        startSample: Int64,
        endSample: Int64,
        depth: Int,
        boundarySource: InferenceLeafBoundarySource
    ) {
        self.startSample = startSample
        self.endSample = endSample
        self.depth = depth
        self.boundarySource = boundarySource
    }

    public var sampleCount: Int64 { endSample - startSample }

    enum CodingKeys: String, CodingKey {
        case startSample = "start_sample"
        case endSample = "end_sample"
        case depth
        case boundarySource = "boundary_source"
    }
}

/// Backend-provided bounds for short ASR inference leaves.
///
/// This type has no backend identity.  The backend layer owns choosing concrete
/// values, so a generic preprocessing plan cannot accidentally become an ASR
/// invocation plan.
public struct InferenceLeafPlanningConfiguration: Equatable, Sendable {
    public var sampleRateHz: Int
    public var preferredInitialDurationS: Double
    public var minimumInitialDurationS: Double
    public var maximumInitialDurationS: Double
    public var minimumRecoveryDurationS: Double
    public var maximumRecoveryDepth: Int

    public init(
        sampleRateHz: Int = 16_000,
        preferredInitialDurationS: Double,
        minimumInitialDurationS: Double,
        maximumInitialDurationS: Double,
        minimumRecoveryDurationS: Double,
        maximumRecoveryDepth: Int
    ) {
        self.sampleRateHz = sampleRateHz
        self.preferredInitialDurationS = preferredInitialDurationS
        self.minimumInitialDurationS = minimumInitialDurationS
        self.maximumInitialDurationS = maximumInitialDurationS
        self.minimumRecoveryDurationS = minimumRecoveryDurationS
        self.maximumRecoveryDepth = maximumRecoveryDepth
    }
}

public enum InferenceLeafPlanningError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidSampleRange
    case recoveryDepthExhausted(depth: Int, maximumDepth: Int)
    case recoveryLeafTooShort(sampleCount: Int64, minimumChildSamples: Int64)
}

/// Plans backend inference leaves and bounded limit-recovery children.
///
/// The initial plan covers every sample exactly once.  Recovery only splits the
/// failed parent range, never re-plans already completed siblings.
public struct InferenceLeafPlanner: Sendable {
    public init() {}

    public func proposeInitialLeaves(
        totalSamples: Int64,
        activityMap: VoiceActivityMap,
        configuration: InferenceLeafPlanningConfiguration
    ) throws -> [InferenceLeaf] {
        let bounds = try validatedBounds(configuration)
        guard totalSamples >= 0 else {
            throw InferenceLeafPlanningError.invalidSampleRange
        }
        guard totalSamples > 0 else { return [] }

        var leaves: [InferenceLeaf] = []
        var startSample: Int64 = 0
        while totalSamples - startSample > bounds.maximumInitialSamples {
            // Keep at least one complete initial leaf for the tail.  This is why
            // an input one sample over the maximum is split instead of creating a
            // one-sample tail.
            let lowerBound = startSample + bounds.minimumInitialSamples
            let upperBound = min(
                startSample + bounds.maximumInitialSamples,
                totalSamples - bounds.minimumInitialSamples
            )
            guard lowerBound <= upperBound else {
                throw InferenceLeafPlanningError.invalidSampleRange
            }
            let desired = min(startSample + bounds.preferredInitialSamples, upperBound)
            let cut = bestSilenceCut(
                in: activityMap.silenceRegions,
                lowerBound: lowerBound,
                upperBound: upperBound,
                desired: desired,
                sampleRateHz: configuration.sampleRateHz
            )
            leaves.append(InferenceLeaf(
                startSample: startSample,
                endSample: cut ?? desired,
                depth: 0,
                boundarySource: cut == nil ? .deterministicFallback : .silence
            ))
            startSample = cut ?? desired
        }
        leaves.append(InferenceLeaf(
            startSample: startSample,
            endSample: totalSamples,
            depth: 0,
            boundarySource: .inputEnd
        ))
        return leaves
    }

    /// Splits a current limit-failed leaf into two children.  A parent at the
    /// configured maximum depth, or one unable to make two minimum-size children,
    /// remains an explicit failure for the caller to record.
    public func splitForLimitRecovery(
        leaf: InferenceLeaf,
        activityMap: VoiceActivityMap,
        configuration: InferenceLeafPlanningConfiguration
    ) throws -> [InferenceLeaf] {
        let bounds = try validatedBounds(configuration)
        guard leaf.startSample >= 0, leaf.endSample > leaf.startSample, leaf.depth >= 0 else {
            throw InferenceLeafPlanningError.invalidSampleRange
        }
        guard leaf.depth < configuration.maximumRecoveryDepth else {
            throw InferenceLeafPlanningError.recoveryDepthExhausted(
                depth: leaf.depth,
                maximumDepth: configuration.maximumRecoveryDepth
            )
        }
        guard leaf.sampleCount >= bounds.minimumRecoverySamples * 2 else {
            throw InferenceLeafPlanningError.recoveryLeafTooShort(
                sampleCount: leaf.sampleCount,
                minimumChildSamples: bounds.minimumRecoverySamples
            )
        }

        let lowerBound = leaf.startSample + bounds.minimumRecoverySamples
        let upperBound = leaf.endSample - bounds.minimumRecoverySamples
        let midpoint = leaf.startSample + leaf.sampleCount / 2
        let cut = bestSilenceCut(
            in: activityMap.silenceRegions,
            lowerBound: lowerBound,
            upperBound: upperBound,
            desired: midpoint,
            sampleRateHz: configuration.sampleRateHz
        )
        let boundary = cut ?? midpoint
        return [
            InferenceLeaf(
                startSample: leaf.startSample,
                endSample: boundary,
                depth: leaf.depth + 1,
                boundarySource: cut == nil ? .deterministicFallback : .silence
            ),
            InferenceLeaf(
                startSample: boundary,
                endSample: leaf.endSample,
                depth: leaf.depth + 1,
                boundarySource: leaf.boundarySource
            ),
        ]
    }

    /// Rounds an external seconds value to the exact PCM frame used by the leaf
    /// planner.  Once planning starts all subsequent operations use integers.
    public static func sampleIndex(seconds: Double, sampleRateHz: Int) -> Int64 {
        Int64((seconds * Double(sampleRateHz)).rounded(.toNearestOrAwayFromZero))
    }

    private func validatedBounds(
        _ configuration: InferenceLeafPlanningConfiguration
    ) throws -> InferenceLeafBounds {
        guard configuration.sampleRateHz > 0,
              configuration.minimumInitialDurationS > 0,
              configuration.minimumInitialDurationS <= configuration.preferredInitialDurationS,
              configuration.preferredInitialDurationS <= configuration.maximumInitialDurationS,
              configuration.minimumRecoveryDurationS > 0,
              configuration.maximumRecoveryDepth >= 0
        else {
            throw InferenceLeafPlanningError.invalidConfiguration
        }
        let minimumInitialSamples = Self.sampleIndex(
            seconds: configuration.minimumInitialDurationS,
            sampleRateHz: configuration.sampleRateHz
        )
        let preferredInitialSamples = Self.sampleIndex(
            seconds: configuration.preferredInitialDurationS,
            sampleRateHz: configuration.sampleRateHz
        )
        let maximumInitialSamples = Self.sampleIndex(
            seconds: configuration.maximumInitialDurationS,
            sampleRateHz: configuration.sampleRateHz
        )
        let minimumRecoverySamples = Self.sampleIndex(
            seconds: configuration.minimumRecoveryDurationS,
            sampleRateHz: configuration.sampleRateHz
        )
        guard minimumInitialSamples > 0,
              minimumInitialSamples <= preferredInitialSamples,
              preferredInitialSamples <= maximumInitialSamples,
              minimumRecoverySamples > 0
        else {
            throw InferenceLeafPlanningError.invalidConfiguration
        }
        return InferenceLeafBounds(
            minimumInitialSamples: minimumInitialSamples,
            preferredInitialSamples: preferredInitialSamples,
            maximumInitialSamples: maximumInitialSamples,
            minimumRecoverySamples: minimumRecoverySamples
        )
    }

    private func bestSilenceCut(
        in silences: [VoiceActivityRegion],
        lowerBound: Int64,
        upperBound: Int64,
        desired: Int64,
        sampleRateHz: Int
    ) -> Int64? {
        silences.compactMap { silence -> Int64? in
            let start = max(
                Self.sampleIndex(seconds: silence.startS, sampleRateHz: sampleRateHz),
                lowerBound
            )
            let end = min(
                Self.sampleIndex(seconds: silence.endS, sampleRateHz: sampleRateHz),
                upperBound
            )
            guard start <= end else { return nil }
            return min(max(desired, start), end)
        }.min { lhs, rhs in
            let lhsDistance = abs(lhs - desired)
            let rhsDistance = abs(rhs - desired)
            return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
        }
    }
}

private struct InferenceLeafBounds: Sendable {
    var minimumInitialSamples: Int64
    var preferredInitialSamples: Int64
    var maximumInitialSamples: Int64
    var minimumRecoverySamples: Int64
}
