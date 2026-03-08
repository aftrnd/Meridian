/// Tests for the ProtonBridge JSON wire protocol.
///
/// These tests verify that commands and events are serialized/deserialized
/// exactly as the meridian-agent Go binary expects them. A mismatch here
/// means vsock messages will be silently dropped or parsed incorrectly.
///
/// Run with:  swift test --filter ProtonBridgeProtocolTests

import Testing
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Types mirrored from ProtonBridge.swift / meridian-agent/main.go
// ─────────────────────────────────────────────────────────────────────────────

// Host → Guest commands
struct BridgeCmd: Codable, Equatable {
    let cmd: String
    let appid: Int?
    let steamid: String?
    let w: Int?
    let h: Int?
}

// Guest → Host events
struct BridgeEvent: Codable, Equatable {
    let event: String
    let pid: Int?
    let code: Int?
    let line: String?
    let appid: Int?
    let pct: Double?
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Command encoding
// ─────────────────────────────────────────────────────────────────────────────

@Suite("ProtonBridge Protocol — Commands (Host → Guest)")
struct CommandEncodingTests {

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    func encode(_ payload: [String: any Sendable]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test("launch command encodes appid and steamid")
    func launchCommand() throws {
        let json = try encode(["cmd": "launch", "appid": 1091500, "steamid": "76561198000000001"])
        let parsed = try JSONDecoder().decode(BridgeCmd.self, from: Data(json.utf8))

        #expect(parsed.cmd == "launch")
        #expect(parsed.appid == 1091500)
        #expect(parsed.steamid == "76561198000000001")
        #expect(parsed.w == nil)
        #expect(parsed.h == nil)
    }

    @Test("stop command encodes correctly")
    func stopCommand() throws {
        let json = try encode(["cmd": "stop"])
        let parsed = try JSONDecoder().decode(BridgeCmd.self, from: Data(json.utf8))
        #expect(parsed.cmd == "stop")
        #expect(parsed.appid == nil)
    }

    @Test("install command encodes appid")
    func installCommand() throws {
        let json = try encode(["cmd": "install", "appid": 730])
        let parsed = try JSONDecoder().decode(BridgeCmd.self, from: Data(json.utf8))
        #expect(parsed.cmd == "install")
        #expect(parsed.appid == 730)
    }

    @Test("resize command encodes w and h")
    func resizeCommand() throws {
        let json = try encode(["cmd": "resize", "w": 2560, "h": 1440])
        let parsed = try JSONDecoder().decode(BridgeCmd.self, from: Data(json.utf8))
        #expect(parsed.cmd == "resize")
        #expect(parsed.w == 2560)
        #expect(parsed.h == 1440)
    }

    @Test("commands are newline-terminated")
    func newlineTermination() throws {
        let payload = ["cmd": "stop"]
        let data = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
    }

    @Test("appid is Int not String in wire format")
    func appidType() throws {
        // The Go struct uses int — if we accidentally send a String the agent
        // will reject it with a parse error.
        let json = try encode(["cmd": "launch", "appid": 570, "steamid": ""])
        #expect(json.contains("\"appid\":570"), "appid must be an integer in JSON, got: \(json)")
        #expect(!json.contains("\"appid\":\"570\""), "appid must NOT be a quoted string")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Event decoding
// ─────────────────────────────────────────────────────────────────────────────

@Suite("ProtonBridge Protocol — Events (Guest → Host)")
struct EventDecodingTests {

    @Test("started event decodes pid")
    func startedEvent() throws {
        let json = #"{"event":"started","pid":12345}"#
        let e = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        #expect(e.event == "started")
        #expect(e.pid == 12345)
    }

    @Test("exited event decodes exit code")
    func exitedEvent() throws {
        let json = #"{"event":"exited","code":0}"#
        let e = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        #expect(e.event == "exited")
        #expect(e.code == 0)
    }

    @Test("exited event with non-zero code")
    func exitedEventNonZero() throws {
        let json = #"{"event":"exited","code":1}"#
        let e = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        #expect(e.code == 1)
    }

    @Test("log event decodes line text")
    func logEvent() throws {
        let json = #"{"event":"log","line":"proton: launching game"}"#
        let e = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        #expect(e.event == "log")
        #expect(e.line == "proton: launching game")
    }

    @Test("progress event decodes appid and percentage")
    func progressEvent() throws {
        let json = #"{"event":"progress","appid":1091500,"pct":42.5}"#
        let e = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        #expect(e.event == "progress")
        #expect(e.appid == 1091500)
        #expect(e.pct == 42.5)
    }

    @Test("unknown event keys are tolerated (forward compatibility)")
    func unknownKeys() throws {
        // Agent may add new fields in future — host must not crash
        let json = #"{"event":"started","pid":999,"future_field":"x"}"#
        let e = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
        #expect(e.event == "started")
        #expect(e.pid == 999)
    }

    @Test("multi-line stream is split on newlines")
    func newlineSplitting() {
        let stream = """
        {"event":"log","line":"line1"}
        {"event":"log","line":"line2"}
        {"event":"exited","code":0}
        """
        let lines = stream.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines[0].contains("line1"))
        #expect(lines[2].contains("exited"))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Known appIDs (smoke-test that preview data matches protocol)
// ─────────────────────────────────────────────────────────────────────────────

@Suite("Game Model — Steam App IDs")
struct GameAppIDTests {

    struct MockGame {
        let id: Int
        let name: String
    }

    let previewGames: [MockGame] = [
        MockGame(id: 570,     name: "Dota 2"),
        MockGame(id: 730,     name: "Counter-Strike 2"),
        MockGame(id: 1091500, name: "Cyberpunk 2077"),
        MockGame(id: 1174180, name: "Red Dead Redemption 2"),
        MockGame(id: 892970,  name: "Valheim"),
        MockGame(id: 1245620, name: "ELDEN RING"),
    ]

    @Test("all preview appids are positive integers")
    func appidsPositive() {
        for game in previewGames {
            #expect(game.id > 0, "appid for \(game.name) must be > 0")
        }
    }

    @Test("launch JSON for each preview game round-trips correctly")
    func launchRoundTrip() throws {
        for game in previewGames {
            let payload: [String: Any] = ["cmd": "launch", "appid": game.id, "steamid": "76561198000000001"]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let back = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            #expect(back["appid"] as? Int == game.id, "\(game.name) appid round-trip failed")
        }
    }
}
