import Foundation
import SwiftUI

/// Steam profile data returned by ISteamUser/GetPlayerSummaries.
struct PlayerSummary: Decodable, Sendable, Identifiable {
    let steamID: String
    let personaName: String
    let profileURL: String
    let avatar: String
    let avatarMedium: String
    let avatarFull: String
    let personaState: Int
    let communityVisibilityState: Int
    let gameExtraInfo: String?
    let gameID: String?
    let lastLogoff: Int?
    /// Optional profile fields — present only when the profile is public and
    /// the user filled them in.
    let realName: String?
    let countryCode: String?
    /// Unix timestamp of account creation ("Member since").
    let timeCreated: Int?

    var id: String { steamID }

    enum CodingKeys: String, CodingKey {
        case steamID                  = "steamid"
        case personaName              = "personaname"
        case profileURL               = "profileurl"
        case avatar
        case avatarMedium             = "avatarmedium"
        case avatarFull               = "avatarfull"
        case personaState             = "personastate"
        case communityVisibilityState = "communityvisibilitystate"
        case gameExtraInfo            = "gameextrainfo"
        case gameID                   = "gameid"
        case lastLogoff               = "lastlogoff"
        case realName                 = "realname"
        case countryCode              = "loccountrycode"
        case timeCreated              = "timecreated"
    }

    var isOnline: Bool { personaState != 0 }
    var isPublic: Bool { communityVisibilityState == 3 }
    var isInGame: Bool { gameID != nil && !(gameID?.isEmpty ?? true) }

    var avatarFullURL: URL? { URL(string: avatarFull) }
    var avatarMediumURL: URL? { URL(string: avatarMedium) }

    var lastLogoffDate: Date? {
        guard let ts = lastLogoff, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    var accountCreatedDate: Date? {
        guard let ts = timeCreated, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// Sort priority: in-game (0) > online (1) > away-ish (2) > offline (3)
    var activitySortOrder: Int {
        if isInGame { return 0 }
        switch personaState {
        case 1, 5, 6: return 1   // online, looking to trade, looking to play
        case 2, 3, 4: return 2   // busy, away, snooze
        default:      return 3   // offline
        }
    }

    // MARK: - Persona state presentation
    //
    // Valve's personastate values (ISteamUser/GetPlayerSummaries):
    //   0 Offline · 1 Online · 2 Busy · 3 Away · 4 Snooze ·
    //   5 Looking to trade · 6 Looking to play

    /// Human-readable persona state. In-game supersedes everything.
    var personaStateText: String {
        if isInGame { return gameExtraInfo ?? "In a game" }
        switch personaState {
        case 1:  return "Online"
        case 2:  return "Busy"
        case 3:  return "Away"
        case 4:  return "Snooze"
        case 5:  return "Looking to Trade"
        case 6:  return "Looking to Play"
        default: return "Offline"
        }
    }

    /// Status dot color: in-game and online green (user direction July 12
    /// 2026 — no Steam blue), away/snooze yellow, busy red, offline gray.
    var statusColor: Color {
        if isInGame { return .green }
        switch personaState {
        case 1, 5, 6: return .green
        case 3, 4:    return .yellow
        case 2:       return .red
        default:      return Color(white: 0.45)
        }
    }
}

/// Lightweight friend relationship returned by GetFriendList.
struct SteamFriend: Decodable, Sendable {
    let steamID: String
    let relationship: String
    let friendSince: Int

    enum CodingKeys: String, CodingKey {
        case steamID      = "steamid"
        case relationship
        case friendSince  = "friend_since"
    }

    var friendSinceDate: Date? {
        guard friendSince > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(friendSince))
    }
}
