import AppKit
import SwiftUI

/// In-memory clipboard history (text, images, files) with pinning. Not saved across launches.
@Observable
final class ClipboardService {
    enum Content: Equatable { case text(String), image(NSImage), files([URL]) }
    struct Clip: Identifiable { let id = UUID(); let content: Content; var pinned = false }

    var clips: [Clip] = []
    @ObservationIgnored private var changeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var timer: Timer?
    private static let limit = 30

    init() {
        timer = .scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        // Password managers mark secrets as concealed/transient; never record them.
        let skip: Set<NSPasteboard.PasteboardType> = [.init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")]
        guard let types = pb.types, skip.isDisjoint(with: types) else { return }

        let content: Content
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            content = .files(urls)
        } else if pb.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pb) {
            content = .image(image)
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = .text(s)
        } else { return }

        clips.removeAll { !$0.pinned && $0.content == content }
        clips.insert(Clip(content: content), at: clips.firstIndex { !$0.pinned } ?? clips.count) // pinned clips stay on top
        if let oldest = clips.last(where: { !$0.pinned }), clips.filter({ !$0.pinned }).count > Self.limit {
            clips.removeAll { $0.id == oldest.id }
        }
    }

    func copy(_ clip: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch clip.content {
        case .text(let s): pb.setString(s, forType: .string)
        case .image(let i): pb.writeObjects([i])
        case .files(let urls): pb.writeObjects(urls as [NSURL])
        }
        changeCount = pb.changeCount // don't record our own copy as a new clip
    }

    func togglePin(_ clip: Clip) {
        guard let i = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var c = clips.remove(at: i)
        c.pinned.toggle()
        clips.insert(c, at: c.pinned ? 0 : (clips.firstIndex { !$0.pinned } ?? clips.count))
    }

    func remove(_ clip: Clip) { clips.removeAll { $0.id == clip.id } }
}

struct ClipboardSection: View {
    let clipboard: ClipboardService
    @State private var copied: UUID?

    var body: some View {
        if clipboard.clips.isEmpty {
            Placeholder(icon: "doc.on.clipboard", text: "Copied items show up here")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(clipboard.clips) { clip in
                        card(clip)
                            .onTapGesture {
                                clipboard.copy(clip)
                                copied = clip.id
                            }
                            .contextMenu {
                                Button(clip.pinned ? "Unpin" : "Pin") { clipboard.togglePin(clip) }
                                Button("Delete") { clipboard.remove(clip) }
                            }
                    }
                }
            }
        }
    }

    private func card(_ clip: ClipboardService.Clip) -> some View {
        Group {
            switch clip.content {
            case .text(let s):
                Text(s).font(.system(size: 10)).lineLimit(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8)
            case .image(let i):
                Image(nsImage: i).resizable().scaledToFill()
            case .files(let urls):
                VStack(spacing: 4) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path)).resizable().frame(width: 40, height: 40)
                    Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files").font(.system(size: 10)).lineLimit(1)
                }
                .padding(6)
            }
        }
        .frame(width: 110, height: 104)
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button { clipboard.togglePin(clip) } label: {
                Image(systemName: clip.pinned ? "pin.fill" : "pin").font(.system(size: 9)).padding(5)
                    .foregroundStyle(clip.pinned ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if copied == clip.id {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(0.8)); copied = nil }
            }
        }
        .animation(.snappy, value: copied)
    }
}
