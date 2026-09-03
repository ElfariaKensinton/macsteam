import Foundation

enum Subprocess {

    struct Result {
        let code: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return Result(code: -1, stdout: "", stderr: error.localizedDescription)
        }
        let (outData, errData) = drainPipes(out: outPipe, err: errPipe)
        p.waitUntilExit()
        return Result(
            code: p.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    static func drainPipes(out: Pipe, err: Pipe) -> (out: Data, err: Data) {
        final class Box: @unchecked Sendable { var out = Data(); var err = Data() }
        let box = Box()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "com.macsteam.proc-drain", attributes: .concurrent)
        q.async(group: group) { box.out = out.fileHandleForReading.readDataToEndOfFile() }
        q.async(group: group) { box.err = err.fileHandleForReading.readDataToEndOfFile() }
        group.wait()
        return (box.out, box.err)
    }

    static func killSteam() {
        _ = run("/usr/bin/pkill", ["-9", "-x", "steam_osx"])
    }
}
