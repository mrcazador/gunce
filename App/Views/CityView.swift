import SwiftUI

/// "Şehir": the city built from your work. Every task is a building; finished steps raise its
/// floors, parked work stands still and slowly fades, and work finished after a long wait
/// becomes a landmark. Nothing to manage: look at it now and then.
struct CityView: View {
    @Environment(AppStore.self) private var store
    @State private var selected: CityBuilding?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        let city = store.city()
        NavigationStack {
            VStack(spacing: 0) {
                CityHeader(city: city) { selected = $0 }
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
                        ScrollView([.horizontal, .vertical]) {
                            CityCanvas(city: city, areas: store.sortedAreas, tile: tileWidth) { selected = $0 }
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
                    }
                }
            }
            .navigationTitle("Şehir")
            .sheet(item: $selected) { building in
                CityBuildingSheet(building: building)
                    .presentationDetents([.medium])
            }
        }
    }

    private var tileWidth: CGFloat {
        78 * min(2.2, max(0.5, zoom * pinch))
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
            if let next = city.level.next {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: city.levelProgress)
                        .tint(Color.primary)
                    Text("\(next.title) için \(next.threshold - city.finished) bina daha")
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
                            .accessibilityHint("\(building.idleDays) gündür duruyor")
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

// MARK: - Canvas

/// Isometric layout: each area is a district (a square block of plots), districts sit in
/// two columns. Plots are filled in the order the tasks were created.
private struct CityCanvas: View {
    let city: CitySummary
    let areas: [Area]
    let tile: CGFloat
    let open: (CityBuilding) -> Void

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

    private var layout: (plots: [Plot], districts: [District]) {
        var groups: [(Area?, [CityBuilding])] = areas.map { area in
            (area, city.buildings.filter { $0.areaId == area.id })
        }
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
            for (n, building) in group.1.enumerated() {
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

        ZStack(alignment: .topLeading) {
            ForEach(districts.indices, id: \.self) { index in
                let d = districts[index]
                let s = CGFloat(d.size), i = CGFloat(d.originI), j = CGFloat(d.originJ)
                let quad = [point(i - 0.5, j - 0.5), point(i + s - 0.5, j - 0.5),
                            point(i + s - 0.5, j + s - 0.5), point(i - 0.5, j + s - 0.5)]
                    .map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
                let tint = d.area?.tint ?? .gray
                Path { path in path.addLines(quad); path.closeSubpath() }
                    .fill(tint.opacity(0.12))
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
            ForEach(plots.sorted { ($0.i + $0.j) < ($1.i + $1.j) }, id: \.building.id) { plot in
                let centre = point(CGFloat(plot.i), CGFloat(plot.j))
                // The image's bottom edge is the tile's front corner.
                let front = CGPoint(x: centre.x + offset.x, y: centre.y + tile / 4 + offset.y)
                Button { open(plot.building) } label: {
                    CityBuildingImage(building: plot.building, tileWidth: tile)
                }
                .buttonStyle(.plain)
                // The artwork's bottom edge (less its small inset) is the tile's front corner.
                .position(x: front.x, y: front.y - buildingHeight / 2 + buildingHeight * CityBuildingImage.bottomInset)
                .accessibilityLabel(CityText.accessibility(plot.building))
            }
        }
        .frame(width: maxX - minX, height: maxY - top + tile / 2)
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
        Image("city-\(CityTheme.current)-\(building.art.rawValue)")
            .resizable()
            .scaledToFit()
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
            .contentShape(Rectangle())
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

/// The artwork set in use. Each theme ships the same stages as `city-<theme>-<stage>` images,
/// so the look of the city can change without touching the rules.
enum CityTheme {
    static let current = "konut"
}

// MARK: - Building sheet

private struct CityBuildingSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let building: CityBuilding

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .center, spacing: 16) {
                        CityBuildingImage(building: building, tileWidth: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            if let area = store.area(building.areaId) {
                                AreaLabel(area: area)
                                    .font(.subheadline)
                            }
                            Text(building.title)
                                .font(.headline)
                            Text(CityText.stage(building))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let note = building.parkNote, !note.isEmpty, building.stage != .finished {
                    Section("Kaldığın yer") {
                        ParkNoteText(note: note)
                    }
                }
                Section {
                    if let task = store.tasks[building.id], task.status == .inbox || task.status == .parked {
                        Button(task.status == .parked ? "Devam et" : "Başla", systemImage: "play.fill") {
                            dismiss()
                            Task {
                                try? await Task.sleep(for: .milliseconds(350))
                                store.requestStart(task)
                            }
                        }
                    }
                    Button("Görevi aç", systemImage: "arrow.up.right") {
                        dismiss()
                        store.openTaskID = building.id
                    }
                } footer: {
                    if building.stage == .abandoned {
                        Text("Devam edersen toparlanır; bitirirsen şehrin anıt yapılarından biri olur.")
                    }
                }
            }
            .navigationTitle("Bina")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }
                }
            }
        }
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
            return "\(b.idleDays) gündür duruyor"
        case .abandoned:
            return "\(b.idleDays) gündür terk edilmiş"
        case .finished:
            return b.isLandmark ? "Anıt yapı: uzun bir aradan sonra bitirdin." : "Tamamlandı"
        }
    }

    static func accessibility(_ b: CityBuilding) -> String {
        "\(b.title). \(stage(b))"
    }
}
