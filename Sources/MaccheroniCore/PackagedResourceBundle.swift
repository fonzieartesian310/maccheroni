import Foundation

public enum PackagedResourceBundle {
    public static func resolve(
        named name: String,
        fallback: () -> Bundle
    ) -> Bundle {
        let fileName = "\(name).bundle"
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(fileName))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(fileName))
        if let executableURL = Bundle.main.executableURL {
            let executableDirectory = executableURL.deletingLastPathComponent()
            let contentsDirectory = executableDirectory.deletingLastPathComponent()
            candidates.append(
                contentsDirectory
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent(fileName)
            )
            candidates.append(executableDirectory.appendingPathComponent(fileName))
        }

        for candidate in candidates {
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return fallback()
    }
}
