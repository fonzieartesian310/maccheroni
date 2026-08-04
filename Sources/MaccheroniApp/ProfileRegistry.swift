import Foundation

enum ProfileRegistryError: Error, LocalizedError {
    case missingResource
    case invalidRegistry(String)

    var errorDescription: String? {
        switch self {
        case .missingResource:
            appString("The bundled profile registry is missing.")
        case let .invalidRegistry(message):
            appString("The profile registry is invalid: \(message)")
        }
    }
}

enum AppProfileRegistry {
    static func load() throws -> [AppProfile] {
        guard let url = appResourcesBundle.url(
            forResource: "profiles",
            withExtension: "json"
        ) else {
            throw ProfileRegistryError.missingResource
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> [AppProfile] {
        let document = try JSONDecoder().decode(
            ProfileRegistryDocument.self,
            from: Data(contentsOf: url)
        )
        guard document.schemaVersion == "1.0.0" else {
            throw ProfileRegistryError.invalidRegistry("unsupported schema version")
        }
        let ids = document.profiles.map(\.id)
        guard Set(ids).count == ids.count else {
            throw ProfileRegistryError.invalidRegistry("duplicate profile identifier")
        }
        guard Set(ids) == Set(AppProfileID.allCases) else {
            throw ProfileRegistryError.invalidRegistry("the v1 profile set is incomplete")
        }
        guard document.profiles.allSatisfy({ !$0.metrics.contains(where: { $0.display.isEmpty }) }) else {
            throw ProfileRegistryError.invalidRegistry("empty benchmark display value")
        }
        guard document.profiles.allSatisfy({ profile in
            !profile.languageCoverage.isEmpty
                && !profile.models.isEmpty
                && profile.models.allSatisfy {
                    !$0.hfModelID.isEmpty
                        && $0.revision.count == 40
                        && $0.revision.allSatisfy(\.isHexDigit)
                        && !$0.quantization.isEmpty
                }
        }) else {
            throw ProfileRegistryError.invalidRegistry("unpinned model or missing language coverage")
        }
        return document.profiles
    }
}
