import SwiftUI

/// Keeps the add-asset footer stable across macOS and iOS while isolating its
/// layout from the larger form's type-checking and state-management concerns.
struct AddServerFooter: View {
    let isTestingConnection: Bool
    let isConnectionVerified: Bool
    let testStatus: String
    let canTestConnection: Bool
    let isSaving: Bool
    let saveButtonEnabled: Bool
    let onTest: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AddServerStatusBar(
                isTestingConnection: isTestingConnection,
                isConnectionVerified: isConnectionVerified,
                testStatus: testStatus,
                canTestConnection: canTestConnection,
                onTest: onTest
            )

            HStack(spacing: 10) {
                Button("取消", action: onCancel)
                    .buttonStyle(ThemedSecondaryButtonStyle())
                    .frame(width: 92)

                Button(isSaving ? "保存中..." : "保存并连接", action: onSave)
                    .buttonStyle(ThemedPrimaryButtonStyle())
                    .disabled(!saveButtonEnabled || isSaving)
                    .frame(width: 224)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
    }
}
