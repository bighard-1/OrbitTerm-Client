import Foundation
import UniformTypeIdentifiers

enum SFTPDropUploadHandler {
    static func handle(
        providers: [NSItemProvider],
        upload: @escaping @MainActor (URL) async -> Void
    ) -> Bool {
        let accepted = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !accepted.isEmpty else { return false }

        for provider in accepted {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                Task { @MainActor in
                    await upload(url)
                }
            }
        }

        return true
    }
}
