import Darwin
import Foundation

@main
struct MaccheroniCommand {
    static func main() async {
        do {
            print(try await CLIApplication().execute(
                arguments: Array(CommandLine.arguments.dropFirst())
            ))
        } catch {
            FileHandle.standardError.write(
                Data("\(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }
}
