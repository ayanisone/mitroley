import AppKit
import Metal
import SwiftUI

// mitroley. Copyright © 2026 Ayan Mitra.

/// What mitroley itself is using, read once a second while the monitor is showing and not at all otherwise.
@Observable final class Vitals {
    static let shared = Vitals()
    var cpu = 0.0            // per cent of one core, summed over the app's threads
    var memory: UInt64 = 0   // bytes the system counts against the app
    var graphics: UInt64 = 0 // bytes of graphics memory the app's own Metal work holds
    var fps = 0.0            // how often the backdrop was drawn in the last second
    var disk: Int64?         // bytes the open session takes on disk
    var warm = "Cool"
    /// Bumped by the backdrop every time it draws.
    nonisolated(unsafe) static var frames = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastFrames = 0
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private let device = MTLCreateSystemDefaultDevice()
    @ObservationIgnored var folder: URL?

    func run(_ on: Bool) {
        if !on { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        lastFrames = Self.frames
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.read() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        read()
    }

    private func read() {
        // Processor: what every thread of the app is using just now.
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        var total = 0.0
        if task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads {
            for i in 0..<Int(count) {
                var info = thread_basic_info()
                var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
                let ok = withUnsafeMutablePointer(to: &info) { p in
                    p.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size) }
                }
                if ok == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 { total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100 }
                mach_port_deallocate(mach_task_self_, threads[i])
            }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        cpu = total
        // Memory: the footprint Activity Monitor shows.
        var vm = task_vm_info_data_t()
        var vmSize = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(vmSize)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmSize) }
        }
        if ok == KERN_SUCCESS { memory = UInt64(vm.phys_footprint) }
        graphics = UInt64(device?.currentAllocatedSize ?? 0)
        fps = Double(Self.frames - lastFrames)
        lastFrames = Self.frames
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: warm = "Cool"
        case .fair: warm = "Warm"
        case .serious: warm = "Hot"
        case .critical: warm = "Very hot"
        @unknown default: warm = "Cool"
        }
        // The session's size on disk changes slowly and takes a walk through its files: now and then, off the main thread.
        if ticks % 20 == 0, let folder {
            Task.detached(priority: .utility) { [weak self] in
                var bytes: Int64 = 0
                if let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                    while let u = walk.nextObject() as? URL { bytes += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
                }
                await MainActor.run { self?.disk = bytes }
            }
        }
        ticks += 1
    }
}

/// The resource monitor: a small card pinned to a corner of the window, like a frame counter in a game. Drag it and it
/// settles in the nearest corner. Session menu or Settings switches it on.
struct VitalsBox: View {
    @Environment(Store.self) private var store
    @AppStorage("vitalsCorner") private var corner = 1   // 0 top left, 1 top right, 2 bottom left, 3 bottom right
    @State private var drag: CGSize = .zero
    @State private var over = false

    private func size(_ b: UInt64) -> String {
        b >= 1_073_741_824 ? String(format: "%.2f GB", Double(b) / 1_073_741_824) : String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    var body: some View {
        // Sits over the picture's own space, not the whole window, and only the card itself can be touched: laid over the
        // window it took the pointer away from everything under it (the picture's subtitle and pop-out buttons went missing).
        GeometryReader { geo in
            Color.clear.allowsHitTesting(false)
                .overlay(alignment: corner == 0 ? .topLeading : corner == 1 ? .topTrailing : corner == 2 ? .bottomLeading : .bottomTrailing) {
                    if store.vitalsOn {
                        card
                            .offset(drag)
                            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("vitals"))
                                .onChanged { drag = $0.translation }
                                .onEnded { g in
                                    // Whichever corner of the picture's space it was let go nearest to.
                                    let left = g.location.x < geo.size.width / 2, top = g.location.y < geo.size.height / 2
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        corner = (top ? 0 : 2) + (left ? 0 : 1)
                                        drag = .zero
                                    }
                                })
                            // Clear of what already lives in each corner: the tools down the left, the picture's own
                            // buttons at the top right, the transport bar along the bottom.
                            // The picture's two buttons sit 18 pt in from the top and right and are 24 pt tall. The card
                            // lines up with their right edge and starts 8 pt under them.
                            .padding(.leading, corner % 2 == 0 ? 68 : 0).padding(.trailing, corner % 2 == 1 ? 18 : 0)
                            .padding(.top, corner < 2 ? (corner == 1 ? 50 : 18) : 0)
                            .padding(.bottom, corner >= 2 ? TransportBar.height + VideoPane.gap * 2 + 4 : 0)
                    }
                }
        }
        .coordinateSpace(name: "vitals")
        .onChange(of: store.vitalsOn, initial: true) { _, now in
            Vitals.shared.folder = store.subfolder("Audio").deletingLastPathComponent()
            Vitals.shared.run(now)
        }
    }

    private var card: some View {
        let v = Vitals.shared
        return VStack(alignment: .leading, spacing: 3) {
            row("CPU", String(format: "%.0f%%", v.cpu), v.cpu > 80 ? Theme.danger : v.cpu > 40 ? ConsoleMetrics.amber : ConsoleMetrics.green)
            row("Memory", size(v.memory), .white)
            row("Graphics", size(v.graphics), .white)
            row("Backdrop", String(format: "%.0f fps", v.fps), .white)
            if let d = v.disk { row("Session", size(UInt64(max(0, d))), .white) }
            row("Mac", v.warm, v.warm == "Cool" ? ConsoleMetrics.green : v.warm == "Warm" ? ConsoleMetrics.amber : Theme.danger)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 144)
        // Light enough to see the picture through; the words carry a soft shadow so they still read.
        .shadow(color: .black.opacity(0.7), radius: 1, y: 0.5)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .contentShape(Rectangle())
        // A small close button on the card itself while the pointer is on it, and the same in its right-click menu.
        .overlay(alignment: .topTrailing) {
            if over {
                Button { store.vitalsOn = false } label: {
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 16, height: 16).background(Color.black.opacity(0.75), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                        .contentShape(Circle().inset(by: -4))
                }
                .buttonStyle(PressStyle(scale: 0.9))
                .offset(x: 6, y: -6)
                .accessibilityLabel("Hide the resource monitor")
                .transition(.opacity)
            }
        }
        .onHover { over = $0 }
        .animation(.easeOut(duration: 0.12), value: over)
        .contextMenu {
            Button("Hide the Resource Monitor") { store.vitalsOn = false }
            Text("Bring it back from Session › Resource Monitor (⌥⌘R)")
        }
        .hint("What mitroley is using right now. Drag it to another corner. The cross hides it; Session › Resource Monitor (⌥⌘R) brings it back.")
    }

    private func row(_ name: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(color)
        }
    }
}
