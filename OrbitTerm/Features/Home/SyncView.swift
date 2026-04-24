import SwiftUI

struct SyncView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var syncService = SyncService()

    @State private var plaintext: String = "{\"servers\":[]}"
    @State private var localCounter: Int = 1

    var body: some View {
        Form {
            Section("本地配置明文") {
                TextEditor(text: $plaintext)
                    .frame(minHeight: 120)
            }

            Section("版本号") {
                Stepper("设备计数: \(localCounter)", value: $localCounter, in: 1 ... 9999)
            }

            Section("同步") {
                Button("上传到云端") {
                    Task { await upload() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(plaintext.isEmpty)

                Text(syncService.lastSyncMessage)
                    .foregroundStyle(syncService.lastSyncMessage.hasPrefix("同步成功") ? .green : .secondary)
            }
        }
        .navigationTitle("云同步")
    }

    private func upload() async {
        guard let token = session.readToken(),
              let masterPassword = session.readMasterPassword() else {
            syncService.lastSyncMessage = "同步失败: 缺少登录态或主密码"
            return
        }

        let vectorClock = ["ios": localCounter]
        _ = await syncService.uploadEncryptedConfig(
            token: token,
            masterPassword: masterPassword,
            plaintextConfig: plaintext,
            vectorClock: vectorClock
        )
    }
}
