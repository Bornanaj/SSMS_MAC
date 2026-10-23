import Foundation
import SwiftUI
import SQLServerKit
import TDSKit

/// Holds one connection per instance a plan has to touch, at the same time.
///
/// Availability group work spans instances: the failover runs on the replica taking
/// over, the join on the new secondary, the resume on whichever replica is behind. A
/// session already open in the app is reused; anything else is dialled with the
/// credentials of the connection the plan came from, which is usually right because the
/// replicas of a group tend to share a login. When it is not, the address and the login
/// can be corrected per instance before connecting.
@MainActor
final class ReplicaConnectionBroker: ObservableObject {

    enum State: Equatable {
        case notConnected
        case connecting
        /// A session the app already had open; the broker must not close it.
        case reused
        case connected
        case failed(String)

        var isUsable: Bool { self == .reused || self == .connected }

        var label: String {
            switch self {
            case .notConnected: return "Not connected"
            case .connecting: return "Connecting…"
            case .reused: return "Already connected"
            case .connected: return "Connected"
            case .failed: return "Failed"
            }
        }

        var detail: String {
            if case .failed(let message) = self { return message }
            return ""
        }
    }

    struct Target: Identifiable {
        var id: String { instance.lowercased() }
        /// The instance as the engine names it, which is what a plan's steps carry.
        var instance: String
        /// What to dial. Defaults to the instance name; a replica reachable only by a
        /// different address or port is corrected here.
        var address: String
        var username: String
        var password: String
        var state: State = .notConnected
        /// Set when the session is the broker's own, so it can be closed again.
        var ownsSession = false
    }

    @Published private(set) var targets: [Target] = []

    private var sessions: [String: SQLServerSession] = [:]
    private let template: ConnectionProfile
    private let templatePassword: String
    private unowned let app: AppState

    init(app: AppState, template: ConnectionProfile, templatePassword: String,
         instances: [String]) {
        self.app = app
        self.template = template
        self.templatePassword = templatePassword
        self.targets = instances.map { instance in
            Target(instance: instance,
                   address: instance,
                   username: template.username,
                   password: templatePassword)
        }
        adoptExistingSessions()
    }

    /// An instance the app is already connected to needs no second connection, and its
    /// session must outlive this broker.
    private func adoptExistingSessions() {
        for index in targets.indices {
            let instance = targets[index].instance
            guard let server = app.servers.first(where: { matches($0, instance: instance) })
            else { continue }
            sessions[key(instance)] = server.session
            targets[index].state = .reused
            targets[index].ownsSession = false
        }
    }

    private func matches(_ server: ConnectedServer, instance: String) -> Bool {
        if server.serverInfo.serverName.caseInsensitiveCompare(instance) == .orderedSame {
            return true
        }
        // A replica named NODE2\SQL2022 is reached as that host and instance, and the
        // profile may have been typed either way around.
        return server.profile.server.caseInsensitiveCompare(instance) == .orderedSame
            || server.displayName.caseInsensitiveCompare(instance) == .orderedSame
    }

    private func key(_ instance: String) -> String { instance.lowercased() }

    func session(for instance: String) -> SQLServerSession? {
        sessions[key(instance)]
    }

    func state(for instance: String) -> State {
        targets.first { $0.id == key(instance) }?.state ?? .notConnected
    }

    func setAddress(_ address: String, for instance: String) {
        guard let index = targets.firstIndex(where: { $0.id == key(instance) }) else { return }
        targets[index].address = address
    }

    func setUsername(_ username: String, for instance: String) {
        guard let index = targets.firstIndex(where: { $0.id == key(instance) }) else { return }
        targets[index].username = username
    }

    func setPassword(_ password: String, for instance: String) {
        guard let index = targets.firstIndex(where: { $0.id == key(instance) }) else { return }
        targets[index].password = password
    }

    var allConnected: Bool { targets.allSatisfy { $0.state.isUsable } }

    @discardableResult
    func connect(instance: String) async -> Bool {
        guard let index = targets.firstIndex(where: { $0.id == key(instance) }) else { return false }
        if targets[index].state.isUsable { return true }

        targets[index].state = .connecting
        var profile = template
        profile.id = UUID()
        profile.name = ""
        profile.discoveredServerName = nil
        profile.server = targets[index].address.isEmpty
            ? targets[index].instance
            : targets[index].address
        profile.username = targets[index].username
        // The plan's statements are server scoped, so the connection lands in master
        // rather than in whatever database the original connection was using.
        profile.database = "master"

        do {
            let session = try await SQLServerSession.connect(
                profile: profile,
                password: targets[index].password.isEmpty ? nil : targets[index].password)
            let info = await session.serverInfo
            // Connecting to the wrong box is the one mistake that would make a plan do
            // its work in the wrong place, so the name is checked rather than assumed.
            guard info.serverName.isEmpty
                    || info.serverName.caseInsensitiveCompare(targets[index].instance)
                        == .orderedSame else {
                await session.close()
                targets[index].state = .failed(
                    "That address answers as \(info.serverName), not \(targets[index].instance).")
                return false
            }
            sessions[key(instance)] = session
            targets[index].state = .connected
            targets[index].ownsSession = true
            return true
        } catch {
            targets[index].state = .failed(String(describing: error))
            return false
        }
    }

    func connectAll() async {
        for target in targets where !target.state.isUsable {
            await connect(instance: target.instance)
        }
    }

    /// Closes only what this broker opened: a session borrowed from the app stays.
    func closeOwnedSessions() async {
        for target in targets where target.ownsSession {
            if let session = sessions.removeValue(forKey: target.id) {
                await session.close()
            }
        }
        for index in targets.indices where targets[index].ownsSession {
            targets[index].state = .notConnected
            targets[index].ownsSession = false
        }
    }
}
