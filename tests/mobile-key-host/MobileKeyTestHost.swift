import SwiftUI

/// Isolated test host: no product account, network, FFI or user data lifecycle.
@main
struct MobileKeyTestHost: App {
    var body: some Scene {
        WindowGroup { Text("OrbitTerm 原生组件测试") }
    }
}
