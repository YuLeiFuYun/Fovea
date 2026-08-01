import Darwin
import Foundation

@main
enum FoveaNetworkLab {
    static func main() async {
        do {
            let options = try NetworkLabOptions.parse(Array(CommandLine.arguments.dropFirst()))
            guard options.live else { throw NetworkLabError.liveModeRequired }
            let report = try await NetworkLabRunner.run(options)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
            if !report.allSucceeded || !report.allExpectationsSatisfied
                || !report.allInvariantsSatisfied
            {
                Darwin.exit(1)
            }
        } catch NetworkLabError.helpRequested {
            FileHandle.standardOutput.write(Data("\(NetworkLabError.usage)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("FoveaNetworkLab failed: \(error)\n".utf8))
            Darwin.exit(2)
        }
    }
}
