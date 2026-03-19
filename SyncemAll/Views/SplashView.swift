import SwiftUI

struct SplashView: View {
    @State private var iconScale: CGFloat = 0.5
    @State private var iconOpacity: Double = 0
    @State private var iconRotation: Double = -180
    @State private var iconOffsetX: CGFloat = 0
    @State private var titleOpacity: Double = 0
    @State private var titleOffsetX: CGFloat = 0
    @State private var finished = false

    var body: some View {
        if finished {
            ContentView()
                .transition(.opacity)
        } else {
            ZStack {
                Color(red: 0.11, green: 0.11, blue: 0.18) // #1C1C2E
                    .ignoresSafeArea()

                VStack(spacing: 28) {
                    Image("SplashIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                        .rotationEffect(.degrees(iconRotation))
                        .scaleEffect(iconScale)
                        .opacity(iconOpacity)
                        .offset(x: iconOffsetX)

                    Text("Sync 'em All")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .opacity(titleOpacity)
                        .offset(x: titleOffsetX)
                }
            }
            .onAppear {
                // Spin in
                withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                    iconScale = 1.0
                    iconOpacity = 1.0
                    iconRotation = 0
                }
                // Title fade in
                withAnimation(.easeIn(duration: 0.4).delay(0.3)) {
                    titleOpacity = 1.0
                }
                // Zip offscreen to the right
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    withAnimation(.easeIn(duration: 0.25)) {
                        iconOffsetX = 500
                        titleOffsetX = -500
                    }
                }
                // Transition to main app
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        finished = true
                    }
                }
            }
        }
    }
}
