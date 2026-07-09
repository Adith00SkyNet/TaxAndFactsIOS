//
//  TaxAndFactsApp.swift
//  TaxAndFacts
//
//  Created by ADITH on 29/06/26.
//

import SwiftUI

@main
struct TaxAndFactsApp: App {
    var body: some Scene {
        WindowGroup {
            SplashRootView()
        }
    }
}

private struct SplashRootView: View {
    @State private var isShowingSplash = true

    var body: some View {
        ZStack {
            ContentView()

            if isShowingSplash {
                SplashScreenView()
                    .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.4))

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    isShowingSplash = false
                }
            }
        }
    }
}

private struct SplashScreenView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            Image("Splash")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260)
                .padding(.horizontal, 40)
                .accessibilityHidden(true)
        }
    }
}
