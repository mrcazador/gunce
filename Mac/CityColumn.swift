import SwiftUI

/// "Şehir" on the Mac: the same city as on the iPhone. Drag to move around, pinch or use the
/// zoom buttons; clicking a building opens its task on the right.
struct MacCityColumn: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: String?
    /// Map scale; nil fits the whole city.
    @State private var zoom: CGFloat?
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    /// Bumped each time Şehir opens: trees, lamps and benches pop in again.
    @State private var popBeat = 0
    @State private var showStory = false

    static let tile: CGFloat = 78

    var body: some View {
        let city = store.city()
        let layout = CityLayout(city: city, areas: store.sortedAreas, tile: Self.tile)
        VStack(spacing: 0) {
            if city.buildings.isEmpty {
                ContentUnavailableView(
                    "Şehrin boş",
                    systemImage: "building.2",
                    description: Text("İlk görevini yaz; arsası hemen ayrılır.")
                )
            } else {
                CityHeader(city: city) { showStory = true }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .popover(isPresented: $showStory, arrowEdge: .bottom) {
                        MacCityStory(city: city)
                    }
                GeometryReader { proxy in
                    let fit = Self.fit(layout, proxy.size)
                    let scale = Self.clamp((zoom ?? fit) * pinch)
                    CityCanvas(layout: layout, level: city.level, selectedID: selection, popBeat: popBeat) { building in
                        selection = building.id
                    }
                    .scaleEffect(scale)
                    .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle())
                    .clipped()
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .updating($drag) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                pan.width += value.translation.width
                                pan.height += value.translation.height
                            }
                            .simultaneously(with:
                                MagnifyGesture()
                                    .updating($pinch) { value, state, _ in state = value.magnification }
                                    .onEnded { value in zoom = Self.clamp((zoom ?? fit) * value.magnification) }
                            )
                    )
                    .overlay(alignment: .bottomTrailing) {
                        zoomControls(fit: fit)
                            .padding(12)
                    }
                }
                .background(CitySky(level: city.level))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.themeBackground)
        .navigationTitle("Şehir")
        .onAppear {
            if !reduceMotion { popBeat += 1 }
        }
    }

    private func zoomControls(fit: CGFloat) -> some View {
        HStack(spacing: 6) {
            Button("Uzaklaş", systemImage: "minus") { setZoom((zoom ?? fit) / 1.25) }
            Button("Tümünü gör", systemImage: "arrow.down.right.and.arrow.up.left") {
                withAnimation(reduceMotion ? nil : .smooth) {
                    zoom = nil
                    pan = .zero
                }
            }
            Button("Yakınlaş", systemImage: "plus") { setZoom((zoom ?? fit) * 1.25) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(ChunkyButtonStyle(prominent: false))
        .controlSize(.large)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(reduceMotion ? nil : .smooth) { zoom = Self.clamp(value) }
    }

    private static func clamp(_ value: CGFloat) -> CGFloat { min(2.6, max(0.3, value)) }

    /// The scale that fits the whole city (never larger than 1).
    private static func fit(_ layout: CityLayout, _ size: CGSize) -> CGFloat {
        guard layout.size.width > 0, layout.size.height > 0 else { return 1 }
        return min(1, size.width / layout.size.width, size.height / layout.size.height)
    }
}

/// The city's story and its stalled sites, in a popover under the header.
private struct MacCityStory: View {
    let city: CitySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(city.level.title)
                .font(.headline)
            Text(city.level.story)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let next = city.level.next {
                Text("\(next.title) için \(next.threshold - city.finished) iş daha bitir. Açılacak: \(next.unlock.lowercased(with: Locale(identifier: "tr"))).")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !city.stalled.isEmpty {
                Divider()
                Text("Duran inşaatlar")
                    .font(.subheadline.weight(.semibold))
                ForEach(city.stalled) { building in
                    HStack {
                        Label(building.title, systemImage: building.stage == .abandoned ? "exclamationmark.triangle" : "pause.circle")
                        Spacer()
                        Text("\(building.idleDays) gün")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .fontDesign(.rounded)
    }
}
