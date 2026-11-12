import AppKit
import BLEPrintCore
import SwiftUI

enum PrintMode: Int, CaseIterable, Identifiable {
    case text, qrText, qrOnly
    var id: Int { rawValue }
    var title: String { ["Text", "QR code + text", "QR code only"][rawValue] }
}

@MainActor
final class AppModel: ObservableObject {
    private let defaults = UserDefaults.standard

    // printer
    @Published var brand: Brand = Brand(rawValue: UserDefaults.standard.string(forKey: "brand") ?? "") ?? .nelko {
        didSet { defaults.set(brand.rawValue, forKey: "brand"); applyBrand() }
    }
    @Published var device: FoundDevice?
    @Published var connected = false
    @Published var connDetail = ""
    @Published var busy = false
    var driver: PrinterDriver?

    // scan
    @Published var showScan = false
    @Published var scanning = false
    @Published var scanResults: [FoundDevice] = []
    @Published var showAllDevices = false

    // settings
    @Published var headMM = UserDefaults.standard.object(forKey: "headMM") as? Double ?? 14.0 {
        didSet { defaults.set(headMM, forKey: "headMM"); refreshPreview() }
    }
    @Published var feedMM = UserDefaults.standard.object(forKey: "feedMM") as? Double ?? 40.0 {
        didSet { defaults.set(feedMM, forKey: "feedMM"); refreshPreview() }
    }
    // P21 14 x 40 mm rolls have a 5 mm gap
    @Published var gapMM = UserDefaults.standard.object(forKey: "gapMM") as? Double ?? Nelko.defaultGapMM {
        didSet { defaults.set(gapMM, forKey: "gapMM") }
    }
    @Published var density = UserDefaults.standard.object(forKey: "density") as? Int ?? 10 {
        didSet { defaults.set(density, forKey: "density") }
    }
    @Published var speed = UserDefaults.standard.object(forKey: "speed") as? Int ?? 3 {
        didSet { defaults.set(speed, forKey: "speed") }
    }
    @Published var copies = UserDefaults.standard.object(forKey: "copies") as? Int ?? 1 {
        didSet { defaults.set(copies, forKey: "copies") }
    }
    @Published var fitLength = UserDefaults.standard.object(forKey: "fitLength") as? Bool ?? true {
        didSet { defaults.set(fitLength, forKey: "fitLength"); refreshPreview() }
    }
    @Published var continuous = UserDefaults.standard.bool(forKey: "continuous") {
        didSet { defaults.set(continuous, forKey: "continuous") }
    }
    @Published var mode: PrintMode = PrintMode(rawValue: UserDefaults.standard.integer(forKey: "printMode")) ?? .text {
        didSet { defaults.set(mode.rawValue, forKey: "printMode"); refreshPreview() }
    }

    // text style
    static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
    @Published var fontFamily = UserDefaults.standard.string(forKey: "fontFamily") ?? "Arial" {
        didSet { defaults.set(fontFamily, forKey: "fontFamily"); refreshPreview() }
    }
    @Published var bold = UserDefaults.standard.object(forKey: "bold") as? Bool ?? true {
        didSet { defaults.set(bold, forKey: "bold"); refreshPreview() }
    }
    @Published var autoSize = UserDefaults.standard.object(forKey: "autoSize") as? Bool ?? true {
        didSet { defaults.set(autoSize, forKey: "autoSize"); refreshPreview() }
    }
    @Published var sizePt = UserDefaults.standard.object(forKey: "sizePt") as? Double ?? 20 {
        didSet { defaults.set(sizePt, forKey: "sizePt"); refreshPreview() }
    }
    @Published var align = TextStyle.Align(rawValue: UserDefaults.standard.object(forKey: "align") as? Int ?? 1) ?? .center {
        didSet { defaults.set(align.rawValue, forKey: "align"); refreshPreview() }
    }
    @Published var border = UserDefaults.standard.bool(forKey: "border") {
        didSet { defaults.set(border, forKey: "border"); refreshPreview() }
    }

    var style: TextStyle {
        TextStyle(family: fontFamily, bold: bold, sizePt: autoSize ? nil : max(4, sizePt), align: align,
                  border: border && mode == .text)
    }

    // data
    @Published var template = UserDefaults.standard.string(forKey: "template") ?? "" {
        didSet { defaults.set(template, forKey: "template"); refreshPreview() }
    }
    @Published var columns: [String] = []
    @Published var rows: [[String: String]] = []
    @Published var current = 0 { didSet { refreshPreview() } }
    @Published var csvName = "No CSV loaded"

    // output
    @Published var preview: CGImage?
    @Published var log: [String] = ["Ready. Find your printer, open a CSV, edit the template, preview, then print."]
    @Published var progress = (value: 0, total: 1)
    @Published var confirmPrintAll = false
    @Published var pause: (done: Int, total: Int)?
    private var pauseContinuation: CheckedContinuation<Bool, Never>?

    init() {
        applyBrand()
        BLE.shared.onDisconnect = { [weak self] in
            Task { @MainActor in
                guard let self, self.connected else { return }
                self.connected = false
                self.connDetail = ""
                self.say("Printer disconnected.")
            }
        }
        Task { await reconnectLast() }
    }

    // MARK: brand-aware settings

    var fitActive: Bool { brand.supportsFitLength && fitLength }
    var continuousActive: Bool { brand.supportsContinuous && continuous }

    func applyBrand() {
        if !brand.densityRange.contains(density) { density = brand.defaultDensity }
        if let fixed = brand.fixedHeadMM { headMM = fixed } else if headMM == 12 { headMM = 14 }   // P21 default roll: 14 x 40 mm
        if !brand.supportsContinuous { continuous = false }
        refreshPreview()
    }

    // MARK: rendering

    func text(for index: Int) -> String {
        var t = template.trimmingCharacters(in: .newlines)
        if rows.indices.contains(index) {
            for c in columns { t = t.replacingOccurrences(of: "{\(c)}", with: rows[index][c] ?? "") }
        }
        return t.isEmpty ? "Hello World!" : t
    }

    func render(_ index: Int) -> GrayImage {
        let t = text(for: index)
        switch brand {
        case .nelko:
            return mode == .text ? Render.nelkoText(t, headMM: headMM, feedMM: feedMM, style: style)
                : Render.nelkoQR(t, headMM: headMM, feedMM: feedMM, showText: mode == .qrText, style: style)
        case .supvan:
            let length: Double? = fitActive ? nil : feedMM
            return mode == .text ? Render.supvanText(t, lengthMM: length, style: style)
                : Render.supvanQR(t, lengthMM: length, showText: mode == .qrText, style: style)
        }
    }

    func refreshPreview() {
        let img = render(current)
        preview = (brand == .nelko ? img.rotatedCW() : img).cgImage   // show it reading left to right
    }

    // MARK: log

    func say(_ s: String) {
        log.append(s)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: CSV

    func openCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let parsed = CSV.parse(try String(contentsOf: url, encoding: .utf8))
            columns = parsed.columns
            rows = parsed.rows
            csvName = "\(url.lastPathComponent)  (\(rows.count) rows)"
            say("Loaded \(rows.count) rows · columns: \(columns.joined(separator: ", "))")
            current = 0
        } catch {
            say("✖ Could not read CSV: \(error.localizedDescription)")
        }
    }

    func insertColumn(_ c: String) { template += "{\(c)}" }

    func go(_ delta: Int) {
        guard !rows.isEmpty else { return }
        current = max(0, min(rows.count - 1, current + delta))
    }

    // MARK: Bluetooth

    func scan() {
        scanning = true
        say("Searching for Bluetooth devices (8 s)…")
        Task {
            do {
                let found = try await BLE.shared.scan(seconds: 8)
                scanResults = found
                say("Found \(found.count) devices, \(found.filter { $0.brand != nil }.count) supported printer(s).")
            } catch { say("✖ \(error.localizedDescription)") }
            scanning = false
        }
    }

    func connect(_ d: FoundDevice, auto: Bool = false) {
        guard let brand = d.brand, let drv = makeDriver(for: d) else { return }
        showScan = false
        device = d
        self.brand = brand
        say(auto ? "Connecting to the last printer, \(d.name)…"
                 : "Selected \(d.name) — \(brand.displayName) (detected by \(d.reason))")
        busy = true
        Task {
            do {
                connDetail = try await drv.connect(log: { [weak self] m in Task { @MainActor in self?.say(m) } })
                driver = drv
                connected = true
                defaults.set(d.id.uuidString, forKey: "lastPrinterID")
                defaults.set(d.name, forKey: "lastPrinterName")
                defaults.set(brand.rawValue, forKey: "lastPrinterBrand")
                say("Connected to \(d.name) (\(drv.label)).")
            } catch {
                say(auto ? "\(d.name) is not reachable (switched off or out of range?) — gave up. Turn it on and press Connect."
                         : "✖ \(error.localizedDescription)")
            }
            busy = false
        }
    }

    /// On launch: try the printer from last time once, without scanning.
    func reconnectLast() async {
        guard let s = defaults.string(forKey: "lastPrinterID"), let id = UUID(uuidString: s),
              let brand = Brand(rawValue: defaults.string(forKey: "lastPrinterBrand") ?? "") else { return }
        let name = defaults.string(forKey: "lastPrinterName") ?? brand.displayName
        do {
            guard let p = try await BLE.shared.knownPeripheral(id) else {
                say("The last printer, \(name), is no longer known to this Mac — use Find printer….")
                return
            }
            connect(FoundDevice(id: id, peripheral: p, name: name, rssi: 0, brand: brand, reason: "last used", mac: nil),
                    auto: true)
        } catch { say("✖ \(error.localizedDescription)") }
    }

    func toggleConnection() {
        if connected {
            driver?.disconnect()
            driver = nil
            connected = false
            connDetail = ""
            say("Disconnected.")
        } else if let d = device {
            connect(d)
        } else {
            showScan = true
            scan()
        }
    }

    // MARK: printing

    var params: PrintParams {
        var p = PrintParams()
        p.headMM = headMM; p.feedMM = feedMM; p.gapMM = gapMM
        p.density = density; p.speed = speed; p.copies = max(1, copies)
        p.continuous = continuousActive; p.fitLength = fitActive
        return p
    }

    func printCurrent() {
        let img = render(current)
        say("Printing row \(current + 1) ×\(max(1, copies))\(continuousActive ? " (continuous)" : "")…")
        run(Array(repeating: img, count: max(1, copies)))
    }

    func printAll() {
        var images: [GrayImage] = []
        for i in rows.indices { images += Array(repeating: render(i), count: max(1, copies)) }
        say("Batch printing \(rows.count) rows (\(images.count) labels)\(continuousActive ? " as one continuous job" : "")…")
        run(images)
    }

    private func run(_ images: [GrayImage]) {
        guard connected, let drv = driver else {
            say("Not connected — use Find printer… first.")
            return
        }
        busy = true
        let p = params
        let pauses = brand.pauseBetweenLabels && !p.continuous && images.count > 1
        Task {
            do {
                try await drv.printLabels(images, p,
                                          log: { [weak self] m in Task { @MainActor in self?.say(m) } },
                                          progress: { [weak self] v, t in Task { @MainActor in self?.progress = (v, max(1, t)) } },
                                          between: pauses ? { [weak self] done, total in await self?.askToContinue(done, total) ?? false } : nil)
                say("Done.")
            } catch { say("✖ \(error.localizedDescription)") }
            busy = false
        }
    }

    func askToContinue(_ done: Int, _ total: Int) async -> Bool {
        NSSound.beep()
        return await withCheckedContinuation { c in
            pauseContinuation = c
            pause = (done, total)
        }
    }

    func answerPause(_ goOn: Bool) {
        if let p = pause { say("  label \(p.done)/\(p.total) done — \(goOn ? "continuing" : "stopped by user")") }
        pause = nil
        pauseContinuation?.resume(returning: goOn)
        pauseContinuation = nil
    }
}
