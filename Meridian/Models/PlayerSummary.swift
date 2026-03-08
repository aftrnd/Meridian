import Foundation

/// Steam profile data returned by ISteamUser/GetPlayerSummaries.
struct PlayerSummary: Decodable, Sendable {
    let steamID: String
    let personaName: String
    let profileURL: String
    let avatar: String
    let avatarMedium: String
    let avatarFull: String
    let personaState: Int
    let communityVisibilityState: Int

    enum CodingKeys: String, CodingKey {
        case steamID                 = "steamid"
        case personaName             = "personaname"
        case profileURL              = "profileurl"
        case avatar
        case avatarMedium            = "avatarmedium"
        case avatarFull              = "avatarfull"
        case personaState            = "personastate"
        case communityVisibilityState = "communityvisibilitystate"
    }

    var isOnline: Bool { personaState != 0 }
    var isPublic: Bool { communityVisibilityState == 3 }

    var avatarFullURL: URL? { URL(string: avatarFull) }
}
