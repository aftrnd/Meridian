import Foundation

/// A game's Steam Cloud state, for the Cloud Saves row on its page. Steam's
/// library shows a "Cloud Status" from its client API, which Meridian can't
/// reach; Steam's files hold the same facts: the state it last recorded for
/// each game, and the uploads it is running (Pattern 69).
enum SteamCloudStatus: Equatable, Sendable {
    case upToDate
    case syncing
    case uploading
    /// Saves changed on this Mac that Steam hasn't uploaded yet.
    case waitingToUpload
    /// Newer saves in the cloud; Steam downloads them when the game launches.
    case newerInCloud
    /// Steam asks which saves to keep when the game launches.
    case conflict

    var text: String {
        switch self {
        case .upToDate: "Up to date"
        case .syncing: "Syncing…"
        case .uploading: "Uploading…"
        case .waitingToUpload: "Waiting to upload"
        case .newerInCloud: "Downloads when you play"
        case .conflict: "File conflict"
        }
    }

    /// Variants of one SF Symbol, like the launch card's status glyphs.
    var symbol: String {
        switch self {
        case .upToDate: "checkmark.icloud"
        case .syncing: "arrow.clockwise.icloud"
        case .uploading, .waitingToUpload: "icloud.and.arrow.up"
        case .newerInCloud: "icloud.and.arrow.down"
        case .conflict: "exclamationmark.icloud"
        }
    }

    /// The last status read for each game: a page opened again mounts with
    /// its row in place instead of adding it mid-zoom, as the store data does.
    @MainActor static var lastRead: [Int: SteamCloudStatus] = [:]

    // MARK: - Reading Steam's files

    /// What Steam is doing with `appID`'s saves: an upload it logged in the
    /// last 30 s (lines come under 5 s apart while one runs, as the launch
    /// wait reads them), else the state it last recorded; nil when it has
    /// recorded none. Reads files: call off the main actor.
    static func read(appID: Int, localConfig: URL?, cloudLog: URL, now: Date = .now) -> SteamCloudStatus? {
        if let uploaded = lastTransfer(appID: appID, in: tail(of: cloudLog)),
           now.timeIntervalSince(uploaded) < 30 {
            return .uploading
        }
        guard let localConfig, let config = try? String(contentsOf: localConfig, encoding: .utf8) else { return nil }
        return recorded(appID: appID, localConfig: config)
    }

    /// `apps > <id> > cloud > last_sync_state` in localconfig.vdf. Steam's
    /// values are the strings beside that key in steamclient64.dll (client
    /// 1792618285, Oct 22 2026): synchronized, inprogress, changesincloud,
    /// changeslocally, changesincloudandlocally, conflictingchanges,
    /// notinitialized. Every game seen so far reads "synchronized".
    static func recorded(appID: Int, localConfig: String) -> SteamCloudStatus? {
        let lines = localConfig.components(separatedBy: "\n")
        let path = ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", String(appID), "cloud"]
        guard let block = SteamEula.block(at: path, in: lines),
              let state = SteamEula.directValues(of: block, in: lines).first(where: { $0.key == "last_sync_state" })?.value
        else { return nil }
        switch state {
        case "synchronized": return .upToDate
        case "inprogress": return .syncing
        case "changeslocally": return .waitingToUpload
        case "changesincloud": return .newerInCloud
        case "changesincloudandlocally", "conflictingchanges": return .conflict
        default: return nil
        }
    }

    /// When Steam last logged a cloud transfer for `appID` in `text`
    /// (cloud_log.txt), from the line's time stamp. Steam's clock is the
    /// Mac's: its launch lines carry the same second as meridian.log's.
    static func lastTransfer(appID: Int, in text: String) -> Date? {
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { transferAppID($0) == appID }),
              line.first == "["
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(line.dropFirst().prefix(19)))
    }

    /// The app a cloud_log.txt line is a transfer for, or nil. Steam's
    /// transfer lines, verbatim from Noita's world cleanup (Oct 22 2026):
    /// `[AppID 881100] Upload batch initiated, ID: …`,
    /// `[AppID 881100] HTTP upload for file '…' beginning . . .`,
    /// `[AppID 881100] Upload OK for file …`,
    /// `[AppID 881100] Delete OK for file …`.
    /// Evaluations (`Starting sync (eval,)`) don't count: Steam runs one for
    /// every game within a second of starting.
    static func transferAppID(_ line: Substring) -> Int? {
        guard let open = line.range(of: "[AppID "),
              let close = line[open.upperBound...].firstIndex(of: "]"),
              let id = Int(line[open.upperBound..<close])
        else { return nil }
        let message = line[line.index(after: close)...].drop { $0 == " " }
        return ["Upload ", "HTTP upload ", "Delete OK "].contains(where: { message.hasPrefix($0) }) ? id : nil
    }

    /// The end of `url`: 128 KB is over a minute of Noita's upload, the
    /// busiest seen (8 lines a second).
    private static func tail(of url: URL, bytes: UInt64 = 128 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
