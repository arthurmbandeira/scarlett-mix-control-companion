import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("scarlett-device-probe", isDirectory: true)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = [
    "swift",
    "run",
    "--package-path",
    packageDirectory.path,
    "ScarlettDeviceProbe",
    "--"
] + CommandLine.arguments.dropFirst()
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    fputs("Could not launch ScarlettDeviceProbe: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}