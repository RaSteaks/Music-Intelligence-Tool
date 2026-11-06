// Compiled with the actual Studio/SongRecord sources by script/check_agent_handoff.sh; no App or XCTest runner.
import Foundation

@main
struct AgentHandoffCheck {
    @MainActor static func main() async throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "switch" {
            try await checkSongSwitch(in: input)
            return
        }
        let song = try JSONDecoder().decode(SongRecord.self, from: Data(contentsOf: input))
        let message = try song.agentMessage(mcpEndpoint: "http://127.0.0.1:18765/mcp")
        let snapshot = Data(message.components(separatedBy: "\n").last!.utf8)
        let copied = try JSONSerialization.jsonObject(with: snapshot) as! NSDictionary
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(song)) as! NSDictionary
        precondition(copied == expected, "Clipboard handoff dropped analysis fields")

        let studio = Studio(root: input.deletingLastPathComponent().appendingPathComponent("library"))
        studio.song = song
        await studio.sendToAgent()
        precondition(!studio.sendingToAgent, "Sender remained busy")
        if CommandLine.arguments.last == "offline" {
            precondition(studio.notice != nil && studio.agentSendStatus?.hasPrefix("未确认发送") == true,
                         "Disconnected channel was reported as delivered")
        } else {
            precondition(studio.notice == nil && studio.agentSendStatus?.hasPrefix("Claude Code 已读取完整记录") == true,
                         "Full handoff was not acknowledged: \(studio.agentSendStatus ?? "nil")")
        }
        print(studio.agentSendStatus ?? "")
    }

    @MainActor static func checkSongSwitch(in directory: URL) async throws {
        let studio = Studio(root: directory.appendingPathComponent("library"))
        let first = directory.appendingPathComponent("first.wav").resolvingSymlinksInPath()
        let second = directory.appendingPathComponent("second.wav").resolvingSymlinksInPath()
        try studio.open(first)
        let oldSend = Task { await studio.sendToAgent() }
        // The HTTP fixture signals only after the old POST or receipt request is in flight.
        try await waitForSignal(directory.appendingPathComponent("switch"))
        try studio.open(second)
        precondition(studio.agentSendStatus == nil && !studio.sendingToAgent,
                     "Switching songs retained the old handoff state")
        if CommandLine.arguments.last == "roundtrip" {
            try studio.open(first)
        }
        let current = URL(fileURLWithPath: studio.song!.path)
        let newSend = Task { await studio.sendToAgent() }
        await oldSend.value
        precondition(studio.sendingToAgent && studio.agentSendStatus == "正在发送完整分析记录…",
                     "The old response overwrote or unlocked the new handoff")
        precondition(studio.notice == nil, "The old request displayed an error on the new song")
        try Data().write(to: directory.appendingPathComponent("old-finished"))
        await newSend.value
        precondition(!studio.sendingToAgent && studio.notice == nil &&
                     studio.agentSendStatus?.hasPrefix("Claude Code 已读取完整记录") == true,
                     "The new song did not receive its own receipt")

        let delivered = studio.agentSendStatus
        try studio.open(current)
        precondition(studio.agentSendStatus == delivered, "Reopening the current song cleared its receipt")
        do {
            try studio.open(directory.appendingPathComponent("missing.wav"))
            preconditionFailure("Opening a missing file unexpectedly succeeded")
        } catch {
            precondition(studio.agentSendStatus == delivered, "A failed switch cleared the current receipt")
        }
        try studio.open(current == first ? second : first)
        precondition(studio.agentSendStatus == nil && !studio.sendingToAgent,
                     "A completed receipt survived a song switch")
        print("Song switch handoff checks passed")
    }

    static func waitForSignal(_ file: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: file.path) {
            guard ContinuousClock.now < deadline else {
                throw StudioError.message("Timed out waiting for test signal: \(file.lastPathComponent)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
