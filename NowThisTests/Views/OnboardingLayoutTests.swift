import SwiftUI
import UIKit
import Testing
@testable import NowThis

@Suite("Onboarding accessibility layout", .serialized)
@MainActor
struct OnboardingLayoutTests {
    @Test("Choose Mode keeps oversized content scrollable in narrow and short windows", arguments: [false, true])
    func oversizedModeChoicesRemainReachable(shortWindow: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let size = shortWindow ? CGSize(width: 594, height: 300) : CGSize(width: 382, height: 550)
        let root = AccountTypeChooserView()
            .modelContainer(container)
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: size.width, height: size.height)
        let controller = UIHostingController(rootView: root)
        controller.safeAreaRegions = []
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
        }

        let scroll = try #require(scrollView(in: controller.view),
            "Choose Mode must provide vertical scrolling when accessibility text exceeds the viewport")
        #expect(scroll.bounds.height > 0)
        #expect(scroll.contentSize.height > scroll.bounds.height,
                "The oversized page must overflow its constrained viewport")
        #expect(scroll.contentSize.width <= scroll.bounds.width + 1,
                "Reading the choices must not require horizontal scrolling")
        let bottom = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        window.layoutIfNeeded()
        #expect(abs(scroll.contentOffset.y - bottom) < 1,
                "The bottom of the onboarding page must be reachable")
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}
