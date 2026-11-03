import SwiftUI

// Shared by the iPhone and the Mac app: the soft game theme's colors, buttons and bricks.
// The colors and the city artwork live in Theme.xcassets next to this file.

/// The soft game palette: warm cream ground, brick for the one main action, sage for
/// progress. Light and dark variants live in the asset catalog. Area colors stay for areas.
extension Color {
    static let themeBackground = Color("ThemeBackground")
    static let themeBrick = Color("ThemeBrick")
    static let themeBrickShadow = Color("ThemeBrickShadow")
    static let themeOnBrick = Color("ThemeOnBrick")
    static let themeCard = Color("ThemeCard")
    static let themeCardShadow = Color("ThemeCardShadow")
    static let themeSage = Color("ThemeSage")
}

extension View {
    /// The warm cream ground behind lists and forms.
    func themedBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.themeBackground)
    }
}

/// A chunky, game-like button that sits on a solid ledge and presses down into it.
struct ChunkyButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? Color.themeOnBrick : Color.primary)
            .padding(.horizontal, 12)
            .background(prominent ? Color.themeBrick : Color.themeCard, in: RoundedRectangle(cornerRadius: 16))
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(prominent ? Color.themeBrickShadow : Color.themeCardShadow)
                    .offset(y: pressed ? 1 : 4)
            )
            .offset(y: pressed ? 3 : 0)
            .padding(.bottom, 4)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: pressed)
    }
}

extension Font {
    /// The signature style for park notes. Nothing else uses serif.
    static let parkNote = Font.system(.body, design: .serif).italic()
}

struct ParkNoteText: View {
    let note: String

    var body: some View {
        Text(note)
            .font(.parkNote)
            // The app uses rounded type; park notes keep their serif signature.
            .fontDesign(.serif)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Kaldığın yer: \(note)")
    }
}


/// Progress laid brick by brick: one brick per step (or per building towards the next level).
/// Finished bricks pop into place when the row appears and whenever one is added. Long rows
/// group into at most 12 bricks so each stays readable.
struct BrickProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let done: Int
    let total: Int
    var height: CGFloat = 14
    /// Spoken by VoiceOver, e.g. "2 adımın 1 tanesi bitti".
    var label: String
    @State private var beat = 0

    var body: some View {
        let count = min(max(total, 1), 12)
        let filled = total > 0 ? min(count, done * count / total) : 0
        let shape = RoundedRectangle(cornerRadius: height * 0.3)
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                if index < filled {
                    shape
                        .fill(Color.themeBrick)
                        .overlay(alignment: .bottom) {
                            // The darker lower edge gives each brick its depth.
                            Rectangle()
                                .fill(Color.themeBrickShadow)
                                .frame(height: height * 0.24)
                        }
                        .clipShape(shape)
                        .modifier(PopIn(delay: Double(index) * 0.05, beat: beat))
                } else {
                    shape
                        .fill(Color.themeCard)
                        .overlay(shape.strokeBorder(Color.themeCardShadow, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])))
                }
            }
        }
        .frame(height: height)
        .onAppear { if !reduceMotion { beat += 1 } }
        .onChange(of: done) { if !reduceMotion { beat += 1 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Pops a prop in from nothing with a little overshoot, after a short delay. Runs each time
/// `beat` changes; with Reduce Motion the beat never changes and props simply stand there.
struct PopIn: ViewModifier {
    let delay: Double
    let beat: Int

    /// A delay of up to a second, different on every opening, so props pop in a loose order.
    static func delay(seed: Int, beat: Int) -> Double {
        Double((seed &* 7 &+ beat &* 13) % 12) * 0.09
    }

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(1), trigger: beat) { view, scale in
            view.scaleEffect(scale, anchor: .bottom)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(0, duration: 0.01)
                LinearKeyframe(0, duration: max(0.01, delay))
                SpringKeyframe(1.2, duration: 0.16)
                SpringKeyframe(1, duration: 0.4, spring: .bouncy)
            }
        }
    }
}
