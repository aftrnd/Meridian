import Foundation

/// What game engine/framework the game uses.
/// Used to group games and apply engine-wide fixes via factory methods.
enum GameEngine: String {
    case unity
    case unreal
    case godot
    case custom
    case unknown
}

/// What DirectX/Vulkan API the game renders with.
/// Drives DXMT vs DXVK selection at launch.
enum GraphicsAPI: String {
    case dx11      // DirectX 11 → DXMT → Metal
    case dx12      // DirectX 12 → DXVK/MoltenVK → Metal
    case vulkan    // Vulkan → MoltenVK → Metal
    case unknown
}

/// How well the game runs under Meridian.
/// Enables UI compatibility badges and batch management.
enum CompatStatus: String {
    case verified   // Confirmed working end-to-end
    case playable   // Runs with minor issues
    case launches   // Starts but has significant problems
    case broken     // Crashes during startup or gameplay
    case untested   // Not yet tested in Meridian
}

/// Per-game compatibility profile.
///
/// Stores everything Meridian needs to correctly launch a specific game:
/// engine requirements, DLL overrides, renderer preference, and documentation.
///
/// Use the factory methods (`.unity()`, `.unreal()`, `.custom()`) to create
/// profiles — they encode engine-specific defaults so individual game entries
/// only need to specify what differs from the engine norm.
struct GameProfile {
    let appID: Int
    let name: String

    let gameEngine: GameEngine
    let graphicsAPI: GraphicsAPI
    let status: CompatStatus

    /// WINEDLLOVERRIDES value. nil = use engine default.
    let dllOverrides: String?

    /// Metal renderer preference.
    enum DXMTMode {
        case auto          // Use DXMT if available
        case required      // Must use DXMT or game will not render correctly
        case disabled      // Force Wine's built-in d3d11, bypassing DXMT
    }
    let dxmtMode: DXMTMode

    /// Extra environment variables specific to this game.
    let extraEnv: [String: String]

    /// Command-line arguments appended to the game executable when launching.
    /// Use for engine-level flags like `-force-d3d11` (Unity) that change
    /// rendering path without needing DLL overrides.
    let launchArgs: [String]

    /// When true, skip launching steam.exe for DRM even if steam_api64.dll is
    /// detected in the game directory. Use for games that have the DLL bundled
    /// but handle SteamAPI_Init() failure gracefully without needing a live
    /// Steam IPC socket. Verified by running the game directly without steam.exe.
    let skipSteamDRM: Bool

    /// Engine tag when this profile was last verified (e.g. "v1.0.11-engine").
    let verifiedWith: String?

    /// Human-readable notes documenting the root cause and fix.
    let notes: String

    init(
        appID: Int,
        name: String,
        gameEngine: GameEngine = .unknown,
        graphicsAPI: GraphicsAPI = .unknown,
        status: CompatStatus = .untested,
        dllOverrides: String? = nil,
        dxmtMode: DXMTMode = .auto,
        extraEnv: [String: String] = [:],
        launchArgs: [String] = [],
        skipSteamDRM: Bool = false,
        verifiedWith: String? = nil,
        notes: String = ""
    ) {
        self.appID = appID
        self.name = name
        self.gameEngine = gameEngine
        self.graphicsAPI = graphicsAPI
        self.status = status
        self.dllOverrides = dllOverrides
        self.dxmtMode = dxmtMode
        self.extraEnv = extraEnv
        self.launchArgs = launchArgs
        self.skipSteamDRM = skipSteamDRM
        self.verifiedWith = verifiedWith
        self.notes = notes
    }

    // MARK: - Factory methods

    /// Unity game preset.
    /// Defaults: graphicsAPI=.dx11. All params overridable per-game.
    static func unity(
        appID: Int,
        name: String,
        status: CompatStatus = .untested,
        graphicsAPI: GraphicsAPI = .dx11,
        dxmtMode: DXMTMode = .auto,
        dllOverrides: String? = nil,
        extraEnv: [String: String] = [:],
        launchArgs: [String] = [],
        skipSteamDRM: Bool = false,
        verifiedWith: String? = nil,
        notes: String
    ) -> GameProfile {
        GameProfile(
            appID: appID, name: name,
            gameEngine: .unity, graphicsAPI: graphicsAPI, status: status,
            dllOverrides: dllOverrides,
            dxmtMode: dxmtMode,
            extraEnv: extraEnv, launchArgs: launchArgs,
            skipSteamDRM: skipSteamDRM,
            verifiedWith: verifiedWith, notes: notes
        )
    }

    static func unreal(
        appID: Int,
        name: String,
        status: CompatStatus = .untested,
        graphicsAPI: GraphicsAPI = .dx11,
        dxmtMode: DXMTMode = .auto,
        dllOverrides: String? = nil,
        extraEnv: [String: String] = [:],
        launchArgs: [String] = [],
        skipSteamDRM: Bool = false,
        verifiedWith: String? = nil,
        notes: String
    ) -> GameProfile {
        GameProfile(
            appID: appID, name: name,
            gameEngine: .unreal, graphicsAPI: graphicsAPI, status: status,
            dllOverrides: dllOverrides,
            dxmtMode: dxmtMode,
            extraEnv: extraEnv, launchArgs: launchArgs,
            skipSteamDRM: skipSteamDRM,
            verifiedWith: verifiedWith, notes: notes
        )
    }

    static func custom(
        appID: Int,
        name: String,
        status: CompatStatus = .untested,
        graphicsAPI: GraphicsAPI = .unknown,
        dxmtMode: DXMTMode = .auto,
        dllOverrides: String? = nil,
        extraEnv: [String: String] = [:],
        launchArgs: [String] = [],
        skipSteamDRM: Bool = false,
        verifiedWith: String? = nil,
        notes: String
    ) -> GameProfile {
        GameProfile(
            appID: appID, name: name,
            gameEngine: .custom, graphicsAPI: graphicsAPI, status: status,
            dllOverrides: dllOverrides,
            dxmtMode: dxmtMode,
            extraEnv: extraEnv, launchArgs: launchArgs,
            skipSteamDRM: skipSteamDRM,
            verifiedWith: verifiedWith, notes: notes
        )
    }
}
