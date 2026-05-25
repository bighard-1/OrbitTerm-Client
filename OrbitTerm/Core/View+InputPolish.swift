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
}
#endif

#if !os(iOS)
extension View {
    func applyKeyboardDismissToolbar(title: String = "收起键盘") -> some View {
        self
    }
}
#endif
