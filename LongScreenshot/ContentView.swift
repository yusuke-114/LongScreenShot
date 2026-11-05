import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            LongScreenshotWindowGlassConfigurator()
                .frame(width: 0, height: 0)

            LongScreenshotWindowBackdrop()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollingCaptureView()
        }
        .frame(width: 820, height: 500)
    }
}

#Preview {
    ContentView()
        .environment(ScrollingCaptureCoordinator())
}
