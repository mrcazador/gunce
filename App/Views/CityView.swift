import SwiftUI

/// "Şehir": the city built from your work. Every task is a building; checked-off steps raise
/// its floors, sites without progress stand still and slowly fade, and work finished after a
/// long wait becomes a landmark. The city grows a level at a time (Bina, Site, Mahalle, Şehir)
/// and each level changes how the streets look. Nothing to manage: look at it now and then.
struct CityView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: CityBuilding?
    @State private var zoom: CGFloat = 0.75
    /// The zoom before a building was focused, restored when its card closes.
    @State private var zoomBeforeFocus: CGFloat?
    @State private var scrollTarget: String?
    @GestureState private var pinch: CGFloat = 1
    /// A few buildings play a short move each time the tab opens: id → move (see `CityDance`).
    @State private var dancers: [String: Int] = [:]
    @State private var danceBeat = 0
    /// The highest level already celebrated, so a level-up is shown once.
    @AppStorage("pickup.city.seenLevel") private var seenLevel = -1
    @State private var celebrating: CityLevel?
    /// A task opened from a building card, pushed here instead of jumping to Şimdi.
    @State private var openID: String?

    var body: some View {
        let city = store.city()
        NavigationStack {
            VStack(spacing: 0) {
                CityHeader(city: city) { focus($0) }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                if city.buildings.isEmpty {
                    ContentUnavailableView(
                        "Şehrin boş",
                        systemImage: "building.2",
                        description: Text("İlk görevini ekle; arsası hemen ayrılır.")
                    )
                } else {
                    GeometryReader { proxy in
                        ScrollViewReader { scroller in
                            ScrollView([.horizontal, .vertical]) {
                                CityCanvas(
                                    city: city,
                                    areas: store.sortedAreas,
                                    tile: tileWidth,
                                    selectedID: selected?.id,
                                    dancers: dancers,
                                    danceBeat: danceBeat
                                ) { focus($0) }
                                .padding(40)
                                // Small cities sit in the middle instead of the top-left corner.
                                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                            }
                            .defaultScrollAnchor(.center)
                            .scrollIndicators(.hidden)
                            .gesture(
                                MagnifyGesture()
                                    .updating($pinch) { value, state, _ in state = value.magnification }
                                    .onEnded { value in zoom = min(2.2, max(0.5, zoom * value.magnification)) }
                            )
                            .onChange(of: scrollTarget) { _, id in
                                guard let id else { return }
                                Task {
                                    // Let the zoom lay the city out first, then bring the building
                                    // into the upper half, above the card.
                                    try? await Task.sleep(for: .milliseconds(80))
                                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) {
                                        scroller.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3))
                                    }
                                }
                            }
                        }
                    }
                    .background(CitySky(level: city.level))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.themeBackground)
            .navigationTitle("Şehir")
            .sheet(item: $selected, onDismiss: unfocus) { building in
                CityBuildingSheet(building: building) { openID = $0 }
            }
            .navigationDestination(item: $openID) { id in
                TaskDetailView(taskID: id)
            }
            .overlay {
                if let level = celebrating {
                    LevelUpCard(level: level) {
                        seenLevel = level.rawValue
                        withAnimation(reduceMotion ? nil : .snappy) { celebrating = nil }
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .sensoryFeedback(.success, trigger: celebrating)
            .onAppear {
                startDance(city)
                checkLevel(city)
            }
        }
    }

    private var tileWidth: CGFloat {
        78 * min(2.2, max(0.5, zoom * pinch))
    }

    /// Zooms in on a building and opens its card underneath.
    private func focus(_ building: CityBuilding) {
        if zoomBeforeFocus == nil { zoomBeforeFocus = zoom }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) {
            zoom = max(zoom, 1.6)
        }
        scrollTarget = building.id
        selected = building
    }

    private func unfocus() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) {
            zoom = zoomBeforeFocus ?? zoom
        }
        zoomBeforeFocus = nil
        scrollTarget = nil
    }

    /// Up to three buildings, picked at random, hop, sway or stretch one after another.
    private func startDance(_ city: CitySummary) {
        guard !reduceMotion else { return }
        let candidates = city.buildings.filter { $0.stage != .planned }.shuffled().prefix(3)
        var picked: [String: Int] = [:]
        for (order, building) in candidates.enumerated() {
            picked[building.id] = Int.random(in: 0..<CityDance.moves) + order * CityDance.moves
        }
        dancers = picked
        danceBeat += 1
    }

    /// Shows the level-up card once when the city has grown since it was last opened.
    private func checkLevel(_ city: CitySummary) {
        let level = city.level.rawValue
        if seenLevel < 0 || level < seenLevel {
            seenLevel = level
        } else if level > seenLevel {
            withAnimation(reduceMotion ? nil : .snappy) { celebrating = city.level }
        }
    }
}

// MARK: - Header

private struct CityHeader: View {
    let city: CitySummary
    let open: (CityBuilding) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(city.level.title)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(city.finished) bina")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(city.level.story)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let next = city.level.next {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: city.levelProgress)
                        .tint(Color.themeSage)
                    Text("\(next.title) için \(next.threshold - city.finished) bina daha · Açılacak: \(next.unlock.lowercased(with: Locale(identifier: "tr")))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if !city.stalled.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(city.stalled) { building in
                            Button { open(building) } label: {
                                Label(building.title, systemImage: building.stage == .abandoned ? "exclamationmark.triangle" : "pause.circle")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 36)
                                    .background(.fill.tertiary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("\(building.idleDays) gündür madde tamamlanmadı")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                Text(city.stalled.count == 1 ? "1 inşaat duruyor" : "\(city.stalled.count) inşaat duruyor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The sky over the city: plain at first, then a little brighter with every level, ending in
/// a dusk with a few stars.
private struct CitySky: View {
    let level: CityLevel

    var body: some View {
        LinearGradient(colors: [top, Color.themeBackground], startPoint: .top, endPoint: .center)
            .overlay(alignment: .top) {
                if level == .city {
                    Canvas { context, size in
                        for n in 0..<18 {
                            // Fixed positions, so the stars do not jump around between renders.
                            let x = CGFloat((n * 73) % 100) / 100 * size.width
                            let y = CGFloat((n * 37) % 100) / 100 * size.height * 0.35
                            let r: CGFloat = n % 3 == 0 ? 1.6 : 1
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                                         with: .color(.white.opacity(0.7)))
                        }
                    }
                }
            }
            .accessibilityHidden(true)
    }

    private var top: Color {
        switch level {
        case .building: Color.themeBackground
        case .site: Color(red: 0.62, green: 0.78, blue: 0.92).opacity(0.35)
        case .neighbourhood: Color(red: 0.98, green: 0.80, blue: 0.52).opacity(0.4)
        case .city: Color(red: 0.36, green: 0.33, blue: 0.58).opacity(0.55)
        }
    }
}

/// Shown once when the city reaches a new level.
private struct LevelUpCard: View {
    let level: CityLevel
    let done: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture(perform: done)
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                Image(systemName: "building.2.crop.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.themeBrick)
                    .accessibilityHidden(true)
                Text("Şehrin büyüdü: \(level.title)")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(level.story)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Label("Açıldı: \(level.unlock)", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                ActionButton(title: "Şehre bak", symbol: "eye", prominent: true, action: done)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(Color.themeBackground, in: RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}

/// A short, playful move for a building: hop, sway or stretch up from the ground. Several
/// buildings move one after another; `move` also carries that order.
struct CityDance: ViewModifier {
    static let moves = 3

    let move: Int
    let beat: Int

    private struct Values {
        var lift: CGFloat = 0
        var angle: Double = 0
        var stretch: CGFloat = 1
    }

    func body(content: Content) -> some View {
        let style = move % Self.moves
        let delay = max(0.01, Double(move / Self.moves) * 0.25)
        let hop: CGFloat = style == 0 ? -14 : 0
        let sway: Double = style == 1 ? 4 : 0
        let squash: CGFloat = style == 2 ? 0.8 : (style == 0 ? 0.94 : 1)
        content.keyframeAnimator(initialValue: Values(), trigger: beat) { view, value in
            view
                .scaleEffect(x: 1, y: value.stretch, anchor: .bottom)
                .rotationEffect(.degrees(value.angle), anchor: .bottom)
                .offset(y: value.lift)
        } keyframes: { _ in
            KeyframeTrack(\.lift) {
                LinearKeyframe(0, duration: delay)
                CubicKeyframe(hop, duration: 0.18)
                SpringKeyframe(0, duration: 0.45, spring: .bouncy)
            }
            KeyframeTrack(\.angle) {
                LinearKeyframe(0, duration: delay)
                CubicKeyframe(sway, duration: 0.12)
                CubicKeyframe(-sway, duration: 0.2)
                CubicKeyframe(sway * 0.5, duration: 0.16)
                SpringKeyframe(0, duration: 0.3, spring: .smooth)
            }
            KeyframeTrack(\.stretch) {
                LinearKeyframe(1, duration: delay)
                CubicKeyframe(squash, duration: 0.15)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy)
            }
        }
    }
}

// MARK: - Canvas

/// Isometric layout: each area is a district (a square block of plots), districts sit in
/// two columns. Plots are filled in the order the tasks were created.
private struct CityCanvas: View {
    let city: CitySummary
    let areas: [Area]
    let tile: CGFloat
    var selectedID: String?
    var dancers: [String: Int] = [:]
    var danceBeat = 0
    let open: (CityBuilding) -> Void

    private var level: CityLevel { city.level }

    private struct Plot {
        let building: CityBuilding
        let i: Int
        let j: Int
    }

    private struct District {
        let area: Area?
        let originI: Int
        let originJ: Int
        let size: Int
    }

    /// One district per area, in a planned grid: offices at the back, banks to the right,
    /// homes to the left, sports in front, other areas after them. A lane of road runs
    /// between districts, so every kind of building keeps to its own neighbourhood.
    private var layout: (plots: [Plot], districts: [District]) {
        var groups: [(Area?, [CityBuilding])] = areas
            .sorted { (CityKind(area: $0).order, $0.sort) < (CityKind(area: $1).order, $1.sort) }
            .map { area in (area, city.buildings.filter { $0.areaId == area.id }) }
        let known = Set(areas.map(\.id))
        groups.append((nil, city.buildings.filter { $0.areaId == nil || !known.contains($0.areaId!) }))
        groups = groups.filter { !$0.1.isEmpty }
        let largest = groups.map(\.1.count).max() ?? 1
        let size = max(2, Int(Double(largest).squareRoot().rounded(.up)))
        var plots: [Plot] = []
        var districts: [District] = []
        for (index, group) in groups.enumerated() {
            let oi = (index % 2) * (size + 1)
            let oj = (index / 2) * (size + 1)
            districts.append(District(area: group.0, originI: oi, originJ: oj, size: size))
            // Big buildings take the back plots so they do not hide the small ones.
            let ordered = group.1.sorted { ($0.size.rawValue, $1.createdAt) > ($1.size.rawValue, $0.createdAt) }
            for (n, building) in ordered.enumerated() {
                plots.append(Plot(building: building, i: oi + n % size, j: oj + n / size))
            }
        }
        return (plots, districts)
    }

    /// Plots sit this many tile widths apart, leaving a lane between buildings.
    private static let spacing: CGFloat = 1.4

    /// Screen point of the centre of plot (i, j) in the 2:1 isometric grid.
    private func point(_ i: CGFloat, _ j: CGFloat) -> CGPoint {
        let step = tile * Self.spacing
        return CGPoint(x: (i - j) * step / 2, y: (i + j) * step / 4)
    }


    /// Mahalle on: trees along the edges of each district.
    private func trees(_ districts: [District], offset: CGPoint) -> some View {
        ForEach(districts.indices, id: \.self) { index in
            let d = districts[index]
            let s = CGFloat(d.size), i = CGFloat(d.originI), j = CGFloat(d.originJ)
            let spots = [point(i - 0.55, j + s / 2 - 0.5), point(i + s / 2 - 0.5, j - 0.55)]
            ForEach(spots.indices, id: \.self) { n in
                Image(systemName: "tree.fill")
                    .font(.system(size: tile * 0.28))
                    .foregroundStyle(Color(red: 0.42, green: 0.66, blue: 0.45))
                    .position(x: spots[n].x + offset.x, y: spots[n].y + offset.y - tile * 0.12)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Site on: street lamps at the corners of each district; lit at Şehir.
    private func lamps(_ districts: [District], offset: CGPoint) -> some View {
        ForEach(districts.indices, id: \.self) { index in
            let d = districts[index]
            let s = CGFloat(d.size), i = CGFloat(d.originI), j = CGFloat(d.originJ)
            let spots = [point(i - 0.6, j - 0.6), point(i + s - 0.4, j - 0.6), point(i - 0.6, j + s - 0.4)]
            ForEach(spots.indices, id: \.self) { n in
                StreetLamp(height: tile * 0.32, glowing: level == .city)
                    .position(x: spots[n].x + offset.x, y: spots[n].y + offset.y - tile * 0.16)
                    .accessibilityHidden(true)
            }
        }
    }

    var body: some View {
        let computed = layout
        let plots = computed.plots
        let districts = computed.districts
        let corners = districts.flatMap { d -> [CGPoint] in
            let s = CGFloat(d.size)
            let i = CGFloat(d.originI), j = CGFloat(d.originJ)
            return [point(i - 0.5, j - 0.5), point(i + s - 0.5, j - 0.5), point(i - 0.5, j + s - 0.5), point(i + s - 0.5, j + s - 0.5)]
        }
        let minX = corners.map(\.x).min() ?? 0, maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0, maxY = corners.map(\.y).max() ?? 0
        let buildingHeight = tile / CityBuildingImage.tileShare * CityBuildingImage.aspect
        let top = minY - buildingHeight
        let offset = CGPoint(x: -minX, y: -top)

        let maxI = CGFloat(districts.map { $0.originI + $0.size }.max() ?? 0)
        let maxJ = CGFloat(districts.map { $0.originJ + $0.size }.max() ?? 0)
        let road = [point(-0.5, -0.5), point(maxI - 0.5, -0.5), point(maxI - 0.5, maxJ - 0.5), point(-0.5, maxJ - 0.5)]
            .map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }

        // Lanes between districts: the plot row/column just past the first district.
        let size = CGFloat(districts.first?.size ?? 2)
        let lanes: [(CGPoint, CGPoint)] = {
            var out: [(CGPoint, CGPoint)] = []
            if maxI > size { out.append((point(size, -0.5), point(size, maxJ - 0.5))) }
            if maxJ > size { out.append((point(-0.5, size), point(maxI - 0.5, size))) }
            return out.map { (CGPoint(x: $0.0.x + offset.x, y: $0.0.y + offset.y), CGPoint(x: $0.1.x + offset.x, y: $0.1.y + offset.y)) }
        }()

        ZStack(alignment: .topLeading) {
            // Şehir: a soft skyline on the horizon behind everything.
            if level == .city {
                CitySkyline(width: maxX - minX, height: buildingHeight * 0.9)
                    .offset(y: max(0, minY - top - buildingHeight * 0.9) + tile * 0.2)
            }
            // The road network: dirt at first, asphalt from Site on.
            Path { path in path.addLines(road); path.closeSubpath() }
                .fill(level == .building
                      ? Color(red: 0.62, green: 0.47, blue: 0.32).opacity(0.22)
                      : Color.secondary.opacity(0.2))
            if level != .building {
                ForEach(lanes.indices, id: \.self) { index in
                    Path { path in
                        path.move(to: lanes[index].0)
                        path.addLine(to: lanes[index].1)
                    }
                    .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: max(1, tile * 0.02), dash: [tile * 0.12, tile * 0.1]))
                }
            }
            ForEach(districts.indices, id: \.self) { index in
                let d = districts[index]
                let s = CGFloat(d.size), i = CGFloat(d.originI), j = CGFloat(d.originJ)
                let quad = [point(i - 0.5, j - 0.5), point(i + s - 0.5, j - 0.5),
                            point(i + s - 0.5, j + s - 0.5), point(i - 0.5, j + s - 0.5)]
                    .map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
                let tint = d.area?.tint ?? .gray
                Path { path in path.addLines(quad); path.closeSubpath() }
                    .fill(Color.themeBackground)
                Path { path in path.addLines(quad); path.closeSubpath() }
                    .fill(tint.opacity(0.14))
                Path { path in path.addLines(quad); path.closeSubpath() }
                    .stroke(tint.opacity(0.35), lineWidth: 1)
                if let area = d.area {
                    Label(area.name, systemImage: area.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(area.tint)
                        .fixedSize()
                        .position(x: quad[0].x, y: quad[0].y - 12)
                        .accessibilityHidden(true)
                }
            }
            if level.rawValue >= CityLevel.neighbourhood.rawValue {
                trees(districts, offset: offset)
            }
            if level.rawValue >= CityLevel.site.rawValue {
                lamps(districts, offset: offset)
            }
            ForEach(plots.sorted { ($0.i + $0.j) < ($1.i + $1.j) }, id: \.building.id) { plot in
                let centre = point(CGFloat(plot.i), CGFloat(plot.j))
                // The image's bottom edge is the tile's front corner.
                let front = CGPoint(x: centre.x + offset.x, y: centre.y + tile / 4 + offset.y)
                let isSelected = plot.building.id == selectedID
                Button { open(plot.building) } label: {
                    if let move = dancers[plot.building.id] {
                        CityBuildingImage(building: plot.building, tileWidth: tile)
                            .modifier(CityDance(move: move, beat: danceBeat))
                    } else {
                        CityBuildingImage(building: plot.building, tileWidth: tile)
                    }
                }
                .buttonStyle(.plain)
                // The focused building stands out while its card is open.
                .scaleEffect(isSelected ? 1.06 : 1, anchor: .bottom)
                .shadow(color: isSelected ? Color.themeBrick.opacity(0.6) : .clear, radius: tile * 0.12)
                .animation(.snappy, value: isSelected)
                .id(plot.building.id)
                // The artwork's bottom edge (less its small inset) is the tile's front corner.
                .position(x: front.x, y: front.y - buildingHeight / 2 + buildingHeight * CityBuildingImage.bottomInset)
                .accessibilityLabel(CityText.accessibility(plot.building))
            }
        }
        .frame(width: maxX - minX, height: maxY - top + tile / 2)
    }
}

/// A street lamp from level Site on; at Şehir its light is on.
private struct StreetLamp: View {
    let height: CGFloat
    let glowing: Bool

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(glowing ? Color.yellow : Color(white: 0.85))
                .frame(width: height * 0.22, height: height * 0.22)
                .shadow(color: glowing ? .yellow.opacity(0.8) : .clear, radius: height * 0.25)
            Capsule()
                .fill(Color(white: 0.35))
                .frame(width: max(1.5, height * 0.06), height: height * 0.78)
        }
        .frame(height: height)
    }
}

/// The skyline at level Şehir: a soft row of towers with a few lit windows.
private struct CitySkyline: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Canvas { context, size in
            let count = 14
            let step = size.width / CGFloat(count)
            for n in 0..<count {
                // Fixed heights, so the skyline stays the same between renders.
                let share = 0.35 + CGFloat((n * 47 + 13) % 60) / 100
                let w = step * 0.8
                let h = size.height * share
                let rect = CGRect(x: CGFloat(n) * step + step * 0.1, y: size.height - h, width: w, height: h)
                context.fill(Path(rect), with: .color(Color(red: 0.45, green: 0.42, blue: 0.62).opacity(0.28)))
                var y = rect.minY + h * 0.15
                while y < rect.maxY - 6 {
                    if (Int(y) + n) % 3 == 0 {
                        context.fill(Path(CGRect(x: rect.minX + w * 0.3, y: y, width: w * 0.18, height: 3)),
                                     with: .color(.yellow.opacity(0.55)))
                    }
                    y += 9
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// One building at its stage: foundation, floors rising, the shell, finished, moved in, or a
/// stalled site. A plot that is only planned shows the foundation faintly.
struct CityBuildingImage: View {
    /// Height / width of the artwork.
    static let aspect: CGFloat = 780.0 / 600.0
    /// The ground tile's width as a share of the artwork's width.
    static let tileShare: CGFloat = 420.0 / 600.0
    /// Gap below the tile's front corner, as a share of the artwork's height.
    static let bottomInset: CGFloat = 12.0 / 780.0

    let building: CityBuilding
    /// Width of the ground tile on screen; the artwork is wider (cranes, trees).
    let tileWidth: CGFloat

    var width: CGFloat { tileWidth / Self.tileShare }
    var height: CGFloat { width * Self.aspect }

    var body: some View {
        Image(building.imageName)
            .resizable()
            .scaledToFit()
            // Moved in: warm light in the windows.
            .brightness(building.art == .occupied ? 0.04 : 0)
            .shadow(color: building.art == .occupied ? .orange.opacity(0.45) : .clear, radius: width * 0.06)
            .saturation(building.stage == .stalled ? 0.7 : 1)
            .opacity(building.stage == .planned ? 0.55 : 1)
            .frame(width: width, height: height)
            .overlay(alignment: .top) {
                if let badge {
                    Image(systemName: badge)
                        .font(.caption.weight(.semibold))
                        .padding(6)
                        .background(.regularMaterial, in: Circle())
                        .offset(y: height * badgeDrop)
                        .accessibilityHidden(true)
                }
            }
            // Only the building itself takes taps, not the empty corners of its artwork, so a
            // building in front does not catch a tap meant for the one behind it.
            .contentShape(
                Rectangle()
                    .size(width: width * 0.6, height: height * 0.62)
                    .offset(x: width * 0.2, y: height * 0.34)
            )
    }

    /// The badge floats just above the roof line of each stage.
    private var badgeDrop: CGFloat {
        switch building.art {
        case .foundation: 0.62
        case .groundFloor: 0.38
        case .upperFloor: 0.22
        default: 0.14
        }
    }

    private var badge: String? {
        if building.isLandmark { return "star.fill" }
        switch building.stage {
        case .stalled: return "pause.fill"
        case .abandoned: return "exclamationmark.triangle.fill"
        default: return nil
        }
    }
}

// MARK: - Building card

/// The card under a focused building: the task's state, where you left off, its steps (check
/// them off right here) and the one action that moves it on. The city stays visible above.
private struct CityBuildingSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let building: CityBuilding
    let openTask: (String) -> Void

    var body: some View {
        // Live copy: checking off a step here raises the building at once.
        let live = store.city().buildings.first { $0.id == building.id } ?? building
        let task = store.tasks[building.id]
        let steps = store.subtasks(of: building.id).filter { $0.deletedAt == nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let area = store.area(live.areaId) {
                            AreaLabel(area: area)
                                .font(.subheadline)
                        }
                        Text(live.title)
                            .font(.title3.weight(.semibold))
                        Text(CityText.stage(live))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Kapat", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Color.themeCard, in: Circle())
                        .buttonStyle(.plain)
                }

                if live.stage != .planned {
                    ProgressView(value: live.progress)
                        .tint(Color.themeSage)
                        .accessibilityLabel("İnşaat ilerlemesi")
                }

                if let note = live.parkNote, !note.isEmpty, live.stage != .finished {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kaldığın yer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ParkNoteText(note: note)
                    }
                }

                if !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Maddeler · \(live.stepsDone)/\(live.stepsTotal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ForEach(steps) { step in
                            StepRow(step: step)
                        }
                    }
                }

                if let task, task.status.isOpen {
                    ActionRow {
                        switch task.status {
                        case .active:
                            ActionButton(title: "İnşaatı durdur", symbol: "pause.fill", prominent: true) {
                                dismiss()
                                Task {
                                    try? await Task.sleep(for: .milliseconds(350))
                                    store.requestPark(task)
                                }
                            }
                        default:
                            ActionButton(title: task.status == .parked ? "Şantiyeye dön" : "Başla", symbol: "play.fill", prominent: true) {
                                dismiss()
                                Task {
                                    try? await Task.sleep(for: .milliseconds(350))
                                    store.requestStart(task)
                                }
                            }
                        }
                        ActionButton(title: "Teslim et", symbol: "checkmark") {
                            Task { await store.complete(task) }
                        }
                    }
                }

                Button("Görevi aç", systemImage: "arrow.up.right") {
                    dismiss()
                    openTask(building.id)
                }
                .frame(minHeight: 44)

                if live.stage == .abandoned {
                    Text("Bir madde tamamlarsan inşaat yeniden başlar; bitirirsen şehrin anıt yapılarından biri olur.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .presentationDetents([.fraction(0.5), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
        .presentationBackground(Color.themeBackground)
        .presentationDragIndicator(.visible)
    }
}

/// One step in the building card: tap to check it off.
private struct StepRow: View {
    @Environment(AppStore.self) private var store
    let step: TaskItem

    var body: some View {
        let done = step.status == .done
        Button {
            if !done { Task { await store.complete(step) } }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? Color.themeSage : Color.secondary)
                Text(step.title)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .accessibilityLabel(done ? "\(step.title), tamamlandı" : "\(step.title), tamamla")
    }
}

enum CityText {
    static func stage(_ b: CityBuilding) -> String {
        switch b.stage {
        case .planned:
            return "Arsa hazır. Başlayınca temel atılır."
        case .rising:
            return b.stepsTotal > 0 ? "Kat \(b.stepsDone)/\(b.stepsTotal) · inşaat sürüyor" : "İnşaat sürüyor"
        case .stalled:
            return "\(b.idleDays) gündür madde tamamlanmadı; inşaat duruyor"
        case .abandoned:
            return "\(b.idleDays) gündür madde tamamlanmadı; terk edilmiş"
        case .finished:
            return b.isLandmark ? "Anıt yapı: uzun bir aradan sonra bitirdin." : "Tamamlandı"
        }
    }

    static func accessibility(_ b: CityBuilding) -> String {
        "\(b.title). \(stage(b))"
    }
}
