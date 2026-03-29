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
/// Drives DXMT vs GPTK D3DMetal vs native Vulkan selection at launch.
enum GraphicsAPI: String {
    case dx11      // DirectX 11 → DXMT → Metal
    case dx12      // DirectX 12 → GPTK D3DMetal → Metal
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

    /// Whether this game requires the CrossOver 24+ engine (CX Preview locally)
    /// to avoid abort stubs missing from Wine 8.0.1.
    let requiresCXEngine: Bool

    /// Metal renderer preference.
    enum DXMTMode {
        case auto          // Use DXMT if available
        case required      // Must use DXMT or game will not render correctly
        case disabled      // Force Wine's built-in d3d11, bypassing DXMT
    }
    let dxmtMode: DXMTMode

    /// Whether to install DXMT DLLs into the Wine prefix system32 before launch.
    /// Needed when the CX engine is active (its built-in d3d11 takes priority over
    /// WINEDLLPATH, so DXMT must be physically in system32 to win).
    let requiresDXMTInSystem32: Bool

    /// Extra environment variables specific to this game.
    let extraEnv: [String: String]

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
        requiresCXEngine: Bool = false,
        dxmtMode: DXMTMode = .auto,
        requiresDXMTInSystem32: Bool = false,
        extraEnv: [String: String] = [:],
        verifiedWith: String? = nil,
        notes: String = ""
    ) {
        self.appID = appID
        self.name = name
        self.gameEngine = gameEngine
        self.graphicsAPI = graphicsAPI
        self.status = status
        self.dllOverrides = dllOverrides
        self.requiresCXEngine = requiresCXEngine
        self.dxmtMode = dxmtMode
        self.requiresDXMTInSystem32 = requiresDXMTInSystem32
        self.extraEnv = extraEnv
        self.verifiedWith = verifiedWith
        self.notes = notes
    }

    // MARK: - Factory methods

    /// Unity game preset.
    /// Defaults: requiresCXEngine=true (IsMouseInPointerEnabled abort stubs),
    /// requiresDXMTInSystem32=true (CX wineloader ignores WINEDLLPATH),
    /// graphicsAPI=.dx11. All params overridable per-game.
    static func unity(
        appID: Int,
        name: String,
        status: CompatStatus = .untested,
        graphicsAPI: GraphicsAPI = .dx11,
        dxmtMode: DXMTMode = .auto,
        requiresCXEngine: Bool = true,
        requiresDXMTInSystem32: Bool = true,
        dllOverrides: String? = nil,
        extraEnv: [String: String] = [:],
        verifiedWith: String? = nil,
        notes: String
    ) -> GameProfile {
        GameProfile(
            appID: appID, name: name,
            gameEngine: .unity, graphicsAPI: graphicsAPI, status: status,
            dllOverrides: dllOverrides, requiresCXEngine: requiresCXEngine,
            dxmtMode: dxmtMode, requiresDXMTInSystem32: requiresDXMTInSystem32,
            extraEnv: extraEnv, verifiedWith: verifiedWith, notes: notes
        )
    }

    /// Unreal Engine game preset.
    /// Defaults: requiresCXEngine=true, requiresDXMTInSystem32=true,
    /// graphicsAPI=.dx11. All params overridable per-game.
    static func unreal(
        appID: Int,
        name: String,
        status: CompatStatus = .untested,
        graphicsAPI: GraphicsAPI = .dx11,
        dxmtMode: DXMTMode = .auto,
        requiresCXEngine: Bool = true,
        requiresDXMTInSystem32: Bool = true,
        dllOverrides: String? = nil,
        extraEnv: [String: String] = [:],
        verifiedWith: String? = nil,
        notes: String
    ) -> GameProfile {
        GameProfile(
            appID: appID, name: name,
            gameEngine: .unreal, graphicsAPI: graphicsAPI, status: status,
            dllOverrides: dllOverrides, requiresCXEngine: requiresCXEngine,
            dxmtMode: dxmtMode, requiresDXMTInSystem32: requiresDXMTInSystem32,
            extraEnv: extraEnv, verifiedWith: verifiedWith, notes: notes
        )
    }

    /// Custom/unknown engine game preset.
    /// Defaults: requiresCXEngine=false, requiresDXMTInSystem32=false.
    /// Override per-game when the custom engine needs CX stubs or DXMT.
    static func custom(
        appID: Int,
        name: String,
        status: CompatStatus = .untested,
        graphicsAPI: GraphicsAPI = .unknown,
        dxmtMode: DXMTMode = .auto,
        requiresCXEngine: Bool = false,
        requiresDXMTInSystem32: Bool = false,
        dllOverrides: String? = nil,
        extraEnv: [String: String] = [:],
        verifiedWith: String? = nil,
        notes: String
    ) -> GameProfile {
        GameProfile(
            appID: appID, name: name,
            gameEngine: .custom, graphicsAPI: graphicsAPI, status: status,
            dllOverrides: dllOverrides, requiresCXEngine: requiresCXEngine,
            dxmtMode: dxmtMode, requiresDXMTInSystem32: requiresDXMTInSystem32,
            extraEnv: extraEnv, verifiedWith: verifiedWith, notes: notes
        )
    }
}
