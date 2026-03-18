//
//  ContentView.swift
//  TheSilentCoach
//
//  Created for ComputoUbicuoTSC
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            // Fondo con gradiente verde
            LinearGradient(
                colors: [
                    Color(red: 0.2, green: 0.65, blue: 0.35),
                    Color(red: 0.1, green: 0.45, blue: 0.25)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Título principal
                Text("The Silent Coach")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                // Descripción
                Text("The dashboard that takes care of you")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                // Botón
                Button(action: {
                    // Acción para el botón
                }) {
                    HStack(spacing: 12) {
                        Text("Lets get started")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)

                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Color.white.opacity(0.2)
                    )
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
    }
}

#Preview {
    ContentView()
}
