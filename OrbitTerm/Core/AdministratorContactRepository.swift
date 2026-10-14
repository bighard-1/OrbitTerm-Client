import Foundation

extension AdministratorContactStore {
    static let shared = AdministratorContactStore(
        source: { NetworkService.shared.currentBaseURLString },
        fetch: { try await NetworkService.shared.fetchSupportContact() },
        load: { UserDefaults.standard.data(forKey: "orbitterm.support.public-contact.v1") },
        save: { UserDefaults.standard.set($0, forKey: "orbitterm.support.public-contact.v1") }
    )
}
