import Darwin
import Foundation

@main
enum FoveaNetworkLab {
    static func main() async {
        do {
            let options = try NetworkLabOptions.parse(Array(CommandLine.arguments.dropFirst()))
            let selectedModeCount = [
                options.live,
                options.mjpegMechanism,
                options.sharedTaskRelayMechanism,
                options.progressiveResourceMechanism,
            ].filter { $0 }.count
            guard selectedModeCount <= 1 else {
                throw NetworkLabError.conflictingModes
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if options.mjpegMechanism {
                let report = try await MJPEGMechanismLab.run()
                FileHandle.standardOutput.write(try encoder.encode(report))
                FileHandle.standardOutput.write(Data("\n".utf8))
                if !report.allCorrect || !report.orderBalanced { Darwin.exit(1) }
                return
            }
            if options.sharedTaskRelayMechanism {
                let report = try await SharedTaskRelayMechanismLab.run()
                FileHandle.standardOutput.write(try encoder.encode(report))
                FileHandle.standardOutput.write(Data("\n".utf8))
                if !report.allCorrect { Darwin.exit(1) }
                return
            }
            if options.progressiveResourceMechanism {
                let report = try await ProgressiveResourceMechanismLab.run(options: options)
                FileHandle.standardOutput.write(try encoder.encode(report))
                FileHandle.standardOutput.write(Data("\n".utf8))
                if !report.allCorrect { Darwin.exit(1) }
                return
            }
            guard options.live else { throw NetworkLabError.liveModeRequired }
            let report = try await NetworkLabRunner.run(options)
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
