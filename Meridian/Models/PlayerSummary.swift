import Foundation

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

    /// Sort priority: in-game (0) > online (1) > offline (2)
    var activitySortOrder: Int {
        if isInGame { return 0 }
        if isOnline { return 1 }
        return 2
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
}
