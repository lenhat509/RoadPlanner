import SwiftUI

/// A two-second opening on launch: the app icon's scene comes to life. The sun rises over the
/// horizon, the road draws toward it, the planned stops (rest, fuel, overnight) appear along it
/// one after another, the name fades in, then the scene fades away to Home.
///
/// Tapping skips it. With Reduce Motion the scene appears still and simply fades.
struct LaunchIntroView: View {
    /// How long the finished scene stays before fading away.
    var hold: TimeInterval = 0.85
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sunRise = 0.0
    @State private var roadDrawn = 0.0
    @State private var stopsShown = 0
    @State private var showsTitle = false
    @State private var isLeaving = false
    @State private var hasFinished = false

    /// The icon's colours.
    private enum Palette {
        static let skyTop = Color(red: 0.043, green: 0.271, blue: 0.325)
        static let skyMiddle = Color(red: 0.102, green: 0.557, blue: 0.580)
        static let skyHorizon = Color(red: 0.373, green: 0.722, blue: 0.659)
        static let groundNear = Color(red: 0.031, green: 0.165, blue: 0.200)
        static let groundFar = Color(red: 0.059, green: 0.294, blue: 0.341)
        static let sun = Color(red: 0.965, green: 0.769, blue: 0.416)
        static let road = Color(red: 0.957, green: 0.969, blue: 0.969)
        static let ink = Color(red: 0.039, green: 0.204, blue: 0.251)
        static let stops = [
            Color(red: 0.0, green: 0.62, blue: 0.45), // rest
            Color(red: 0.90, green: 0.62, blue: 0.0), // fuel
            Color(red: 0.80, green: 0.47, blue: 0.65), // overnight
        ]
    }

    /// Shown on every launch, except in UI tests (which drive the app straight away) unless they
    /// ask for it.
    static func isShown(in mode: AppEnvironment.Mode, arguments: [String] = []) -> Bool {
        mode != .uiTest || arguments.contains(LaunchArgument.showIntro)
    }

    /// The finished scene's hold: a few seconds when a screenshot run asks for the intro.
    static func hold(arguments: [String]) -> TimeInterval {
        arguments.contains(LaunchArgument.showIntro) ? 4 : 0.85
    }

    /// Depth along the road of each stop (1 = the bottom of the screen).
    private static let stopDepths = [1.25, 2.2, 4.2]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            let horizon = height * 0.56
            let ground = height - horizon
            let sun = width * 0.14
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    stops: [
                        .init(color: Palette.skyTop, location: 0),
                        .init(color: Palette.skyMiddle, location: 0.82),
                        .init(color: Palette.skyHorizon, location: 1),
                    ],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.56)
                )
                RadialGradient(
                    colors: [Palette.sun.opacity(0.55), Palette.sun.opacity(0)],
                    center: UnitPoint(x: 0.5, y: 0.56), startRadius: 0, endRadius: max(width, height * 0.5) * 0.6
                )
                .opacity(sunRise)
                Circle()
                    .fill(Palette.sun)
                    .frame(width: sun * 2, height: sun * 2)
                    .position(x: width / 2, y: horizon + sun * (1.05 - sunRise))
                LinearGradient(colors: [Palette.groundFar, Palette.groundNear], startPoint: .top, endPoint: .bottom)
                    .frame(width: width, height: ground)
                    .offset(y: horizon)
                road(width: width, height: ground)
                    .frame(width: width, height: ground)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: ground * roadDrawn)
                    }
                    .offset(y: horizon)
                ForEach(Self.stopDepths.indices, id: \.self) { index in
                    stop(index, width: width)
                        .scaleEffect(stopsShown > index ? 1 : 0.01)
                        .opacity(stopsShown > index ? 1 : 0)
                        .position(x: width / 2, y: horizon + ground / Self.stopDepths[index])
                }
                VStack(spacing: 6) {
                    Text("Waystage")
                        .font(.system(size: 46, weight: .heavy, design: .rounded))
                        .tracking(-0.5)
                    Text("Long drives, planned end to end")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .frame(width: width)
                .position(x: width / 2, y: horizon * 0.42)
                .opacity(showsTitle ? 1 : 0)
                .offset(y: showsTitle ? 0 : 14)
            }
        }
        .ignoresSafeArea()
        .opacity(isLeaving ? 0 : 1)
        .scaleEffect(isLeaving && !reduceMotion ? 1.06 : 1)
        .contentShape(Rectangle())
        .onTapGesture { leave(after: 0) }
        .task { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waystage")
        .accessibilityAddTraits(.isHeader)
    }

    /// The road from the bottom of the screen to the horizon, with its centre dashes in
    /// perspective (as in the app icon).
    private func road(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            let centre = size.width / 2
            var surface = Path()
            surface.move(to: CGPoint(x: centre - width * 0.256, y: size.height))
            surface.addLine(to: CGPoint(x: centre + width * 0.256, y: size.height))
            surface.addLine(to: CGPoint(x: centre + width * 0.012, y: 0))
            surface.addLine(to: CGPoint(x: centre - width * 0.012, y: 0))
            surface.closeSubpath()
            context.fill(surface, with: .color(Palette.road))
            for near in [1.0, 1.6, 2.5, 3.9, 6.0, 9.5] {
                let far = near * 1.28
                let half = width * 15 / 1024
                var dash = Path()
                dash.move(to: CGPoint(x: centre - half / near, y: size.height / near))
                dash.addLine(to: CGPoint(x: centre + half / near, y: size.height / near))
                dash.addLine(to: CGPoint(x: centre + half / far, y: size.height / far))
                dash.addLine(to: CGPoint(x: centre - half / far, y: size.height / far))
                dash.closeSubpath()
                context.fill(dash, with: .color(Palette.ink))
            }
        }
    }

    private func stop(_ index: Int, width: CGFloat) -> some View {
        let radius = width * 64 / 1024 / pow(Self.stopDepths[index], 0.8)
        return Circle()
            .fill(Palette.stops[index])
            .overlay(Circle().strokeBorder(.white, lineWidth: max(2, radius * 0.3)))
            .frame(width: radius * 2, height: radius * 2)
    }

    private func play() async {
        if reduceMotion {
            sunRise = 1
            roadDrawn = 1
            stopsShown = Self.stopDepths.count
            showsTitle = true
            leave(after: max(0.9, hold))
            return
        }
        withAnimation(.easeOut(duration: 0.7)) { sunRise = 1 }
        await pause(0.15)
        withAnimation(.easeInOut(duration: 0.7)) { roadDrawn = 1 }
        await pause(0.3)
        for _ in Self.stopDepths {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.58)) { stopsShown += 1 }
            await pause(0.13)
        }
        withAnimation(.easeOut(duration: 0.45)) { showsTitle = true }
        leave(after: hold)
    }

    /// Fades the scene away, then hands over to the app (once).
    private func leave(after delay: TimeInterval) {
        Task {
            await pause(delay)
            guard !isLeaving else { return }
            withAnimation(.easeIn(duration: 0.35)) { isLeaving = true }
            await pause(0.35)
            guard !hasFinished else { return }
            hasFinished = true
            onFinished()
        }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
