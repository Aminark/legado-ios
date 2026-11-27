import SwiftUI

/// Breaks SwiftUI's deeply nested `ModifiedContent<...>` generic tree into
/// shallow, independently evaluated stages so real iOS devices (whose main
/// thread stack is capped around 1 MB) do not overflow while opening or
/// re-evaluating `ReaderView`.
struct ReaderStageBoundary<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        AnyView(content)
    }
}

extension View {
    /// Caps SwiftUI's compile-time and runtime generic modifier depth at this
    /// boundary without altering view identity or layout semantics.
    func readerStageBoundary() -> some View {
        ReaderStageBoundary { self }
    }
}

/// Encapsulates system chrome modifiers (color scheme, bars, status bar,
/// home indicator, and interactive pop gesture) into a single shallow stage.
struct ReaderSystemChromeStage: ViewModifier {
    let colorScheme: ColorScheme?
    let hidesStatusBar: Bool
    let hidesHomeIndicator: Bool

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(colorScheme)
            .readingTabBarHidden()
            .navigationBarHidden(true)
            .navigationBarBackButtonHidden(true)
            .background {
                ReaderInteractivePopEnabler()
                    .frame(width: 0, height: 0)
            }
            .statusBarHidden(hidesStatusBar)
            .readingHomeIndicatorHidden(hidesHomeIndicator)
            .readerStageBoundary()
    }
}

/// Encapsulates top/bottom reader menu overlays and top-level setting error
/// presentation into an isolated generic stage.
struct ReaderOverlayChromeStage<TopChrome: View, BottomChrome: View>: ViewModifier {
    let showsMenu: Bool
    @Binding var settingErrorPresented: Bool
    let settingErrorMessage: String
    let clearSettingError: () -> Void
    @ViewBuilder let topChrome: () -> TopChrome
    @ViewBuilder let bottomChrome: () -> BottomChrome

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if showsMenu {
                    topChrome()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                if showsMenu {
                    bottomChrome()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: showsMenu)
            .alert("阅读设置未保存", isPresented: $settingErrorPresented) {
                Button("好", role: .cancel, action: clearSettingError)
            } message: {
                Text(settingErrorMessage)
            }
            .readerStageBoundary()
    }
}
