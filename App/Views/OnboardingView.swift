import SwiftUI

/// A short first-run tour: four pages, skippable, shown once after the first sign-in and
/// always available again from Settings ("Nasıl çalışır?"). It teaches the one loop the app is
/// built around: write it down, work on it, leave a note when interrupted, watch the city grow.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    private struct Page {
        let image: String
        let title: String
        let body: String
        /// A sample park note, shown in the app's serif signature.
        var note: String?
    }

    private let pages: [Page] = [
        Page(
            image: "city-temel",
            title: "Aklına geleni yaz",
            body: "Alttaki “Aklına geleni yaz…” çubuğuna bir cümle yaz. Saniyeler içinde gelen kutusuna düşer; şehrinde arsası ayrılır."
        ),
        Page(
            image: "city-hayat-kat1",
            title: "Bir işi ele al",
            body: "Başla dediğinde inşaat başlar. İşi küçük adımlara böl; tamamladığın her adım binana bir kat çıkarır. Aynı anda tek iş elinde olur."
        ),
        Page(
            image: "city-is-kat2",
            title: "Bölününce kaldığın yeri yaz",
            body: "Araya bir şey girerse “Ara ver”e bas ve tek cümleyle nerede kaldığını yaz. “Devam et” dediğinde bu not seni karşılar.",
            note: "Grafikler hazır, metinler kaldı."
        ),
        Page(
            image: "city-yatirim-final2",
            title: "Şehrin büyüsün",
            body: "Bitirdiğin her iş şehrinde bir bina olur. 3 gün adım atılmayan inşaat durur; bitirdikçe şehrin Site, Mahalle ve Şehir olur."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Atla") { dismiss() }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .opacity(page == pages.count - 1 ? 0 : 1)
                    .accessibilityHidden(page == pages.count - 1)
            }
            .padding(.horizontal)

            TabView(selection: $page.animation(reduceMotion ? nil : .snappy)) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            ActionButton(
                title: page == pages.count - 1 ? "Başlayalım" : "Devam",
                symbol: page == pages.count - 1 ? "hammer.fill" : "arrow.right",
                prominent: true
            ) {
                if page == pages.count - 1 {
                    dismiss()
                } else {
                    withAnimation(reduceMotion ? nil : .snappy) { page += 1 }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color.themeBackground.ignoresSafeArea())
        .fontDesign(.rounded)
    }

    private func pageView(_ page: Page) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(page.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .accessibilityHidden(true)
                Text(page.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = page.note {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kaldığın yer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ParkNoteText(note: note)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.themeCard, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
