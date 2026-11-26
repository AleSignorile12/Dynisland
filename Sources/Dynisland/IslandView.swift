import AppKit
import SwiftUI

extension Animation {
    static var islandOpen: Animation { .spring(duration: 0.5, bounce: Prefs.shared.bouncy ? 0.3 : 0.08) }
    static var islandClose: Animation { .spring(duration: 0.4, bounce: Prefs.shared.bouncy ? 0.12 : 0) }
}

/// Notch silhouette: flat top that flares out into concave "ears", rounded bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear, y: r.minY + ear), control: CGPoint(x: r.minX + ear, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + ear, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + ear + bottom, y: r.maxY), control: CGPoint(x: r.minX + ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - ear, y: r.maxY - bottom), control: CGPoint(x: r.maxX - ear, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - ear, y: r.minY + ear))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - ear, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// What the collapsed island shows beside the notch, most important first.
enum Activity: Equatable {
    case hud(HUD), charging(Int), timer, agent, score, music, download, shelf, none
    /// Same kind = same wing size. Volume steps only move the bar, they must not re-spring the whole island.
    var kind: Int {
        switch self {
        case .hud: 0
        case .charging: 1
        case .timer: 2
        case .agent: 3
        case .score: 8
        case .music: 4
        case .download: 5
        case .shelf: 6
        case .none: 7
        }
    }
}

struct IslandView: View {
    let model: IslandModel
    private let pad: CGFloat = 16, tileWidth: CGFloat = 110, spacing: CGFloat = 12

    private var activity: Activity {
        if let h = model.hud { return .hud(h) }
        if let p = model.charging { return .charging(p) }
        if model.timer.isActive { return .timer }
        if model.agents.active != nil, Prefs.shared.agentActivity { return .agent }
        if model.sports.liveForNotch != nil { return .score }
        if model.media.playing, Prefs.shared.musicActivity { return .music }
        if !model.downloads.isEmpty { return .download }
        if !model.shelf.isEmpty { return .shelf }
        return .none
    }

    private var ear: CGFloat { model.expanded ? 14 : model.banner != nil ? 10 : 6 }
    private var bottom: CGFloat { model.expanded ? 28 : model.banner != nil ? 22 : model.notch.height * 0.32 }
    /// Width of each wing beside the notch (symmetric so the notch stays centred), capped by the free menu-bar room.
    private var side: CGFloat {
        let want: CGFloat = switch activity {
        case .none: 0
        case .hud, .charging, .timer, .score: 74
        default: 38
        }
        let room = min(want, model.sideLimit)
        return room < 24 ? 0 : room
    }
    private var size: CGSize {
        if model.expanded { return model.expandedSize }
        if model.banner != nil { return CGSize(width: max(model.notch.width + 220, 420), height: model.notch.height + 58) }
        return CGSize(width: model.notch.width + side * 2, height: model.notch.height)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(ear: ear, bottom: bottom).fill(model.expanded || model.banner != nil ? Prefs.shared.island : .black) // closed stays black to blend with the notch
            Group {
                if model.expanded { expanded.transition(.blurReplace) }
                else if let b = model.banner { BannerView(banner: b, notchHeight: model.notch.height).transition(.blurReplace) }
                else { compact.transition(.blurReplace) }
            }
            .padding(.horizontal, ear)
        }
        .frame(width: size.width + ear * 2, height: size.height)
        .clipShape(NotchShape(ear: ear, bottom: bottom))
        .onChange(of: size, initial: true) { _, s in if !model.expanded { model.closedSize = s } } // for the open-when-near zone
        .simultaneousGesture(TapGesture().onEnded { model.clicked() })
        .onChange(of: model.expanded) { _, open in model.opened(open) }
        .onDrop(of: IslandModel.dropTypes, delegate: IslandDrop(model: model, airdropMaxX: ear + pad + tileWidth + spacing / 2))
        .contextMenu {
            Button("Settings…") { model.openSettings() }
            Button("Quit Dynisland") { NSApp.terminate(nil) }
        }
        .animation(model.expanded ? .islandOpen : .islandClose, value: model.expanded)
        .animation(.islandOpen, value: model.banner)
        .animation(.islandOpen, value: activity.kind)
        .animation(.snappy, value: model.zone)
        .animation(.snappy, value: model.shownSection)
        .animation(.snappy, value: model.shelfShowsClipboard)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Compact (notch + wings)

    private var compact: some View {
        HStack(spacing: 0) {
            leftWing.frame(width: side).clipped()
            Color.clear.frame(width: model.notch.width)
            rightWing.frame(width: side).clipped()
        }
        .frame(height: model.notch.height)
    }

    @ViewBuilder private var leftWing: some View {
        switch activity {
        case .hud(let h): Image(systemName: h.icon).font(.system(size: 13, weight: .semibold)).contentTransition(.symbolEffect(.replace))
        case .charging(let p): BatteryGlyph(percent: p)
        case .timer: Image(systemName: model.timer.isPaused ? "pause.fill" : "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(Prefs.shared.accent)
        case .agent: if let a = model.agents.active { AgentIcon(agent: a, size: 18) }
        case .score: if let g = model.sports.liveForNotch { ScoreWing(team: g.away, leading: true) }
        case .music: Artwork(image: model.media.artwork, size: 20, radius: 5)
        case .download: Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold)).foregroundStyle(.blue)
        case .shelf: ShelfStack(items: model.shelf)
        case .none: EmptyView()
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch activity {
        case .hud(let h): // fill stays inside its track: clipped, and animated without overshoot
            Capsule().fill(.white.opacity(0.25)).frame(width: 44, height: 5)
                .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 44 * min(1, max(0, h.level))) }
                .clipShape(Capsule())
                .animation(.smooth(duration: 0.18), value: h.level)
        case .charging(let p):
            Text("\(p)%").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.green)
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(TimerService.format(model.timer.remaining(at: ctx.date)))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(model.timer.isPaused ? .secondary : Prefs.shared.accent)
            }
        case .score: if let g = model.sports.liveForNotch { ScoreWing(team: g.home, leading: false) }
        case .agent: Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundStyle(Prefs.shared.accent).symbolEffect(.variableColor.iterative)
        case .music: Equalizer(playing: model.media.playing, colors: Prefs.shared.albumTint ? model.media.palette : [.white])
        case .download:
            ProgressRing(fraction: model.downloads.map(\.fraction).reduce(0, +) / Double(model.downloads.count)).frame(width: 16, height: 16)
        case .shelf: Text("\(model.shelf.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        case .none: EmptyView()
        }
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            tabs.frame(height: model.notch.height)
            section(model.shownSection)
                .id(model.shownSection)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding([.horizontal, .bottom], pad)
                .padding(.top, 6)
        }
    }

    /// Section icons sit either side of the camera housing.
    private var tabs: some View {
        let all = model.sections, half = (all.count + 1) / 2
        let room = (model.expandedSize.width - model.notch.width) / 2 - 12 // per side, beside the camera
        let w = max(18, min(30, room / CGFloat(max(half, 1)) - 2))
        return HStack(spacing: 0) {
            HStack(spacing: 2) { ForEach(all.prefix(half)) { tab($0, width: w) } }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
            Color.clear.frame(width: model.notch.width)
            HStack(spacing: 2) { ForEach(all.dropFirst(half)) { tab($0, width: w) } }
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 12)
        }
    }

    private func tab(_ s: IslandSection, width: CGFloat) -> some View {
        let on = model.shownSection == s
        return Button { model.selected = s } label: {
            Image(systemName: s.icon).font(.system(size: 12, weight: .medium))
                .frame(width: width, height: 22)
                .foregroundStyle(on ? .white : .secondary)
                .background(on ? .white.opacity(0.15) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(s.title)
    }

    /// A drag always shows the file shelf, whatever half was picked.
    private var clipboardShown: Bool { model.shelfShowsClipboard && !(model.dragging || model.dragNear || model.holdOpen) }

    @ViewBuilder private func section(_ s: IslandSection) -> some View {
        switch s {
        case .shelf:
            HStack(spacing: spacing) {
                AirDropTile(targeted: model.dragging && model.zone == .airdrop).frame(width: tileWidth)
                ShelfSwitch(clipboard: clipboardShown) { model.shelfShowsClipboard = $0 }
                if clipboardShown {
                    ClipboardSection(clipboard: model.clipboard).transition(.opacity)
                } else {
                    ShelfView(model: model, targeted: model.dragging && model.zone == .shelf) { model.openClickApp(for: .shelf) }
                        .transition(.opacity)
                }
                if !model.downloads.isEmpty { DownloadsView(items: model.downloads).frame(width: 180) }
            }
        case .media: MediaSection(media: model.media, audio: model.audio).opens { model.openClickApp(for: s) }
        case .calendar: CalendarSection(calendar: model.calendar).opens { model.openClickApp(for: s) }
        case .timer: TimerSection(timer: model.timer).opens { model.openClickApp(for: s) }
        case .mirror: MirrorSection(audio: model.audio).opens { model.openClickApp(for: s) }
        case .controls: ControlsSection(controls: model.controls, audio: model.audio).opens { model.openClickApp(for: s) }
        case .system: SystemSection(network: model.network).opens { model.openClickApp(for: s) }
        case .mixer: MixerSection(mixer: model.mixer).opens { model.openClickApp(for: s) }
        case .agents: AgentsSection(agents: model.agents) { model.open($0) }
        case .sports: SportsSection(sports: model.sports).opens { model.openClickApp(for: s) }
        case .captions: CaptionsSection(captions: model.captions, prompter: model.prompter) { model.openSettings() }.opens { model.openClickApp(for: s) }
        case .settings: SettingsModule { model.openSettings() }
        }
    }
}

// MARK: Drop handling (one delegate for the whole island; the zone is picked by x position)

struct IslandDrop: DropDelegate {
    let model: IslandModel
    let airdropMaxX: CGFloat

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: IslandModel.dropTypes) }
    func dropEntered(info: DropInfo) { model.dragging = true; updateZone(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { updateZone(info); return DropProposal(operation: .copy) }
    func dropExited(info: DropInfo) {
        model.dragging = false
        model.hovering = false // hover-exit is not delivered during a drag session
    }
    func performDrop(info: DropInfo) -> Bool {
        model.handleDrop(info.itemProviders(for: IslandModel.dropTypes), zone: model.zone)
        model.dragging = false
        model.dragNear = false
        model.hovering = false
        return true
    }
    private func updateZone(_ info: DropInfo) {
        let z: DropZone = model.expanded && info.location.x < airdropMaxX ? .airdrop : .shelf
        if model.zone != z { model.zone = z }
    }
}

// MARK: Pieces

struct BannerView: View {
    let banner: Banner
    let notchHeight: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 12) {
                Group {
                    if let image = banner.image { Image(nsImage: image).resizable() }
                    else { Image(systemName: banner.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(banner.tint) }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !banner.subtitle.isEmpty {
                        Text(banner.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
        }
    }
}

extension View {
    /// Clicking the view's empty area opens an app; its buttons (play, day cells…) keep working as usual.
    func opens(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle()).onTapGesture(perform: action)
    }
}

struct Placeholder: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 22))
            Text(text).font(.system(size: 11)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Tile<Content: View>: View {
    var targeted = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(targeted ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(targeted ? 0.5 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .scaleEffect(targeted ? 1.03 : 1)
    }
}

struct AirDropTile: View {
    let targeted: Bool
    var body: some View {
        Tile(targeted: targeted) {
            VStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(targeted ? .blue : .white)
                    .symbolEffect(.variableColor.iterative, isActive: targeted)
                Text("AirDrop").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Two stacked icons between AirDrop and the shelf: dropped files or clipboard history.
struct ShelfSwitch: View {
    let clipboard: Bool
    let pick: (Bool) -> Void
    var body: some View {
        VStack(spacing: 4) {
            icon("tray.full.fill", on: !clipboard, help: "Shelf") { pick(false) }
            icon("doc.on.clipboard", on: clipboard, help: "Clipboard history") { pick(true) }
        }
        .padding(3)
        .background(.white.opacity(0.07), in: Capsule())
    }
    private func icon(_ name: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(on ? .white : .secondary)
                .background(on ? .white.opacity(0.16) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ShelfView: View {
    let model: IslandModel
    let targeted: Bool
    let openApp: () -> Void
    var body: some View {
        Tile(targeted: targeted) {
            if model.shelf.isEmpty && model.landing == 0 {
                Placeholder(icon: "tray.and.arrow.down", text: "Drop files, links or text")
                    .opens(openApp)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.shelf) { ShelfTile(item: $0, model: model).transition(.scale(scale: 0.4).combined(with: .opacity)) }
                        ForEach(0..<model.landing, id: \.self) { _ in
                            ProgressView().controlSize(.small).frame(width: 66, height: 62).transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 10)
                    .animation(.spring(duration: 0.45, bounce: 0.35), value: model.shelf)
                    .animation(.easeOut(duration: 0.2), value: model.landing)
                }
                .overlay(alignment: .topTrailing) {
                    Button { model.remove(model.shelf) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Clear shelf")
                }
            }
        }
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    let model: IslandModel
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            ShelfIcon(item: item).frame(width: 40, height: 40)
            Text(item.title).font(.system(size: 10)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
        }
        .frame(width: 66)
        .padding(.vertical, 6)
        .background(.white.opacity(hover ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 }
        .onDrag { item.provider }
        .onTapGesture { item.open() }
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { model.remove([item]) } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Color(white: 0.32)))
                        .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(3)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .help("Remove from shelf")
            }
        }
        .animation(.snappy(duration: 0.18), value: hover)
        .contextMenu { Button("Remove") { model.remove([item]) } }
        .help(item.title)
    }
}

struct ShelfIcon: View {
    let item: ShelfItem
    var body: some View {
        switch item {
        case .file(let url): Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        case .link: symbol("safari.fill")
        case .text: symbol("text.quote")
        }
    }
    private func symbol(_ name: String) -> some View {
        Image(systemName: name).resizable().scaledToFit().padding(6).foregroundStyle(.white)
    }
}

/// Up to three shelf icons fanned out, shown in the left wing while collapsed.
struct ShelfStack: View {
    let items: [ShelfItem]
    var body: some View {
        ZStack {
            ForEach(Array(items.suffix(3).enumerated()), id: \.offset) { i, item in
                ShelfIcon(item: item).frame(width: 18, height: 18)
                    .rotationEffect(.degrees(Double(i - 1) * 12))
                    .offset(x: CGFloat(i - 1) * 3)
            }
        }
    }
}

struct DownloadsView: View {
    let items: [DownloadItem]
    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items.prefix(3)) { d in
                    HStack(spacing: 8) {
                        ProgressRing(fraction: d.fraction).frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(d.detail.isEmpty ? "\(Int(d.fraction * 100))%" : d.detail)
                                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProgressRing: View {
    let fraction: Double
    var tint: Color = .blue
    var lineWidth: CGFloat = 3
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.smooth, value: fraction)
    }
}

/// Battery outline whose green fill sweeps up to the current charge, with a bolt on top.
struct BatteryGlyph: View {
    let percent: Int
    @State private var fill = 0.0
    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.white.opacity(0.35), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(.green)
                    .frame(width: max(3, 24 * fill), height: 9)
                    .padding(.leading, 2)
            }
            .frame(width: 28, height: 13)
            .overlay { Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) }
            Capsule().fill(.white.opacity(0.35)).frame(width: 1.5, height: 4)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.1).delay(0.2)) { fill = Double(percent) / 100 } }
    }
}

extension ShelfItem {
    var title: String {
        switch self {
        case .file(let u): u.lastPathComponent
        case .link(let u): u.host() ?? u.absoluteString
        case .text(let t): t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    var provider: NSItemProvider {
        switch self {
        case .file(let u): NSItemProvider(contentsOf: u) ?? NSItemProvider(object: u as NSURL)
        case .link(let u): NSItemProvider(object: u as NSURL)
        case .text(let t): NSItemProvider(object: t as NSString)
        }
    }
    /// Click: open files/links, copy text.
    func open() {
        switch self {
        case .file(let u), .link(let u): NSWorkspace.shared.open(u)
        case .text(let t):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t, forType: .string)
        }
    }
}

/// One team of the live game in a wing: logo and abbreviation on the outside, score next to the notch.
struct ScoreWing: View {
    let team: SportsService.Team
    let leading: Bool
    var body: some View {
        HStack(spacing: 5) {
            if !leading { score }
            AsyncImage(url: team.logo) { $0.resizable().scaledToFit() } placeholder: { Text(team.abbr).font(.system(size: 9, weight: .bold)) }
                .frame(width: 16, height: 16)
            if leading { score }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
    private var score: some View {
        Text(team.score).font(.system(size: 13, weight: .bold).monospacedDigit()).contentTransition(.numericText()).animation(.smooth, value: team.score)
    }
}
