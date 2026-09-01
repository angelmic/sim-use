// SPDX-License-Identifier: Apache-2.0
//
// Deterministic fixture for the tvOS E2E suite
// (Tests/TVOSRemoteTests.swift, driven by scripts/test-runner-tvos.sh).
//
// Mirrors the iOS Playground layout: a root menu of test screens, each
// reachable directly via `--launch-arg screen=<name>` so suites don't
// depend on one another's navigation state. Screens and their contracts:
//
//   grid       3x2 button grid, default focus pinned on Alpha; a
//              "Last: <action>" line records select activations and
//              play-pause presses.
//                  [Alpha] [Bravo]   [Charlie]
//                  [Delta] [Echo]    [Foxtrot]
//              Right of Alpha is Bravo, below Bravo is Echo, and Alpha
//              sits on the top-left edge (left/up from it must not move).
//
//   behaviors  One row [First] [Disabled] [Second] where Disabled is
//              truly disabled — the focus engine must skip it — plus a
//              "Show Alert" button raising a standard alert whose
//              "Dismiss" button takes focus.
//
//   list       25 focusable rows ("Row 1"..."Row 25"); moving focus down
//              must scroll later rows into view.
//
// The root menu itself is part of the contract: its entries are focus
// targets ("Grid Test", "Focus Behaviors", "Long List") and pressing
// Menu inside a screen returns here.

import SwiftUI

@main
struct SimUsePlaygroundTVApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var path: [Screen] = []

    enum Screen: String, Hashable, CaseIterable {
        case grid
        case behaviors
        case list
        case text

        var title: String {
            switch self {
            case .grid: return "Grid Test"
            case .behaviors: return "Focus Behaviors"
            case .list: return "Long List"
            case .text: return "Text Entry"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(Screen.allCases, id: \.self) { screen in
                    NavigationLink(screen.title, value: screen)
                        .accessibilityIdentifier("menu-\(screen.rawValue)")
                }
            }
            .navigationTitle("SimUse Playground")
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .grid: GridScreen()
                case .behaviors: BehaviorsScreen()
                case .list: ListScreen()
                case .text: TextScreen()
                }
            }
        }
        // Setting a non-empty initial path in the @State initializer does
        // not push on tvOS's first frame; applying it onAppear does.
        .onAppear {
            path = Self.initialPath()
        }
    }

    /// `--launch-arg screen=<name>` opens a screen directly, mirroring the
    /// iOS Playground's launch-argument navigation.
    private static func initialPath() -> [Screen] {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--launch-arg"),
              index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("screen="),
              let screen = Screen(rawValue: String(arguments[index + 1].dropFirst(7)))
        else { return [] }
        return [screen]
    }
}

// MARK: - grid

struct GridScreen: View {
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
        .onPlayPauseCommand {
            lastAction = "play-pause"
        }
    }
}

// MARK: - behaviors

struct BehaviorsScreen: View {
    @State private var lastAction = "none"
    @State private var showsAlert = false
    @FocusState private var focusedButton: String?

    var body: some View {
        // Leading alignment keeps "Show Alert" in First's vertical beam —
        // the tvOS focus engine only moves to targets whose frames overlap
        // the current focus's projection, so a centered button below an
        // edge button would be unreachable with a single `down`.
        VStack(alignment: .leading, spacing: 60) {
            Text("Last: \(lastAction)")
                .font(.title2)
                .accessibilityIdentifier("last-action")

            HStack(spacing: 60) {
                Button("First") { lastAction = "First" }
                    .focused($focusedButton, equals: "First")
                Button("Disabled") { lastAction = "Disabled" }
                    .disabled(true)
                Button("Second") { lastAction = "Second" }
            }

            Button("Show Alert") { showsAlert = true }
        }
        .padding(80)
        .defaultFocus($focusedButton, "First")
        .alert("Fixture Alert", isPresented: $showsAlert) {
            Button("Dismiss") { lastAction = "alert-dismissed" }
        } message: {
            Text("Focus is trapped here until dismissed.")
        }
    }
}

// MARK: - text

struct TextScreen: View {
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 60) {
            // Mirrors the field's content into a label the outline always
            // shows, because a focused full-screen keyboard session covers
            // the field itself.
            Text("Typed: \(typed.isEmpty ? "none" : typed)")
                .font(.title2)
                .accessibilityIdentifier("typed-value")

            TextField("Search", text: $typed)
                .focused($fieldFocused)
                .accessibilityIdentifier("text-input")
        }
        .padding(80)
        .defaultFocus($fieldFocused, true)
    }
}

// MARK: - list

struct ListScreen: View {
    var body: some View {
        List(1...25, id: \.self) { index in
            Button("Row \(index)") {}
                .accessibilityIdentifier("row-\(index)")
        }
        .navigationTitle("Long List")
    }
}
