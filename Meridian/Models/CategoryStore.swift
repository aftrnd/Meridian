import Foundation
import Observation

// MARK: - Data Types

/// A named playlist of game app IDs.
struct GameCategory: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    /// SF Symbol name shown next to the playlist in the sidebar.
    var icon: String
    /// Steam app IDs belonging to this category.
    var appIDs: [Int]
    /// nil = top-level; non-nil = lives inside this folder.
    var folderID: UUID?
    /// Used to preserve user-defined ordering within a level.
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "folder",
        appIDs: [Int] = [],
        folderID: UUID? = nil,
        sortOrder: Int = 0
    ) {
        self.id        = id
        self.name      = name
        self.icon      = icon
        self.appIDs    = appIDs
        self.folderID  = folderID
        self.sortOrder = sortOrder
    }
}

/// A collapsible folder that groups zero or more GameCategory playlists.
struct CategoryFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var isExpanded: Bool
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        isExpanded: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id         = id
        self.name       = name
        self.isExpanded = isExpanded
        self.sortOrder  = sortOrder
    }
}

// MARK: - Store

/// Owns all user-created category folders and playlists.
/// Persisted to UserDefaults as JSON blobs.
@Observable
final class CategoryStore {

    private(set) var folders:    [CategoryFolder] = []
    private(set) var categories: [GameCategory]   = []

    init() { load() }

    // MARK: - Queries

    var sortedFolders: [CategoryFolder] {
        folders.sorted { $0.sortOrder < $1.sortOrder }
    }

    func topLevelCategories() -> [GameCategory] {
        categories
            .filter { $0.folderID == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func categories(inFolder folderID: UUID) -> [GameCategory] {
        categories
            .filter { $0.folderID == folderID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func category(id: UUID) -> GameCategory? {
        categories.first { $0.id == id }
    }

    func folder(id: UUID) -> CategoryFolder? {
        folders.first { $0.id == id }
    }

    /// Returns the games from `allGames` that belong to the given category,
    /// preserving the order in which they were added.
    func games(in categoryID: UUID, from allGames: [Game]) -> [Game] {
        guard let cat = category(id: categoryID) else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: allGames.map { ($0.id, $0) })
        return cat.appIDs.compactMap { lookup[$0] }
    }

    func containsGame(appID: Int, in categoryID: UUID) -> Bool {
        category(id: categoryID)?.appIDs.contains(appID) ?? false
    }

    // MARK: - Folder mutations

    /// Creates a new folder and returns its ID.
    @discardableResult
    func createFolder(name: String) -> UUID {
        let order = (folders.map(\.sortOrder).max() ?? -1) + 1
        let f = CategoryFolder(name: name, sortOrder: order)
        folders.append(f)
        save()
        return f.id
    }

    func renameFolder(id: UUID, name: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].name = name
        save()
    }

    /// Deletes a folder. Categories inside are promoted to top-level.
    func deleteFolder(id: UUID) {
        for idx in categories.indices where categories[idx].folderID == id {
            categories[idx].folderID = nil
        }
        folders.removeAll { $0.id == id }
        save()
    }

    func toggleFolderExpanded(id: UUID) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].isExpanded.toggle()
        save()
    }

    // MARK: - Category mutations

    /// Creates a new category and returns its ID.
    @discardableResult
    func createCategory(name: String, folderID: UUID? = nil) -> UUID {
        let peers = categories.filter { $0.folderID == folderID }
        let order = (peers.map(\.sortOrder).max() ?? -1) + 1
        let cat = GameCategory(name: name, folderID: folderID, sortOrder: order)
        categories.append(cat)
        save()
        return cat.id
    }

    func renameCategory(id: UUID, name: String) {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[idx].name = name
        save()
    }

    func changeIcon(id: UUID, icon: String) {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[idx].icon = icon
        save()
    }

    func deleteCategory(id: UUID) {
        categories.removeAll { $0.id == id }
        save()
    }

    func moveCategory(id: UUID, toFolder folderID: UUID?) {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[idx].folderID = folderID
        save()
    }

    // MARK: - Game membership

    func addGame(appID: Int, to categoryID: UUID) {
        guard let idx = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        guard !categories[idx].appIDs.contains(appID) else { return }
        categories[idx].appIDs.append(appID)
        save()
    }

    func removeGame(appID: Int, from categoryID: UUID) {
        guard let idx = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        categories[idx].appIDs.removeAll { $0 == appID }
        save()
    }

    // MARK: - Persistence

    private func load() {
        if let data    = UserDefaults.standard.data(forKey: "categoryFolders"),
           let decoded = try? JSONDecoder().decode([CategoryFolder].self, from: data) {
            folders = decoded
        }
        if let data    = UserDefaults.standard.data(forKey: "gameCategories"),
           let decoded = try? JSONDecoder().decode([GameCategory].self, from: data) {
            categories = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: "categoryFolders")
        }
        if let data = try? JSONEncoder().encode(categories) {
            UserDefaults.standard.set(data, forKey: "gameCategories")
        }
    }
}
