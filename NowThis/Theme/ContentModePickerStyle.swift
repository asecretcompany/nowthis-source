import SwiftUI

struct ContentModePickerStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.pickerStyle(.tabs)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}

extension View {
    func contentModePickerStyle() -> some View {
        modifier(ContentModePickerStyle())
    }
}
