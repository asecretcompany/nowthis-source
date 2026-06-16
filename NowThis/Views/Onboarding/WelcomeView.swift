import SwiftUI

/// The first screen the user sees on fresh install.
///
/// Features a polished welcome with the app's branding and a single
/// "Get Started" call-to-action that navigates to the account type chooser.
struct WelcomeView: View {

    @State private var showAccountChooser = false
    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var buttonOpacity: Double = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                LogoSection(scale: logoScale, opacity: logoOpacity)
                Spacer().frame(height: 32)
                TitleSection(opacity: textOpacity)
                Spacer()
                GetStartedButton(opacity: buttonOpacity) {
                    showAccountChooser = true
                }
                Spacer().frame(height: 60)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BackgroundGradient())
            .navigationDestination(isPresented: $showAccountChooser) {
                AccountTypeChooserView()
            }
            .onAppear { animateEntrance() }
        }
    }

    private func animateEntrance() {
        withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.1)) {
            logoScale = 1.0
            logoOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.6).delay(0.4)) {
            textOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.6).delay(0.7)) {
            buttonOpacity = 1.0
        }
    }
}

// MARK: - Sub-views

private struct LogoSection: View {
    let scale: CGFloat
    let opacity: Double

    var body: some View {
        Image("AppLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            .scaleEffect(scale)
            .opacity(opacity)
            .accessibilityLabel("NowThis logo")
            .accessibilityAddTraits(.isImage)
            .accessibilityRemoveTraits(.isSelected)
    }
}

private struct TitleSection: View {
    let opacity: Double

    var body: some View {
        VStack(spacing: 12) {
            Text("NowThis")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Your tasks. Your device. Your privacy.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .opacity(opacity)
        .accessibilityElement(children: .combine)
    }
}

private struct GetStartedButton: View {
    let opacity: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Get Started")
                .font(.headline)
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        }
        .padding(.horizontal, 40)
        .opacity(opacity)
    }
}

private struct BackgroundGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.0, green: 0.45, blue: 1.0),
                Color(red: 0.0, green: 0.6, blue: 1.0),
                Color(red: 0.0, green: 0.75, blue: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

#Preview {
    WelcomeView()
}
