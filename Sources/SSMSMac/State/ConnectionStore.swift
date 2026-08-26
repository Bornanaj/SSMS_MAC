import Foundation
import SQLServerKit

/// Persists saved connections to `~/Library/Application Support/SSMS for Mac/connections.json`
/// and keeps their passwords in the keychain.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSMS for Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("connections.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        profiles = (try? decoder.decode([ConnectionProfile].self, from: data)) ?? []
        profiles.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Passwords live in the keychain; nothing sensitive is written here.
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func save(_ profile: ConnectionProfile, password: String?) {
        var updated = profile
        updated.lastUsed = Date()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = updated
        } else {
            profiles.append(updated)
        }
        if updated.savePassword, let password, !password.isEmpty {
            Keychain.setPassword(password, for: updated.credentialKey)
        } else if !updated.savePassword {
            Keychain.removePassword(for: updated.credentialKey)
        }
        profiles.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        persist()
    }

    func remove(_ profile: ConnectionProfile) {
        Keychain.removePassword(for: profile.credentialKey)
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    /// Synchronous read. Only safe away from the main thread; views use the async form.
    nonisolated func password(for profile: ConnectionProfile) -> String? {
        Keychain.password(for: profile.credentialKey)
    }

    func password(for profile: ConnectionProfile) async -> String? {
        await Keychain.password(for: profile.credentialKey)
    }

    /// Most recently used servers, for the Connect dialog's server combo box.
    var recentServers: [String] {
        var seen = Set<String>()
        return profiles.compactMap { profile in
            let key = profile.server.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return profile.server
        }
    }
}
