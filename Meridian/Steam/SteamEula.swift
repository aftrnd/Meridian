import Foundation

private let log = MeridianLog(category: "SteamEula")

/// A game's license agreement, as Steam lists it in the game's app info
/// (`common/eulas/<n>`: id, name, url, version).
///
/// Steam draws its own agreement dialog inside its library window, so it
/// can't be shown on its own the way the sign-in window is. Meridian shows
/// the agreement in its own sheet and records the player's answer where
/// Steam's dialog does: `"<id>" "<version>"` in the game's block of
/// `userdata/<account>/config/localconfig.vdf`. Steam reads that file when it
/// starts and then launches without asking; with the line removed it asks
/// again (Pattern 47, CLI-verified Oct 12 2026).
struct SteamEula: Equatable, Sendable, Identifiable {
    let appID: Int
    /// `4069520_eula_0`
    let id: String
    /// `Super Battle Golf EULA`
    let name: String
    let url: URL
    let version: Int
}

extension SteamEula {

    // MARK: - The game's agreements and the player's answers

    /// The agreements for `appID` the player hasn't accepted. `pending` are
    /// accepted in Meridian but not yet handed to Steam. Empty when Steam's
    /// files can't be read: Steam then asks in its own window.
    static func unaccepted(
        appID: Int,
        appInfo appInfoURL: URL,
        localConfig localConfigURL: URL,
        pending: [SteamEula]
    ) -> [SteamEula] {
        guard let data = try? Data(contentsOf: appInfoURL, options: .mappedIfSafe) else {
            log.warning("[unaccepted] appID=\(appID): no app info cache at \(appInfoURL.path(percentEncoded: false))")
            return []
        }
        guard let listed = listed(appID: appID, appInfo: data) else {
            log.warning("[unaccepted] appID=\(appID): app info cache unreadable (format changed?)")
            return []
        }
        let config = (try? String(contentsOf: localConfigURL, encoding: .utf8)) ?? ""
        let accepted = acceptedVersions(appID: appID, localConfig: config)
        return listed.filter { eula in
            (accepted[eula.id] ?? 0) < eula.version && !pending.contains(eula)
        }
    }

    // MARK: - Steam's app info cache (appcache/appinfo.vdf)

    /// The agreements Steam's app info cache lists for `appID` (empty when
    /// it has none), or nil when the cache can't be read. Format 29: a
    /// header, one binary key-value tree per app, and a string table its
    /// keys index (verified against Steam's cache, Oct 12 2026).
    static func listed(appID: Int, appInfo data: Data) -> [SteamEula]? {
        let bytes = [UInt8](data)
        var reader = BinaryReader(bytes: bytes, offset: 0)
        guard reader.u32() == 0x0756_4429, reader.u32() != nil,
              let tableOffset = reader.u64().flatMap({ Int(exactly: $0) }),
              let keys = stringTable(bytes, at: tableOffset)
        else { return nil }

        while let id = reader.u32(), id != 0 {
            guard let size = reader.u32().map(Int.init) else { return nil }
            let next = reader.offset + size
            if id == appID {
                // infoState, lastUpdated, picsToken, SHA-1, change number, SHA-1
                reader.offset += 4 + 4 + 8 + 20 + 4 + 20
                guard case .section(let root)? = keyValues(&reader, keys: keys) else { return nil }
                return eulas(appID: appID, in: root)
            }
            reader.offset = next
        }
        return []
    }

    private static func eulas(appID: Int, in root: [String: KeyValue]) -> [SteamEula] {
        guard case .section(let appinfo)? = root["appinfo"],
              case .section(let common)? = appinfo["common"],
              case .section(let list)? = common["eulas"]
        else { return [] }
        return list.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.compactMap { _, value in
            guard case .section(let entry) = value,
                  case .string(let id)? = entry["id"],
                  case .string(let link)? = entry["url"],
                  let url = URL(string: link)
            else { return nil }
            let name: String
            if case .string(let n)? = entry["name"] { name = n } else { name = id }
            let version: Int
            switch entry["version"] {
            case .int(let v)?: version = v
            case .string(let s)?: version = Int(s) ?? 0
            default: version = 0
            }
            return SteamEula(appID: appID, id: id, name: name, url: url, version: version)
        }
    }

    private enum KeyValue {
        case section([String: KeyValue])
        case string(String)
        case int(Int)
        case other
    }

    private struct BinaryReader {
        let bytes: [UInt8]
        var offset: Int

        mutating func u8() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }

        mutating func u64() -> UInt64? {
            guard let low = u32(), let high = u32() else { return nil }
            return UInt64(low) | UInt64(high) << 32
        }

        mutating func cString() -> String? {
            guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return String(decoding: bytes[offset..<end], as: UTF8.self)
        }
    }

    private static func stringTable(_ bytes: [UInt8], at offset: Int) -> [String]? {
        var reader = BinaryReader(bytes: bytes, offset: offset)
        guard let count = reader.u32() else { return nil }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let key = reader.cString() else { return nil }
            keys.append(key)
        }
        return keys
    }

    /// One section's children, read up to its end marker.
    private static func keyValues(_ reader: inout BinaryReader, keys: [String]) -> KeyValue? {
        var children: [String: KeyValue] = [:]
        while let type = reader.u8() {
            if type == 0x08 { return .section(children) }
            guard let index = reader.u32().map(Int.init), keys.indices.contains(index) else { return nil }
            let key = keys[index]
            switch type {
            case 0x00:
                guard let section = keyValues(&reader, keys: keys) else { return nil }
                children[key] = section
            case 0x01:
                guard let value = reader.cString() else { return nil }
                children[key] = .string(value)
            case 0x02:
                guard let value = reader.u32() else { return nil }
                children[key] = .int(Int(Int32(bitPattern: value)))
            case 0x03, 0x04, 0x06:  // float, pointer, colour
                reader.offset += 4
                children[key] = .other
            case 0x07, 0x0A:        // uint64, int64
                reader.offset += 8
                children[key] = .other
            default:
                return nil
            }
        }
        return nil
    }

    // MARK: - Steam's record of the answers (localconfig.vdf)

    /// The game's block in localconfig.vdf: `UserLocalConfigStore > Software >
    /// Valve > Steam > apps > <appID>` (Steam's key spelling varies in case).
    private static func gamePath(_ appID: Int) -> [String] {
        ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", String(appID)]
    }

    /// Accepted version per agreement id for `appID`.
    static func acceptedVersions(appID: Int, localConfig: String) -> [String: Int] {
        let lines = localConfig.components(separatedBy: "\n")
        guard let block = block(at: gamePath(appID), in: lines) else { return [:] }
        var versions: [String: Int] = [:]
        for (key, value) in directValues(of: block, in: lines) {
            if let version = Int(value) { versions[key] = version }
        }
        return versions
    }

    /// `localConfig` with `eulas` recorded as accepted for `appID`. Every
    /// other line stays as Steam wrote it; the game's block, and any missing
    /// parent, is created when Steam hasn't written one yet.
    static func recording(_ eulas: [SteamEula], appID: Int, in localConfig: String) -> String {
        var lines = localConfig.contains("\"UserLocalConfigStore\"")
            ? localConfig.components(separatedBy: "\n")
            : ["\"UserLocalConfigStore\"", "{", "}", ""]
        let path = gamePath(appID)

        // Create the missing tail of the path inside the deepest block that exists.
        if let existing = (1...path.count).reversed().first(where: { block(at: Array(path.prefix($0)), in: lines) != nil }),
           existing < path.count,
           let parent = block(at: Array(path.prefix(existing)), in: lines) {
            var inserted: [String] = []
            for depth in existing..<path.count {
                let indent = String(repeating: "\t", count: depth)
                inserted.append("\(indent)\"\(path[depth])\"")
                inserted.append("\(indent){")
            }
            for depth in (existing..<path.count).reversed() {
                inserted.append(String(repeating: "\t", count: depth) + "}")
            }
            lines.insert(contentsOf: inserted, at: parent.close)
        }

        guard let game = block(at: path, in: lines) else { return localConfig }
        let indent = String(repeating: "\t", count: path.count)
        for eula in eulas where eula.appID == appID {
            let line = "\(indent)\"\(eula.id)\"\t\t\"\(eula.version)\""
            let current = block(at: path, in: lines) ?? game
            if let existing = directValueLines(of: current, in: lines).first(where: { $0.key == eula.id }) {
                lines[existing.index] = line
            } else {
                lines.insert(line, at: current.close)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The `{` and `}` line indexes of the block at `path`, matched
    /// case-insensitively. Steam writes one key or brace per line. Also reads
    /// a game's cloud state (`SteamCloudStatus`).
    static func block(at path: [String], in lines: [String]) -> (open: Int, close: Int)? {
        var stack: [String] = []
        var pendingKey = ""
        var open: Int?
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "{" {
                stack.append(pendingKey)
                pendingKey = ""
                if open == nil, matches(stack, path) { open = index }
            } else if line == "}" {
                if let open, matches(stack, path) { return (open, index) }
                if !stack.isEmpty { stack.removeLast() }
            } else if WinePrefix.vdfKeyValue(from: line) == nil, line.hasPrefix("\""), line.hasSuffix("\""), line.count >= 2 {
                pendingKey = String(line.dropFirst().dropLast())
            }
        }
        return nil
    }

    private static func matches(_ stack: [String], _ path: [String]) -> Bool {
        stack.count == path.count
            && zip(stack, path).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
    }

    static func directValues(of block: (open: Int, close: Int), in lines: [String]) -> [(key: String, value: String)] {
        directValueLines(of: block, in: lines).map { ($0.key, $0.value) }
    }

    /// Key-value lines directly inside `block` (not inside nested blocks).
    private static func directValueLines(
        of block: (open: Int, close: Int), in lines: [String]
    ) -> [(index: Int, key: String, value: String)] {
        var depth = 0
        var found: [(index: Int, key: String, value: String)] = []
        for index in (block.open + 1)..<block.close {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "{" { depth += 1 } else if line == "}" { depth -= 1 }
            else if depth == 0, let pair = WinePrefix.vdfKeyValue(from: line) {
                found.append((index, pair.key, pair.value))
            }
        }
        return found
    }

    // MARK: - The agreement's text

    enum TextError: Error, LocalizedError {
        case badResponse(Int)
        case noContent

        var errorDescription: String? {
            switch self {
            case .badResponse(let status): return "Steam answered with status \(status)."
            case .noContent: return "Steam sent no agreement text."
            }
        }
    }

    /// The agreement's text in Steam's BBCode, from the page Steam's own
    /// dialog loads: `<url>?eulaLang=<language>&json=1` returns
    /// `{"title", "content", "eulaLang", "rgLanguages"}`. Public, no sign-in.
    static func text(of eula: SteamEula, language: String = "english") async throws -> String {
        guard var components = URLComponents(url: eula.url, resolvingAgainstBaseURL: false) else {
            throw TextError.noContent
        }
        components.scheme = "https"
        let query = components.queryItems ?? []
        components.queryItems = query
            + [URLQueryItem(name: "eulaLang", value: language), URLQueryItem(name: "json", value: "1")]
        guard let url = components.url else { throw TextError.noContent }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            log.warning("[text] \(eula.id): HTTP \(status)")
            throw TextError.badResponse(status)
        }
        struct Page: Decodable { let content: String? }
        guard let content = try JSONDecoder().decode(Page.self, from: data).content, !content.isEmpty else {
            throw TextError.noContent
        }
        return content
    }
}
