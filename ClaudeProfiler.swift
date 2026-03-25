import SwiftUI

// MARK: - Models

struct ClaudeProcess: Identifiable {
    let id: Int
    let name: String
    let memoryMB: Double
    let cpuPercent: Double
    let command: String
}

// MARK: - Process Monitor

class ProcessMonitor: ObservableObject {
    @Published var processes: [ClaudeProcess] = []
    @Published var totalMemoryMB: Double = 0
    @Published var totalCPU: Double = 0
    @Published var tick: Int = 0  // forces menu bar label to re-render
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.ishanrai.claudeprofiler.monitor")

    init() {
        fetchInBackground()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.fetchInBackground()
        }
    }

    deinit { timer?.invalidate() }

    // Total system RAM in MB
    private static let systemMemoryMB: Double = {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
    }()

    // Heat based on % of system RAM used by Claude
    // 0.0 = nothing, 1.0 = Claude is using 15%+ of total RAM
    // Idle = no main claude CLI processes (background helpers like chrome-native-host don't count)
    var isIdle: Bool {
        !processes.contains { $0.name.lowercased() == "claude" }
    }

    var heatLevel: Double {
        let memPercent = totalMemoryMB / Self.systemMemoryMB
        let memHeat = min(memPercent / 0.15, 1.0)  // 15% of RAM = max heat
        let cpuHeat = min(totalCPU / 100.0, 1.0)
        return max(memHeat, cpuHeat)
    }

    func refresh() { fetchInBackground() }

    private func fetchInBackground() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-eo", "pid,ppid,rss,%cpu,comm"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()

            guard let _ = try? task.run() else { return }
            // Read BEFORE waitUntilExit to avoid deadlock if pipe buffer fills
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return }

            var allLines: [(pid: Int, ppid: Int, rss: Int, cpu: Double, cmd: String)] = []
            var claudePIDs: Set<Int> = []

            for line in output.components(separatedBy: "\n").dropFirst() {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                let p = t.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                guard p.count >= 5,
                      let pid = Int(p[0]), let ppid = Int(p[1]),
                      let rss = Int(p[2]), let cpu = Double(p[3]) else { continue }
                let cmd = String(p[4])
                allLines.append((pid, ppid, rss, cpu, cmd))
                let lo = cmd.lowercased()
                if lo.contains("claude") && !lo.contains("claudeprofiler") {
                    claudePIDs.insert(pid)
                }
            }

            var result: [ClaudeProcess] = []
            var seen = Set<Int>()
            for l in allLines {
                if claudePIDs.contains(l.pid) || claudePIDs.contains(l.ppid) {
                    let name = URL(fileURLWithPath: l.cmd).lastPathComponent
                    if name.lowercased().contains("claudeprofiler") { continue }
                    if seen.contains(l.pid) { continue }
                    seen.insert(l.pid)
                    result.append(ClaudeProcess(
                        id: l.pid, name: name,
                        memoryMB: Double(l.rss) / 1024.0,
                        cpuPercent: l.cpu, command: l.cmd))
                }
            }
            result.sort { $0.memoryMB > $1.memoryMB }

            DispatchQueue.main.async {
                self.processes = result
                self.totalMemoryMB = result.reduce(0) { $0 + $1.memoryMB }
                self.totalCPU = result.reduce(0) { $0 + $1.cpuPercent }
                self.tick += 1
            }
        }
    }
}

// MARK: - Sprite Loader
// Loads clawd-tank PNG frames and removes the dark blue background (#1A1A2E)

enum SpriteLoader {
    static func loadAll() -> [String: [NSImage]] {
        var result: [String: [NSImage]] = [:]
        result["idle"] = (0..<8).compactMap { loadFrame("idle", "idle_\(String(format: "%02d", $0))") }
        result["sleeping"] = (0..<6).compactMap { loadFrame("sleeping", "frame_\(String(format: "%02d", $0))") }
        result["alert"] = (0..<6).compactMap { loadFrame("alert", "frame_\(String(format: "%02d", $0))") }
        result["happy"] = (0..<6).compactMap { loadFrame("happy", "frame_\(String(format: "%02d", $0))") }
        return result
    }

    private static func loadFrame(_ dir: String, _ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png",
                                        subdirectory: "sprites/\(dir)"),
              let nsImg = NSImage(contentsOf: url),
              let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let w = cg.width, h = cg.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let px = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }

        // Make background transparent (bg = #1A1A2E with tolerance)
        for i in 0..<(w * h) {
            let o = i * 4
            let r = Int(px[o]), g = Int(px[o+1]), b = Int(px[o+2])
            if abs(r - 0x1A) < 20 && abs(g - 0x1A) < 20 && abs(b - 0x2E) < 20 {
                px[o] = 0; px[o+1] = 0; px[o+2] = 0; px[o+3] = 0
            }
        }

        guard let processed = ctx.makeImage() else { return nil }
        return NSImage(cgImage: processed, size: NSSize(width: w, height: h))
    }
}

// MARK: - Crab View (real clawd-tank PNG sprites + dynamic heat effects)

struct CrabView: View {
    var heat: Double
    var isIdle: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0)) { tl in
            CrabCanvas(heat: heat, isIdle: isIdle, time: tl.date.timeIntervalSinceReferenceDate)
        }
    }
}

struct CrabCanvas: View {
    let heat: Double
    let isIdle: Bool
    let time: Double

    private static let sprites = SpriteLoader.loadAll()

    private var animState: (name: String, fps: Double) {
        if isIdle { return ("sleeping", 1.5) }
        if heat > 0.7 { return ("alert", 4.0) }
        if heat > 0.4 { return ("idle", 3.0) }
        return ("idle", 2.0)
    }

    private var currentFrame: NSImage? {
        let (name, fps) = animState
        guard let frames = Self.sprites[name], !frames.isEmpty else { return nil }
        return frames[Int(time * fps) % frames.count]
    }

    // Color multiply tint — shifts toward red as heat increases
    private var tintColor: Color {
        if heat > 0.7 {
            let t = min((heat - 0.7) / 0.3, 1.0)
            return Color(red: 1.0, green: 1.0 - t * 0.4, blue: 1.0 - t * 0.5)
        }
        if heat > 0.4 {
            let t = (heat - 0.4) / 0.3
            return Color(red: 1.0, green: 1.0 - t * 0.1, blue: 1.0 - t * 0.15)
        }
        return .white
    }

    var body: some View {
        ZStack {
            if let frame = currentFrame {
                Image(nsImage: frame)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .colorMultiply(tintColor)
            }

            // Overlays: construction hat, sweat, steam
            Canvas { ctx, size in
                let cx: CGFloat = size.width / 2  // center of crab
                let headY: CGFloat = 27.5         // crab head top in view coords

                // Construction hat when working (heat 0.3–0.6)
                // Pixel-art hard hat matching the crab's 1.5pt pixel size
                if !isIdle && heat > 0.4 && heat <= 0.7 {
                    let ps: CGFloat = 1.5  // pixel size (matches crab sprite scale)
                    let yellow  = Color(red: 1.0, green: 0.84, blue: 0.0)
                    let darkYel = Color(red: 0.85, green: 0.68, blue: 0.0)
                    let band    = Color(red: 0.80, green: 0.55, blue: 0.0)
                    let shadow  = Color(red: 0.70, green: 0.52, blue: 0.0)
                    let shine   = Color(red: 1.0, green: 0.95, blue: 0.6)

                    // Hat rows: (width in pixels, color)
                    // Dome tapers from narrow top to wide brim
                    let rows: [(w: CGFloat, c: Color)] = [
                        ( 6, yellow),    // tip
                        ( 8, yellow),    // dome
                        (10, yellow),    // dome
                        (12, yellow),    // dome
                        (14, darkYel),   // dome lower
                        (14, band),      // band / ridge
                        (14, band),      // band
                        (16, darkYel),   // below band
                        (22, yellow),    // brim top
                        (24, yellow),    // brim
                        (26, yellow),    // brim widest
                        (24, shadow),    // brim underside
                    ]

                    let hatBottom = headY - 1  // sits just on the head
                    let hatTop = hatBottom - CGFloat(rows.count) * ps

                    for (i, row) in rows.enumerated() {
                        let w = row.w * ps
                        let x = cx - w / 2
                        let y = hatTop + CGFloat(i) * ps
                        ctx.fill(Path(CGRect(x: x, y: y, width: w, height: ps)),
                                 with: .color(row.c))
                    }

                    // Shine highlight on dome (2 rows, offset left)
                    ctx.fill(Path(CGRect(x: cx - 4 * ps, y: hatTop + 2 * ps,
                                         width: 3 * ps, height: ps)),
                             with: .color(shine.opacity(0.5)))
                    ctx.fill(Path(CGRect(x: cx - 3 * ps, y: hatTop + 3 * ps,
                                         width: 2 * ps, height: ps)),
                             with: .color(shine.opacity(0.3)))

                    // Hammer held in right claw
                    let wood      = Color(red: 0.50, green: 0.30, blue: 0.12)
                    let woodLight = Color(red: 0.62, green: 0.40, blue: 0.18)
                    let metal     = Color(red: 0.58, green: 0.58, blue: 0.62)
                    let metalLt   = Color(red: 0.75, green: 0.75, blue: 0.80)

                    // Swing animation
                    let swing = CGFloat(sin(time * 4.0) * 3.0)

                    // Anchor at right claw: grid (58, 33) → view (94, 51.5)
                    let hx: CGFloat = 95
                    let clawY: CGFloat = 51.5

                    // Handle: 2px wide, 12px tall, going up from claw
                    let handleH: CGFloat = 12 * ps
                    let handleTop = clawY - handleH + swing
                    ctx.fill(Path(CGRect(x: hx, y: handleTop,
                                         width: 2 * ps, height: handleH)),
                             with: .color(wood))
                    // Handle highlight strip
                    ctx.fill(Path(CGRect(x: hx + ps, y: handleTop,
                                         width: ps, height: handleH)),
                             with: .color(woodLight))

                    // Hammer head: 7px wide, 4px tall, centered on handle top
                    let headW: CGFloat = 7 * ps
                    let headH: CGFloat = 4 * ps
                    let headX = hx + ps - headW / 2  // centered on handle
                    let headTop = handleTop - headH + ps
                    ctx.fill(Path(CGRect(x: headX, y: headTop,
                                         width: headW, height: headH)),
                             with: .color(metal))
                    // Head shine (top row)
                    ctx.fill(Path(CGRect(x: headX, y: headTop,
                                         width: headW, height: ps)),
                             with: .color(metalLt))
                    // Head shadow (bottom row)
                    ctx.fill(Path(CGRect(x: headX, y: headTop + headH - ps,
                                         width: headW, height: ps)),
                             with: .color(metal.opacity(0.7)))
                    // Claw face (peen) — flat end on left side
                    ctx.fill(Path(CGRect(x: headX - ps, y: headTop + ps,
                                         width: ps, height: 2 * ps)),
                             with: .color(metal))
                }

                // Sweat drops when hot
                if heat > 0.6 {
                    let cr = CGRect(x: 7, y: 2, width: 96, height: 96)
                    let sweat = Color(red: 0.45, green: 0.72, blue: 0.95)
                    for i in 0..<2 {
                        let phase = (time * 1.8 + Double(i) * 1.5)
                            .truncatingRemainder(dividingBy: 3.0)
                        let dy = cr.minY + 12 + CGFloat(phase) * 28
                        let a = phase < 0.3 ? phase / 0.3
                            : max(0, 1.0 - (phase - 0.3) / 2.7)
                        let dx = i == 0 ? cr.minX + 5 : cr.maxX - 8
                        ctx.fill(Path(CGRect(x: dx, y: dy, width: 3, height: 5)),
                                 with: .color(sweat.opacity(a * 0.8)))
                    }
                }

                // Steam puffs when very hot
                if heat > 0.7 {
                    for i in 0..<3 {
                        let phase = (time * 0.7 + Double(i) * 1.0)
                            .truncatingRemainder(dividingBy: 3.5)
                        let sy: CGFloat = 2 - CGFloat(phase) * 12
                        let a = max(0, 1.0 - phase / 3.0) * 0.4
                        let sx = cx - 12 + CGFloat(i) * 12
                        ctx.fill(Path(CGRect(x: sx, y: sy, width: 5, height: 3)),
                                 with: .color(Color.white.opacity(a)))
                    }
                }
            }
            .frame(width: 110, height: 100)
            .allowsHitTesting(false)
        }
        .frame(width: 110, height: 100)
    }
}

// MARK: - App

@main
struct ClaudeProfilerApp: App {
    @StateObject private var monitor = ProcessMonitor()

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
                .frame(width: 440, height: monitor.processes.isEmpty ? 420 : 560)
        } label: {
            let _ = monitor.tick  // subscribe to changes
            let mem = monitor.totalMemoryMB
            if mem > 0 {
                let memStr = mem >= 1024
                    ? String(format: "%.1fG", mem / 1024)
                    : String(format: "%.0fM", mem)
                Text("◆ \(memStr)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            } else {
                Text("◆")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var monitor: ProcessMonitor

    private let bgColor = Color(red: 0.07, green: 0.07, blue: 0.11)
    private let bgDarker = Color(red: 0.05, green: 0.05, blue: 0.08)
    private let accent = Color(red: 0.90, green: 0.58, blue: 0.27)
    private let dim = Color(white: 0.35)
    private let txt = Color(white: 0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            divider
            crabSection
            divider
            statsBar
            divider
            if monitor.processes.isEmpty {
                emptyState
            } else {
                processList
            }
            divider
            footerView
        }
        .background(bgColor)
    }

    private var divider: some View {
        Rectangle().fill(accent.opacity(0.15)).frame(height: 1)
    }

    // MARK: Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Text("◆")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(accent)
            Text("CLAUDE PROFILER")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(accent)
            Spacer()
            Text("v1.0")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(dim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Crab Section

    private var crabSection: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                CrabView(heat: monitor.heatLevel, isIdle: monitor.isIdle)
                Text(crabMood)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(moodColor)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .background(bgDarker)
    }

    private var crabMood: String {
        if monitor.isIdle { return "zzz... no claude running" }
        let h = monitor.heatLevel
        if h > 0.7 { return "sweating!! too many processes!" }
        if h > 0.4 { return "working hard..." }
        return "chillin ~"
    }

    private var moodColor: Color {
        if monitor.processes.isEmpty { return dim }
        let h = monitor.heatLevel
        if h > 0.7 { return Color(red: 0.90, green: 0.30, blue: 0.25) }
        if h > 0.4 { return accent }
        return Color(red: 0.4, green: 0.75, blue: 0.4)
    }

    // MARK: Stats

    private var statsBar: some View {
        HStack(spacing: 24) {
            statBlock(label: "MEM", value: fmtMem(monitor.totalMemoryMB),
                      color: monitor.totalMemoryMB > 0 ? accent : dim)
            statBlock(label: "CPU", value: String(format: "%.1f%%", monitor.totalCPU),
                      color: monitor.totalCPU > 0 ? txt : dim)
            Spacer()
            statBlock(label: "PRC", value: "\(monitor.processes.count)", color: txt)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bgDarker)
    }

    private func statBlock(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(dim)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
    }

    // MARK: Empty / Process List

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("- - -")
                .font(.system(size: 16, design: .monospaced))
                .foregroundColor(dim.opacity(0.5))
            Text("no claude processes detected")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(dim)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("PID").frame(width: 60, alignment: .leading)
                Text("NAME").frame(width: 205, alignment: .leading)
                Text("MEM").frame(width: 80, alignment: .trailing)
                Text("CPU").frame(width: 65, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(dim)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(monitor.processes) { proc in processRow(proc) }
                }
            }
            .frame(maxHeight: 300)

            // Bottom padding so last row doesn't hug the footer
            Spacer().frame(height: 4)
        }
    }

    private func processRow(_ proc: ClaudeProcess) -> some View {
        HStack(spacing: 0) {
            Text(String(proc.id))
                .frame(width: 60, alignment: .leading)
                .foregroundColor(dim)
            Text(proc.name)
                .frame(width: 205, alignment: .leading)
                .foregroundColor(txt)
                .lineLimit(1).truncationMode(.middle)
            Text(fmtMem(proc.memoryMB))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(memColor(proc.memoryMB))
            Text(String(format: "%.1f%%", proc.cpuPercent))
                .frame(width: 65, alignment: .trailing)
                .foregroundColor(txt)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.015))
    }

    // MARK: Footer

    private var footerView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(monitor.isIdle ? dim : Color.green)
                .frame(width: 6, height: 6)
            Text("refresh: 3s")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(dim)
            Spacer()
            Button(action: { monitor.refresh() }) {
                Text("REFRESH")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(accent)
            }.buttonStyle(.plain)
            Text("|")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(dim.opacity(0.4))
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("QUIT")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(red: 0.85, green: 0.30, blue: 0.30))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Helpers

    private func fmtMem(_ mb: Double) -> String {
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return "0 MB"
    }

    private func memColor(_ mb: Double) -> Color {
        if mb > 500 { return Color(red: 0.85, green: 0.30, blue: 0.30) }
        if mb > 200 { return accent }
        return txt
    }
}
