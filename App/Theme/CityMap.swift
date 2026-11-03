import SwiftUI

// The city map, shared by the iPhone and the Mac app: layout, ground, buildings and props.

extension Area {
    /// Color means area only. Unknown names fall back to gray.
    var tint: Color {
        switch color {
        case "indigo": .indigo
        case "pink": .pink
        case "orange": .orange
        case "green": .green
        case "blue": .blue
        case "red": .red
        case "purple": .purple
        case "teal": .teal
        case "mint": .mint
        case "cyan": .cyan
        case "yellow": .yellow
        case "brown": .brown
        default: .gray
        }
    }
}

// MARK: - Header

struct CityHeader: View {
    let city: CitySummary
    let openStory: () -> Void

    var body: some View {
        // One quiet row: the level, how far to the next one, and a way into the story. The
        // story, what the next level adds and the stalled sites live one tap away.
        Button(action: openStory) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(city.level.title)
                        .font(.title3.weight(.bold))
                    if let next = city.level.next {
                        Text("· \(next.title) için \(city.finished)/\(next.threshold)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !city.stalled.isEmpty {
                        Label("\(city.stalled.count)", systemImage: "pause.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.orange)
                            .accessibilityLabel("\(city.stalled.count) inşaat duruyor")
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if let next = city.level.next {
                    BrickProgress(
                        done: city.finished - city.level.threshold,
                        total: next.threshold - city.level.threshold,
                        height: 10,
                        label: "\(next.title) için \(next.threshold - city.finished) bina daha"
                    )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Şehrin hikâyesini ve duran inşaatları açar")
    }
}

/// The sky over the city: plain at first, then a little brighter with every level, ending in
/// a dusk with a few stars.
struct CitySky: View {
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

/// One building with a little street around it (a tree, a lamp, a bush, by level), whose
/// props pop in each time it appears. Used on Şimdi and in a task's detail.
struct CityBuildingShowcase: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let building: CityBuilding
    let level: CityLevel
    var tile: CGFloat = 96
    @State private var beat = 0

    var body: some View {
        let props = Self.props(for: building, level: level)
        let height = tile / CityBuildingImage.tileShare * CityBuildingImage.aspect
        ZStack(alignment: .bottom) {
            CityBuildingImage(building: building, tileWidth: tile)
            ForEach(props.indices, id: \.self) { n in
                let side: CGFloat = n % 2 == 0 ? -1 : 1
                let row: CGFloat = n < 2 ? 0 : 1
                CityPropView(prop: props[n], tile: tile, glowing: level == .city)
                    .modifier(PopIn(delay: 0.15 + Double(n) * 0.14, beat: beat))
                    .offset(x: side * tile * (0.58 + row * 0.22), y: -tile * (0.2 + row * 0.12))
            }
        }
        .frame(width: tile * 2.2, height: height)
        .onAppear {
            if !reduceMotion { beat += 1 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CityText.accessibility(building))
    }

    /// The street a building gets: what the city's level allows, two to four pieces.
    static func props(for building: CityBuilding, level: CityLevel) -> [CityProp] {
        let options = CityProp.available(at: level.rawValue >= CityLevel.site.rawValue ? level : .site)
        let seed = CityProp.seed(building.id)
        let count = building.stage == .finished ? 4 : 2
        return (0..<count).map { options[(seed / (n(for: $0))) % options.count] }
    }

    private static func n(for index: Int) -> Int { [1, 7, 13, 29][index] }
}

// MARK: - Layout

/// Where everything sits on the isometric map. Each area is a district (a square block of
/// plots) in a planned grid: offices at the back, banks to the right, homes to the left,
/// sports in front, other areas after them, with a lane of road between districts. Shared by
/// the canvas (to draw) and the map (to zoom in on a building).
struct CityLayout {
    struct Plot {
        let building: CityBuilding
        let i: Int
        let j: Int
    }

    struct District {
        let area: Area?
        let originI: Int
        let originJ: Int
        let size: Int
        /// Times this area's repeating tasks were done: its street furniture.
        var chores = 0
    }

    /// Plots sit this many tile widths apart, leaving a lane between buildings.
    static let spacing: CGFloat = 1.4
    /// Room around the city inside the canvas.
    static let margin: CGFloat = 40

    let plots: [Plot]
    let districts: [District]
    let tile: CGFloat
    /// Canvas size, margins included.
    let size: CGSize
    /// Added to a raw grid point to get canvas coordinates.
    let offset: CGPoint
    let buildingHeight: CGFloat

    init(city: CitySummary, areas: [Area], tile: CGFloat) {
        self.tile = tile
        var groups: [(Area?, [CityBuilding])] = areas
            .sorted { (CityKind(area: $0).order, $0.sort) < (CityKind(area: $1).order, $1.sort) }
            .map { area in (area, city.buildings.filter { $0.areaId == area.id }) }
        let known = Set(areas.map(\.id))
        groups.append((nil, city.buildings.filter { $0.areaId == nil || !known.contains($0.areaId!) }))
        // An area with only repeating tasks still gets a district, for its street furniture.
        groups = groups.filter { !$0.1.isEmpty || (city.chores[$0.0?.id] ?? 0) > 0 }
        let largest = groups.map(\.1.count).max() ?? 1
        let side = max(2, Int(Double(largest).squareRoot().rounded(.up)))
        var plots: [Plot] = []
        var districts: [District] = []
        for (index, group) in groups.enumerated() {
            let oi = (index % 2) * (side + 1)
            let oj = (index / 2) * (side + 1)
            districts.append(District(area: group.0, originI: oi, originJ: oj, size: side, chores: city.chores[group.0?.id] ?? 0))
            // Big buildings take the back plots so they do not hide the small ones.
            let ordered = group.1.sorted { ($0.size.rawValue, $1.createdAt) > ($1.size.rawValue, $0.createdAt) }
            for (n, building) in ordered.enumerated() {
                plots.append(Plot(building: building, i: oi + n % side, j: oj + n / side))
            }
        }
        self.plots = plots
        self.districts = districts

        let raw = { (i: CGFloat, j: CGFloat) -> CGPoint in
            let step = tile * Self.spacing
            return CGPoint(x: (i - j) * step / 2, y: (i + j) * step / 4)
        }
        let corners = districts.flatMap { d -> [CGPoint] in
            let s = CGFloat(d.size), i = CGFloat(d.originI), j = CGFloat(d.originJ)
            return [raw(i - 0.5, j - 0.5), raw(i + s - 0.5, j - 0.5), raw(i - 0.5, j + s - 0.5), raw(i + s - 0.5, j + s - 0.5)]
        }
        let minX = corners.map(\.x).min() ?? 0, maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0, maxY = corners.map(\.y).max() ?? 0
        buildingHeight = tile / CityBuildingImage.tileShare * CityBuildingImage.aspect
        let top = minY - buildingHeight
        offset = CGPoint(x: Self.margin - minX, y: Self.margin - top)
        size = CGSize(width: maxX - minX + Self.margin * 2, height: maxY - top + tile / 2 + Self.margin * 2)
    }

    /// Canvas point of grid position (i, j); whole numbers are plot centres.
    func point(_ i: CGFloat, _ j: CGFloat) -> CGPoint {
        let step = tile * Self.spacing
        return CGPoint(x: (i - j) * step / 2 + offset.x, y: (i + j) * step / 4 + offset.y)
    }

    /// The tile's front corner of a plot: where the artwork's bottom edge sits.
    func front(_ plot: Plot) -> CGPoint {
        let centre = point(CGFloat(plot.i), CGFloat(plot.j))
        return CGPoint(x: centre.x, y: centre.y + tile / 4)
    }

    /// The middle of a building's body, for zooming in on it.
    func centre(of id: String) -> CGPoint? {
        guard let plot = plots.first(where: { $0.building.id == id }) else { return nil }
        let base = front(plot)
        return CGPoint(x: base.x, y: base.y - buildingHeight * 0.35)
    }
}

// MARK: - Canvas

struct CityCanvas: View {
    let layout: CityLayout
    let level: CityLevel
    var selectedID: String?
    /// Changes each time the tab opens; the props pop in again.
    var popBeat = 0
    let open: (CityBuilding) -> Void

    private var tile: CGFloat { layout.tile }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if level == .city {
                CitySkyline(width: layout.size.width - CityLayout.margin * 2, height: layout.buildingHeight * 0.9)
                    .offset(x: CityLayout.margin, y: CityLayout.margin + layout.buildingHeight * 0.1 + tile * 0.2)
            }
            ground
            ForEach(layout.plots.sorted { ($0.i + $0.j) < ($1.i + $1.j) }, id: \.building.id) { plot in
                plotView(plot)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    // MARK: Ground

    private var ground: some View {
        let districts = layout.districts
        let maxI = CGFloat(districts.map { $0.originI + $0.size }.max() ?? 0)
        let maxJ = CGFloat(districts.map { $0.originJ + $0.size }.max() ?? 0)
        let side = CGFloat(districts.first?.size ?? 2)
        let road = [layout.point(-0.5, -0.5), layout.point(maxI - 0.5, -0.5), layout.point(maxI - 0.5, maxJ - 0.5), layout.point(-0.5, maxJ - 0.5)]
        var lanes: [(CGPoint, CGPoint)] = []
        if maxI > side { lanes.append((layout.point(side, -0.5), layout.point(side, maxJ - 0.5))) }
        if maxJ > side { lanes.append((layout.point(-0.5, side), layout.point(maxI - 0.5, side))) }
        return ZStack(alignment: .topLeading) {
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
                districtView(districts[index], index: index)
            }
        }
    }

    @ViewBuilder
    private func districtView(_ d: CityLayout.District, index: Int) -> some View {
        let s = CGFloat(d.size), i = CGFloat(d.originI), j = CGFloat(d.originJ)
        let quad = [layout.point(i - 0.5, j - 0.5), layout.point(i + s - 0.5, j - 0.5),
                    layout.point(i + s - 0.5, j + s - 0.5), layout.point(i - 0.5, j + s - 0.5)]
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
        // Street furniture at the district's outer corners, by level: lamps from Site, trees
        // from Mahalle.
        let corners: [(CGPoint, CityProp)] = {
            var out: [(CGPoint, CityProp)] = []
            if level.rawValue >= CityLevel.site.rawValue {
                out.append((layout.point(i - 0.62, j - 0.62), .lamp))
                out.append((layout.point(i + s - 0.38, j - 0.62), .lamp))
            }
            if level.rawValue >= CityLevel.neighbourhood.rawValue {
                out.append((layout.point(i - 0.62, j + s / 2 - 0.5), .tree))
                out.append((layout.point(i + s / 2 - 0.5, j - 0.62), .tree))
            }
            return out
        }()
        ForEach(corners.indices, id: \.self) { n in
            CityPropView(prop: corners[n].1, tile: tile, glowing: level == .city)
                .modifier(PopIn(delay: PopIn.delay(seed: index * 31 + n, beat: popBeat), beat: popBeat))
                .position(x: corners[n].0.x, y: corners[n].0.y - tile * corners[n].1.height / 2)
        }
        // Repeating tasks done in this area: flower beds, trees and benches along its edges,
        // one more each time, up to sixteen.
        let chores: [(CGPoint, CityProp)] = {
            var spots: [CGPoint] = []
            for f in [0.15, 0.4, 0.65, 0.9] as [CGFloat] {
                spots.append(layout.point(i - 0.62, j + f * s - 0.5))
                spots.append(layout.point(i + f * s - 0.5, j - 0.62))
                spots.append(layout.point(i + s - 0.38, j + f * s - 0.5))
                spots.append(layout.point(i + f * s - 0.5, j + s - 0.38))
            }
            let props = CityProp.street
            return (0..<min(d.chores, spots.count)).map { n in (spots[n], props[(n + index) % props.count]) }
        }()
        ForEach(chores.indices, id: \.self) { n in
            CityPropView(prop: chores[n].1, tile: tile, glowing: level == .city)
                .modifier(PopIn(delay: PopIn.delay(seed: index * 17 + n * 5, beat: popBeat), beat: popBeat))
                .position(x: chores[n].0.x, y: chores[n].0.y - tile * chores[n].1.height / 2)
                .allowsHitTesting(false)
        }
    }

    // MARK: Buildings

    @ViewBuilder
    private func plotView(_ plot: CityLayout.Plot) -> some View {
        let base = layout.front(plot)
        let height = layout.buildingHeight
        let isSelected = plot.building.id == selectedID
        Button { open(plot.building) } label: {
            CityBuildingImage(building: plot.building, tileWidth: tile)
        }
        .buttonStyle(.plain)
        // The focused building stands out while its card is open.
        .scaleEffect(isSelected ? 1.06 : 1, anchor: .bottom)
        .shadow(color: isSelected ? Color.themeBrick.opacity(0.6) : .clear, radius: tile * 0.12)
        .animation(.snappy, value: isSelected)
        // The artwork's bottom edge (less its small inset) is the tile's front corner.
        .position(x: base.x, y: base.y - height / 2 + height * CityBuildingImage.bottomInset)
        .accessibilityLabel(CityText.accessibility(plot.building))
        // Finished buildings get a little street furniture beside them, by level.
        let props = CityProp.around(plot.building, level: level)
        ForEach(props.indices, id: \.self) { n in
            let side: CGFloat = n == 0 ? -1 : 1
            CityPropView(prop: props[n], tile: tile, glowing: level == .city)
                .modifier(PopIn(delay: PopIn.delay(seed: CityProp.seed(plot.building.id) + n, beat: popBeat), beat: popBeat))
                .position(x: base.x + side * tile * 0.56, y: base.y - tile * 0.2 - tile * props[n].height / 2)
                .allowsHitTesting(false)
        }
    }
}

/// Small street furniture in the same art style as the buildings. Props appear as the city
/// grows and pop in each time the city is opened.
enum CityProp: String, CaseIterable {
    case bush = "cali"
    case lamp = "lamba"
    case bench = "bank"
    case tree = "agac"
    case fountain = "cesme"
    case flag = "bayrak"
    case flowerBed = "tarh"
    case blossom = "erguvan"
    case planter = "saksi"
    case birdhouse = "kus"

    var imageName: String { "city-prop-\(rawValue)" }

    /// Height on screen as a share of the tile width.
    var height: CGFloat {
        switch self {
        case .bush: 0.26
        case .lamp: 0.58
        case .bench: 0.22
        case .tree: 0.62
        case .fountain: 0.34
        case .flag: 0.6
        case .flowerBed: 0.22
        case .blossom: 0.6
        case .planter: 0.3
        case .birdhouse: 0.55
        }
    }

    /// What daily work plants along a district's edges, in this order.
    static let street: [CityProp] = [.flowerBed, .bush, .planter, .blossom, .bench, .tree, .birdhouse, .fountain]

    /// What the streets have at each level: bushes at first, then lamps and benches, trees,
    /// and fountains and flags in a full city.
    static func available(at level: CityLevel) -> [CityProp] {
        switch level {
        case .building: [.bush]
        case .site: [.bush, .lamp, .bench]
        case .neighbourhood: [.bush, .lamp, .bench, .tree]
        case .city: [.bush, .lamp, .bench, .tree, .fountain, .flag]
        }
    }

    /// Two props beside a finished building, the same ones every time for that building.
    static func around(_ building: CityBuilding, level: CityLevel) -> [CityProp] {
        guard building.stage == .finished else { return [] }
        let options = available(at: level)
        let seed = seed(building.id)
        return [options[seed % options.count], options[(seed / 7) % options.count]]
    }

    /// A stable number from an id (Swift's hashValue changes between launches).
    static func seed(_ id: String) -> Int {
        id.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
    }
}

struct CityPropView: View {
    let prop: CityProp
    let tile: CGFloat
    var glowing = false

    var body: some View {
        Image(prop.imageName)
            .resizable()
            .scaledToFit()
            .frame(height: tile * prop.height)
            .shadow(color: glowing && prop == .lamp ? .yellow.opacity(0.7) : .clear, radius: tile * 0.08)
            .accessibilityHidden(true)
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
