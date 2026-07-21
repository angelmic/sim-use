// SPDX-License-Identifier: Apache-2.0
//
// Deterministic focus fixture for the tvOS E2E suite
// (Tests/TVOSRemoteTests.swift, driven by scripts/test-runner-tvos.sh).
//
// A 3x2 button grid with a pinned default focus (Alpha) and a status line
// that records the last activated button, so `sim-use tvos remote`
// movement and `select` activation can be asserted from the outline alone:
//
//     Last: none                     <- StaticText, updated by select
//     [Alpha] [Bravo]   [Charlie]    <- default focus on Alpha
//     [Delta] [Echo]    [Foxtrot]
//
// Grid geometry is part of the test contract: right of Alpha is Bravo,
// below Bravo is Echo. Keep labels and layout stable or update the suite.

import SwiftUI

@main
struct SimUsePlaygroundTVApp: App {
    var body: some Scene {
        WindowGroup {
            FocusGridView()
        }
    }
}

struct FocusGridView: View {
    @State private var lastAction = "none"
    @FocusState private var focusedButton: String?

    private let rows: [[String]] = [
        ["Alpha", "Bravo", "Charlie"],
        ["Delta", "Echo", "Foxtrot"],
    ]

    var body: some View {
        VStack(spacing: 60) {
            Text("Last: \(lastAction)")
                .font(.title2)
                .accessibilityIdentifier("last-action")

            ForEach(rows, id: \.first) { row in
                HStack(spacing: 60) {
                    ForEach(row, id: \.self) { name in
                        Button(name) {
                            lastAction = name
                        }
                        .focused($focusedButton, equals: name)
                        .accessibilityIdentifier("focus-\(name.lowercased())")
                    }
                }
            }
        }
        .padding(80)
        .defaultFocus($focusedButton, "Alpha")
    }
}
