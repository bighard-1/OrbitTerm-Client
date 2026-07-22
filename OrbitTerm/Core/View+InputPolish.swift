import SwiftUI

extension View {
    @ViewBuilder
    func applyInputPolish() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }
}

#if os(iOS)
extension View {
    func applyKeyboardDismissToolbar(title: String = "收起键盘") -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(title) {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
            }
        }
    }

    /// TerminalView installs its own UIKit input accessory. Applying SwiftUI's
    /// keyboard toolbar at the same time makes UIKit lay out two competing
    /// accessory regions, which can clip the terminal-only shortcuts.
    @ViewBuilder
    func applyKeyboardDismissToolbar(
        enabled: Bool,
        title: String = "收起键盘"
    ) -> some View {
        if enabled {
            applyKeyboardDismissToolbar(title: title)
        } else {
            self
        }
    }
}
#endif

#if !os(iOS)
extension View {
    func applyKeyboardDismissToolbar(title: String = "收起键盘") -> some View {
        self
    }
}
#endif
