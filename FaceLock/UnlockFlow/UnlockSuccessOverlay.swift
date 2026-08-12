import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class UnlockSuccessOverlayController {
    static let shared = UnlockSuccessOverlayController()

    private var panel: PassiveOverlayPanel?
    private var dismissTask: Task<Void, Never>?

    func show() {
        dismissTask?.cancel()

        let panel = panel ?? makePanel()
        self.panel = panel

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? .zero
        let hasNotch = (screen?.safeAreaInsets.top ?? 0) > 0
        panel.contentView = NSHostingView(rootView: UnlockSuccessOverlayView(hasNotch: hasNotch))

        let size = CGSize(width: 240, height: 125)
        panel.setFrame(NSRect(x: screenFrame.midX - size.width / 2,
                              y: screenFrame.maxY - size.height,
                              width: size.width,
                              height: size.height),
                       display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        dismissTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(1_350))
            guard !Task.isCancelled, let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in panel.orderOut(nil) }
            }
            self?.dismissTask = nil
        }
    }

    private func makePanel() -> PassiveOverlayPanel {
        let panel = PassiveOverlayPanel(contentRect: .zero,
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered,
                                        defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

private final class PassiveOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct UnlockSuccessOverlayView: View {
    let hasNotch: Bool

    @State private var rotation = Angle.zero
    @State private var pulse = false
    @State private var complete = false
    @State private var expanded = false
    @State private var contentVisible = false

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 0,
                                   bottomLeadingRadius: expanded ? 25 : 14,
                                   bottomTrailingRadius: expanded ? 25 : 14,
                                   topTrailingRadius: 0,
                                   style: .continuous)
                .fill(Color.black)
                .overlay {
                    UnevenRoundedRectangle(topLeadingRadius: 0,
                                           bottomLeadingRadius: expanded ? 25 : 14,
                                           bottomTrailingRadius: expanded ? 25 : 14,
                                           topTrailingRadius: 0,
                                           style: .continuous)
                        .stroke(Color.white.opacity(expanded ? 0.08 : 0.02), lineWidth: 1)
                }
                .frame(width: expanded ? 188 : (hasNotch ? 174 : 132),
                       height: expanded ? 88 : (hasNotch ? 31 : 26))
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 14, y: 7)
                .offset(y: hasNotch && expanded ? 22 : 0)

            if contentVisible {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 3)
                            .frame(width: 48, height: 48)

                        Circle()
                            .trim(from: 0.08, to: complete ? 1 : 0.88)
                            .stroke(
                                AngularGradient(colors: [.green.opacity(0.15), .green, .mint, .green.opacity(0.15)],
                                                center: .center),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .frame(width: 48, height: 48)
                            .rotationEffect(rotation)
                            .opacity(complete ? 0.4 : 1)

                        Circle()
                            .stroke(Color.green.opacity(pulse ? 0.16 : 0.46), lineWidth: 1.5)
                            .frame(width: 54, height: 54)
                            .scaleEffect(pulse ? 1.05 : 0.94)

                        Image(systemName: complete ? "checkmark" : "faceid")
                            .font(.system(size: complete ? 21 : 23,
                                          weight: complete ? .bold : .medium,
                                          design: .rounded))
                            .foregroundStyle(complete ? Color.green : Color.white)
                            .contentTransition(.symbolEffect(.replace))
                    }

                    Text(complete ? "Unlocked" : "Face recognized")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .contentTransition(.opacity)
                }
                .padding(.top, hasNotch ? 39 : 17)
                .transition(.opacity.combined(with: .scale(scale: 0.84, anchor: .top)))
            }
        }
        .frame(width: 240, height: 125, alignment: .top)
        .onAppear {
            withAnimation(.linear(duration: 0.72).repeatForever(autoreverses: false)) {
                rotation = .degrees(360)
            }
            withAnimation(.easeInOut(duration: 0.58).repeatForever(autoreverses: true)) {
                pulse = true
            }

            Task {
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
                    expanded = true
                }

                try? await Task.sleep(for: .milliseconds(90))
                withAnimation(.easeOut(duration: 0.20)) {
                    contentVisible = true
                }

                try? await Task.sleep(for: .milliseconds(270))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.64)) {
                    complete = true
                }

                try? await Task.sleep(for: .milliseconds(620))
                withAnimation(.easeIn(duration: 0.14)) {
                    contentVisible = false
                }

                try? await Task.sleep(for: .milliseconds(100))
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    expanded = false
                }
            }
        }
    }
}
