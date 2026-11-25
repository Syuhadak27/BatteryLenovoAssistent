//
//  AppDelegate.swift
//  ThinkpadAssistant
//
//  Dikelola oleh Syuhadak27. https://github.com/Syuhadak27/ThinkpadAssistent
//

import Cocoa
import ServiceManagement
import IOKit
import IOKit.ps
import Darwin
import Sparkle

private extension Notification.Name {
    static let powerSourceDidChange = Notification.Name("BatterySync.PowerSourceDidChange")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    let helperBundleName = "de.mszturc.AutoLaunchHelper"

    // Battery threshold (YogaSMC ThinkVPC) — lihat SUMMARY.md bagian 4 dan 9.
    private weak var thresholdBatteryItem: NSMenuItem?
    private weak var thresholdPowerItem: NSMenuItem?
    private weak var thresholdEC0Item: NSMenuItem?
    private weak var thresholdEC1Item: NSMenuItem?
    private weak var thresholdSummaryItem: NSMenuItem?
    private weak var thresholdStartItem: NSMenuItem?
    private weak var thresholdStopItem: NSMenuItem?
    private weak var thresholdEnableItem: NSMenuItem?
    private weak var thresholdECStatusItem: NSMenuItem?
    private weak var thresholdECDirectItem: NSMenuItem?

    // Sparkle 2 — singleton, dibuat di main actor saat menu disiapkan.
    @MainActor private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    // Battery sync monitoring (IOPowerSources = sumber angka ikon macOS).
    private var batteryRefreshTimer: Timer?
    private var powerRefreshTimer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var batteryMismatchSince: Date?
    private var lastDisplayedPercent: Int?
    private var pendingForceApply: DispatchWorkItem?
    private var ecReapplyTimer: Timer?
    private let thresholdQueue = DispatchQueue(label: "BatteryThreshold.ECReapply", qos: .utility)

    @IBOutlet weak var statusBarMenu: NSMenu!

    @IBOutlet weak var monitorCapslocksMenuItem: NSMenuItem!
    @IBOutlet weak var launchAtLoginMenuItem: NSMenuItem!

    // UI baru
    private let statusBatteryView = StatusBarBatteryView(frame: NSRect(x: 0, y: 0, width: 220, height: 42))
    private var settingsWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?

    @MainActor
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMenuBar()
        ShortcutManager.register()
        CapslockMonitor.register()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        ShortcutManager.unregister()
    }

    @IBAction func launchAtLoginPressed(_ sender: NSMenuItem) {
        if sender.state == .off {
            sender.state = .on
            SMLoginItemSetEnabled(helperBundleName as CFString, true)
        } else {
            sender.state = .off
            SMLoginItemSetEnabled(helperBundleName as CFString, false)
        }
    }

    @IBAction func monitorCapslockPressed(_ sender: NSMenuItem) {
        if(sender.state == .off) {
            sender.state = .on
            CapslockMonitor.start()
        } else {
            sender.state = .off
            CapslockMonitor.stop()
        }
    }

    @MainActor
    func setupMenuBar() {
        statusItem.button?.image = NSImage(named: "menuIcon")
        statusItem.button?.alternateImage = NSImage(named: "menuIcon-light")

        statusItem.button?.image?.size = NSSize(width: 18, height: 18)
        statusItem.button?.alternateImage?.size = NSSize(width: 18, height: 18)

        statusItem.menu = statusBarMenu

        rebuildMenu()

        startBatteryMonitoring()
    }

    /// Menu dropdown：header baterai (hijau) + Pengaturan + Cek Update + Tentang + Keluar.
    /// Item menu lainnya memakai tampilan putih standar.
    @MainActor
    private func rebuildMenu() {
        statusBarMenu.removeAllItems()

        // 1. Header: ikon baterai + persentase + status + progress bar (hijau).
        let headerItem = NSMenuItem()
        headerItem.view = statusBatteryView
        statusBarMenu.addItem(headerItem)
        statusBarMenu.addItem(NSMenuItem.separator())

        // 2. Pengaturan (membuka panel, bukan submenu).
        statusBarMenu.addItem(menuItem(
            NSLocalizedString("Pengaturan", comment: ""),
            action: #selector(openSettings(_:)),
            keyEquivalent: ",",
            modifiers: [.command]
        ))

        // 3. Cek Update di menu utama.
        statusBarMenu.addItem(menuItem(
            NSLocalizedString("Cek Update", comment: ""),
            action: #selector(checkForUpdatesPressed(_:)),
            keyEquivalent: ""
        ))

        statusBarMenu.addItem(NSMenuItem.separator())

        // 4. Tentang.
        statusBarMenu.addItem(menuItem(
            NSLocalizedString("Tentang", comment: ""),
            action: #selector(openAbout(_:)),
            keyEquivalent: ""
        ))

        // 5. Keluar.
        statusBarMenu.addItem(menuItem(
            NSLocalizedString("Keluar", comment: ""),
            action: #selector(quitPressed(_:)),
            keyEquivalent: "q",
            modifiers: [.command]
        ))
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String, modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    // MARK: - Battery threshold (YogaSMC / ThinkVPC)
    //
    // Referensi lokal: YogaSMC 1.5.3. Threshold ditulis lewat properti IOUserClient,
    // BUKAN lewat SMC key B0St/B0Sp/B0En (key itu tidak ada / bukan threshold).
    //
    //   {"setCMstart": 80, "Battery": 1}  -> ThinkVPC::setPropertiesGated()
    //   {"setCMstop":  90, "Battery": 1}  -> ThinkVPC::setConservation()
    //                                     -> ACPI BCCS / BCSS -> EC
    //
    // "Battery": 0 = ANY, 1 = PRIMARY, 2 = SECONDARY (default YogaSMC = 1).
    // Nama key internal (BCTG/BCSG) sengaja TIDAK dipakai di UI — debug log saja.
    private enum BatteryThresholdError: LocalizedError {
        case serviceNotFound
        case setFailed(IOReturn)

        var errorDescription: String? {
            switch self {
            case .serviceNotFound:
                return NSLocalizedString("Layanan ThinkVPC (YogaSMC) nggak ketemu. Pastikan YogaSMC 1.5.3 ke-load.", comment: "")
            case .setFailed(let kr):
                return String(format: NSLocalizedString("Gagal nulis batas (0x%08X). Mungkin butuh hak admin.", comment: ""), kr)
            }
        }
    }

    /// Akses EC langsung lewat YogaSMCUserClient.
    ///
    /// Bukti dari folder ACPI + KEXT (tidak diubah):
    /// - `ACPI/SSDT-EC.aml` mendefinisikan `RE1B` (baca 1 byte EC) dan `WE1B`
    ///   (tulis 1 byte EC) di bawah `\_SB.PCI0.LPC.EC`.
    /// - `Kexts/YogaSMC-*.kext` mengekspos keduanya lewat `YogaSMCUserClient`:
    ///   selector 0 = open, 1 = close, 2 = readEC, 3 = writeEC, 4 = readECName.
    ///   `writeEC(offset, byte)` memanggil `method_we1b()` -> ACPI `WE1B`,
    ///   dan hanya menerima 1 byte dengan offset <= 0x99.
    ///
    /// Ini jalur "benar-benar menulis ke EC" yang dipakai saat Direct EC aktif.
    private enum ECBridgeError: LocalizedError {
        case serviceNotFound
        case openFailed(IOReturn)
        case callFailed(String, IOReturn)

        var errorDescription: String? {
            switch self {
            case .serviceNotFound:
                return NSLocalizedString("Layanan ThinkVPC (YogaSMC) nggak ketemu.", comment: "")
            case .openFailed(let kr):
                return String(format: NSLocalizedString("Gagal buka koneksi YogaSMC (0x%08X).", comment: ""), kr)
            case .callFailed(let name, let kr):
                return String(format: NSLocalizedString("YogaSMC %@ gagal (0x%08X).", comment: ""), name, kr)
            }
        }
    }

    private final class YogaSMCECBridge {
        static let shared = YogaSMCECBridge()
        private init() {}

        private enum Selector: UInt32 {
            case open = 0
            case close = 1
            case readEC = 2
            case writeEC = 3
            case readECName = 4
        }

        private let lock = NSLock()
        private var connect: io_connect_t = 0

        private var ioPort: mach_port_t {
            if #available(macOS 12.0, *) { return kIOMainPortDefault }
            return kIOMasterPortDefault
        }

        private func ensureConnection() throws -> io_connect_t {
            lock.lock()
            defer { lock.unlock() }
            if connect != 0 { return connect }

            let service = IOServiceGetMatchingService(ioPort, IOServiceMatching("ThinkVPC"))
            guard service != 0 else { throw ECBridgeError.serviceNotFound }
            defer { IOObjectRelease(service) }

            var newConnect: io_connect_t = 0
            let kr = IOServiceOpen(service, mach_task_self_, 0, &newConnect)
            guard kr == kIOReturnSuccess else { throw ECBridgeError.openFailed(kr) }

            // YogaSMCUserClient::writeEC/readEC menolak kalau provider belum
            // di-open oleh client ini. Selector 0 = userClientOpen().
            let opened = IOConnectCallMethod(newConnect, Selector.open.rawValue,
                                             nil, 0, nil, 0, nil, nil, nil, nil)
            if opened != kIOReturnSuccess {
                NSLog("[BatteryEC] WARN userClientOpen returned 0x%08X", opened)
            }
            connect = newConnect
            return newConnect
        }

        func readByte(_ offset: UInt8) throws -> UInt8 {
            let c = try ensureConnection()
            var scalar = UInt64(offset)
            var output = UInt8(0)
            var outputSize = 1
            let kr = withUnsafePointer(to: &scalar) { scalarPtr in
                withUnsafeMutablePointer(to: &output) { outPtr in
                    withUnsafeMutablePointer(to: &outputSize) { sizePtr in
                        IOConnectCallMethod(c, Selector.readEC.rawValue,
                                            scalarPtr, 1, nil, 0, nil, nil, outPtr, sizePtr)
                    }
                }
            }
            guard kr == kIOReturnSuccess else { throw ECBridgeError.callFailed("readEC", kr) }
            return output
        }

        func writeByte(_ offset: UInt8, _ value: UInt8) throws {
            let c = try ensureConnection()
            var scalar = UInt64(offset)
            var input = value
            let kr = withUnsafePointer(to: &scalar) { scalarPtr in
                withUnsafePointer(to: &input) { inPtr in
                    IOConnectCallMethod(c, Selector.writeEC.rawValue,
                                        scalarPtr, 1, inPtr, 1, nil, nil, nil, nil)
                }
            }
            guard kr == kIOReturnSuccess else { throw ECBridgeError.callFailed("writeEC", kr) }
        }

        func closeConnection() {
            lock.lock()
            defer { lock.unlock() }
            if connect != 0 {
                _ = IOConnectCallMethod(connect, Selector.close.rawValue,
                                        nil, 0, nil, 0, nil, nil, nil, nil)
                IOServiceClose(connect)
                connect = 0
            }
        }
    }

    private struct BatteryStatus {
        let name: String
        let percent: Int
        let stateText: String
    }

    /// Sumber kebenaran: IOPowerSources — persis yang dipakai macOS untuk ikon baterai.
    /// Di X260 ini menggabungkan BAT0 + BAT1 menjadi satu "InternalBattery".
    private struct MacOSBatteryStatus {
        let percent: Int
        let stateText: String
        let current: Int
        let max: Int
        let timeRemainingMinutes: Int?
    }

    private enum MacOSBatteryReader {
        static func read() -> MacOSBatteryStatus? {
            let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            guard let array = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
                return nil
            }

            for source in array {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?
                        .takeUnretainedValue() as? [String: Any],
                      let type = description[kIOPSTypeKey as String] as? String,
                      type == kIOPSInternalBatteryType else { continue }

                let current = int(description[kIOPSCurrentCapacityKey as String])
                let maxCapacity = int(description[kIOPSMaxCapacityKey as String])
                let percent = maxCapacity > 0
                    ? min(100, max(0, Int(round(Double(current) / Double(maxCapacity) * 100))))
                    : 0

                let charging = description[kIOPSIsChargingKey as String] as? Bool ?? false
                let state = description[kIOPSPowerSourceStateKey as String] as? String ?? ""
                let stateText: String
                if charging {
                    stateText = NSLocalizedString("Lagi Ngisi", comment: "")
                } else if state == kIOPSACPowerValue {
                    stateText = NSLocalizedString("Colok, nggak ngisi", comment: "")
                } else {
                    stateText = NSLocalizedString("Pakai Baterai", comment: "")
                }

                let remaining = charging
                    ? int(description[kIOPSTimeToFullChargeKey as String],
                          fallback: -1)
                    : int(description[kIOPSTimeToEmptyKey as String],
                          fallback: -1)

                return MacOSBatteryStatus(
                    percent: percent,
                    stateText: stateText,
                    current: current,
                    max: maxCapacity,
                    timeRemainingMinutes: remaining >= 0 ? remaining : nil
                )
            }
            return nil
        }

        private static func int(_ value: Any?, fallback: Int = 0) -> Int {
            (value as? NSNumber)?.intValue ?? fallback
        }
    }

    /// Arus + tegangan real-time dari baterai.
    /// Sumber utama: IOPowerSources (kIOPSVoltageKey mV, kIOPSCurrentKey mA).
    /// Fallback: AppleSmartBattery di IORegistry (InstantAmperage / Amperage).
    private struct LivePowerStatus {
        let voltageMV: Int
        let currentMA: Int
        let charging: Bool
        let acConnected: Bool

        var amps: Double { Double(abs(currentMA)) / 1000 }
        var watts: Double { abs(Double(voltageMV) * Double(currentMA)) / 1_000_000 }

        /// Charger nyolok tapi arus ≈ 0 / nggak dilaporkan ngisi:
        /// bisa karena threshold stop, bisa juga karena baterai sudah penuh.
        var stoppedWhilePlugged: Bool {
            acConnected && (!charging || abs(currentMA) < 50)
        }
    }

    private enum LivePowerReader {
        static func read() -> LivePowerStatus? {
            let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
                return nil
            }

            var acConnected = false
            var charging = false
            var sourceVoltage: Int?
            var sourceCurrent: Int?

            for source in sources {
                guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                        .takeUnretainedValue() as? [String: Any] else { continue }

                if desc[kIOPSPowerSourceStateKey as String] as? String == kIOPSACPowerValue {
                    acConnected = true
                }
                guard desc[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType else { continue }

                charging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
                sourceVoltage = validInt(desc[kIOPSVoltageKey as String], in: 1...50_000)
                sourceCurrent = validInt(desc[kIOPSCurrentKey as String], in: -100_000...100_000)
            }

            // Tanpa charger, baris daya memang sengaja disembunyikan.
            guard acConnected else { return nil }

            let registry = registryElectrical()
            let voltage = sourceVoltage ?? registry.voltage
            let current: Int?
            if let fromIOPS = sourceCurrent, fromIOPS != 0 {
                current = fromIOPS
            } else {
                current = registry.current ?? sourceCurrent
            }
            guard let v = voltage, let i = current else { return nil }

            return LivePowerStatus(
                voltageMV: v,
                currentMA: i,
                charging: charging,
                acConnected: acConnected
            )
        }

        /// AppleSmartBattery cadangan kalau IOPS Current = 0 (sering di Hackintosh).
        private static func registryElectrical() -> (voltage: Int?, current: Int?) {
            let service = IOServiceGetMatchingService(
                kIOMasterPortDefault,
                IOServiceMatching("AppleSmartBattery")
            )
            guard service != 0 else { return (nil, nil) }
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &properties, kCFAllocatorDefault, 0
            ) == kIOReturnSuccess,
            let dict = properties?.takeRetainedValue() as? [String: Any] else {
                return (nil, nil)
            }
            let voltage = validInt(dict["Voltage"], in: 1...50_000)
            let current = validInt(dict["InstantAmperage"], in: -100_000...100_000)
                ?? validInt(dict["Amperage"], in: -100_000...100_000)
            return (voltage, current)
        }

        private static func validInt(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
            guard let number = (value as? NSNumber)?.intValue, range.contains(number) else {
                return nil
            }
            return number
        }
    }

    private final class BatteryThresholdManager {
        static let shared = BatteryThresholdManager()
        private init() {}

        private let serviceName = "ThinkVPC"
        private let batteryProperty = "Battery"
        private let batteryIndex = 1   // BAT_PRIMARY

        private let defaults = UserDefaults.standard
        private let startKey = "BatteryThreshold.Start"
        private let stopKey = "BatteryThreshold.Stop"
        private let enabledKey = "BatteryThreshold.Enabled"

        // Jalur EC langsung (opsional, Advanced). Default OFF karena offset
        // RAM EC tidak bisa dibuktikan dari folder ACPI/KEXT yang diberikan.
        private let ecDirectKey = "BatteryThreshold.ECDirectEnabled"
        private let ecStartOffsetKey = "BatteryThreshold.ECStartOffset"
        private let ecStopOffsetKey = "BatteryThreshold.ECStopOffset"
        private let ecInhibitOffsetKey = "BatteryThreshold.ECInhibitOffset"
        private var ecDidLogFailure = false

        private func stored(_ key: String, fallback: Int) -> Int {
            guard let value = defaults.object(forKey: key) as? Int else { return fallback }
            return min(100, max(0, value))
        }

        var start: Int { stored(startKey, fallback: 75) }
        var stop: Int { stored(stopKey, fallback: 85) }

        var isEnabled: Bool {
            get { defaults.object(forKey: enabledKey) as? Bool ?? true }
            set { defaults.set(newValue, forKey: enabledKey) }
        }

        var ecDirectEnabled: Bool {
            get { defaults.object(forKey: ecDirectKey) as? Bool ?? false }
            set { defaults.set(newValue, forKey: ecDirectKey) }
        }

        /// Offset EC hanya dipakai kalau 0x01–0x99. 0 / belum di-set = tidak ditulis.
        private func ecOffset(_ key: String) -> UInt8? {
            let value = defaults.object(forKey: key) as? Int ?? 0
            return (1...0x99).contains(value) ? UInt8(value) : nil
        }

        var ecStartOffset: UInt8? { ecOffset(ecStartOffsetKey) }
        var ecStopOffset: UInt8? { ecOffset(ecStopOffsetKey) }
        var ecInhibitOffset: UInt8? { ecOffset(ecInhibitOffsetKey) }

        func setECOffsets(start: UInt8?, stop: UInt8?, inhibit: UInt8?) {
            func store(_ value: UInt8?, _ key: String) {
                if let value = value {
                    defaults.set(Int(value), forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            store(start, ecStartOffsetKey)
            store(stop, ecStopOffsetKey)
            store(inhibit, ecInhibitOffsetKey)
            ecDidLogFailure = false
        }

        private func copyService() throws -> io_registry_entry_t {
            let matching = IOServiceMatching(serviceName)
            let service = IOServiceGetMatchingService(kIOMasterPortDefault, matching)
            guard service != 0 else { throw BatteryThresholdError.serviceNotFound }
            return service
        }

        /// Kirim beberapa dictionary secara BERURUTAN. ThinkVPC::setPropertiesGated()
        /// mengiterasi key NSDictionary (urutan tidak terjamin), jadi `Battery`
        /// harus dikirim lebih dulu supaya indeks baterai benar sebelum BCCS/BCSS.
        private func send(_ batches: [[String: Any]]) throws {
            let service = try copyService()
            defer { IOObjectRelease(service) }

            var kr: IOReturn = kIOReturnSuccess
            for props in batches {
                let cfProps = props as NSDictionary as CFTypeRef
                kr = IORegistryEntrySetCFProperties(service, cfProps)
                if kr == kIOReturnSuccess { continue }

                // Fallback: user client resmi YogaSMC (IOConnectSetCFProperties).
                var connect: io_connect_t = 0
                let open = IOServiceOpen(service, mach_task_self_, 0, &connect)
                guard open == kIOReturnSuccess else { throw BatteryThresholdError.setFailed(kr) }
                defer { IOServiceClose(connect) }
                kr = IOConnectSetCFProperties(connect, cfProps)
                guard kr == kIOReturnSuccess else { throw BatteryThresholdError.setFailed(kr) }
            }
        }

        /// Menulis threshold lewat dua jalur:
        /// 1. ThinkVPC / YogaSMC -> ACPI BCCS/BCSS -> SMI -> EC (jalur OEM).
        /// 2. Opsional: YogaSMCUserClient writeEC -> ACPI WE1B -> EC langsung.
        /// Jalur (2) hanya aktif kalau user mengaktifkan Direct EC dan mengisi
        /// offset EC yang sudah diverifikasi untuk tipenya.
        func apply(start: Int? = nil, stop: Int? = nil, enabled: Bool? = nil) throws {
            var s = start ?? self.start
            var t = stop ?? self.stop
            let e = enabled ?? self.isEnabled

            if start != nil { s = min(100, max(0, s)); defaults.set(s, forKey: startKey) }
            if stop != nil { t = min(100, max(0, t)); defaults.set(t, forKey: stopKey) }
            if enabled != nil { isEnabled = e }

            // YogaSMCPane resmi mengirim 0 untuk "stop 100%" (0 = penuh).
            let ysmcStop = t >= 100 ? 0 : t
            var props: [String: Any] = [batteryProperty: batteryIndex]
            if e {
                props["setCMstart"] = s
                props["setCMstop"] = ysmcStop
            } else {
                props["setCMstart"] = 0
                props["setCMstop"] = 0
                props["setCMInhibitCharge"] = 0
            }
            try send([[batteryProperty: batteryIndex], props])
            applyDirectEC(start: s, stop: t, enabled: e)
        }

        /// Tulis byte EC memakai method ACPI WE1B (SSDT-EC.aml) lewat user client.
        /// Read-back dipakai supaya tulisan benar-benar sampai ke EC, dan supaya
        /// byte yang sama tidak ditulis ulang tiap beberapa detik.
        private func applyDirectEC(start s: Int, stop t: Int, enabled e: Bool) {
            guard ecDirectEnabled else { return }
            guard let startOffset = ecStartOffset, let stopOffset = ecStopOffset else {
                if !ecDidLogFailure {
                    NSLog("[BatteryEC] Direct EC ON but Start/Stop offsets are unset — use 'Set EC Offsets…'")
                    ecDidLogFailure = true
                }
                return
            }

            let bridge = YogaSMCECBridge.shared
            let startByte = UInt8(e ? s : 0)
            let stopByte = UInt8(e ? (t >= 100 ? 0 : t) : 0)

            func writeIfNeeded(_ offset: UInt8, _ desired: UInt8, _ label: String) {
                do {
                    let before = try bridge.readByte(offset)
                    if before == desired { return }
                    try bridge.writeByte(offset, desired)
                    let after = try bridge.readByte(offset)
                    NSLog("[BatteryEC] WE1B %@ 0x%02X <- 0x%02X (was 0x%02X, readback 0x%02X)%@",
                          label, offset, desired, before, after,
                          after == desired ? "" : " [MISMATCH]")
                } catch {
                    if !ecDidLogFailure {
                        NSLog("[BatteryEC] direct EC %@ failed: %@", label, error.localizedDescription)
                        ecDidLogFailure = true
                    }
                }
            }

            writeIfNeeded(startOffset, startByte, "start")
            writeIfNeeded(stopOffset, stopByte, "stop")
            if e {
                if let inhibit = ecInhibitOffset { writeIfNeeded(inhibit, 0, "inhibit") }
            }
        }

        /// Debug saja: nama key internal tetap ada di log, tidak di menu.
        func logRawThresholds() {
            guard let service = try? copyService() else { return }
            defer { IOObjectRelease(service) }
            let raw = IORegistryEntryCreateCFProperty(service, "BAT_PRIMARY" as CFString, kCFAllocatorDefault, 0)
            if let dict = raw?.takeRetainedValue() as? NSDictionary {
                NSLog("[BatteryThreshold] debug raw BAT_PRIMARY: %@", dict.description)
            }
        }

        // MARK: Baterai (IORegistry, bukan BCTG/BCSG)

        private func boolProperty(_ key: String, _ service: io_registry_entry_t) -> Bool? {
            let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
            return raw?.takeRetainedValue() as? Bool
        }

        private func intProperty(_ key: String, _ service: io_registry_entry_t) -> Int? {
            let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
            return (raw?.takeRetainedValue() as? NSNumber)?.intValue
        }

        private func batteryName(_ service: io_registry_entry_t) -> String {
            // Naik beberapa level sampai ketemu nama device ACPI (BAT0 / BAT1).
            var current = service
            var ownsCurrent = false
            for _ in 0..<5 {
                var buffer = [CChar](repeating: 0, count: 128)
                if IORegistryEntryGetName(current, &buffer) == kIOReturnSuccess {
                    let name = String(cString: buffer)
                    if name.hasPrefix("BAT") {
                        if ownsCurrent { IOObjectRelease(current) }
                        return name
                    }
                }
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == kIOReturnSuccess,
                      parent != 0 else { break }
                if ownsCurrent { IOObjectRelease(current) }
                current = parent
                ownsCurrent = true
            }
            if ownsCurrent { IOObjectRelease(current) }
            return "BAT0"
        }

        private func readBattery(_ service: io_registry_entry_t) -> BatteryStatus? {
            guard boolProperty("BatteryInstalled", service) ?? false else { return nil }
            let current = intProperty("CurrentCapacity", service) ?? 0
            let capacity = intProperty("MaxCapacity", service) ?? 0
            let percent = capacity > 0
                ? min(100, max(0, Int(round(Double(current) / Double(capacity) * 100))))
                : 0

            let charging = boolProperty("IsCharging", service) ?? false
            let connected = boolProperty("ExternalConnected", service) ?? false
            let stateText: String
            if charging {
                stateText = NSLocalizedString("Lagi Ngisi ⚡", comment: "")
            } else if connected {
                stateText = NSLocalizedString("Colok, nggak ngisi 🔌", comment: "")
            } else {
                stateText = NSLocalizedString("Pakai Baterai 🔋", comment: "")
            }
            return BatteryStatus(name: batteryName(service), percent: percent, stateText: stateText)
        }

        /// Detail EC per baterai (BAT0, BAT1). Hanya dipakai untuk baris detail kecil —
        /// BUKAN untuk persen utama. Control threshold tetap memakai jalur EC/SMC ini.
        func ecBatteryDetails() -> [BatteryStatus] {
            let matching = IOServiceMatching("AppleSmartBattery")
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iterator) == kIOReturnSuccess else {
                return []
            }
            defer { IOObjectRelease(iterator) }

            var result: [BatteryStatus] = []
            var service = IOIteratorNext(iterator)
            while service != 0 {
                if let status = readBattery(service) { result.append(status) }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            return result.sorted { $0.name < $1.name }
        }
    }

    private func valueSubmenu(tagBase: Int, action: Selector) -> NSMenu {
        let menu = NSMenu()
        for value in stride(from: 0, through: 100, by: 5) {
            let choice = NSMenuItem(title: "\(value)%", action: action, keyEquivalent: "")
            choice.target = self
            choice.tag = tagBase + value
            menu.addItem(choice)
        }
        return menu
    }

    private func setupBatteryThresholdMenu() {
        // Menu utama bersih: About, Monitor Capslock, Launch on Login, Battery Threshold, Quit.
        for item in statusBarMenu.items where item.isSeparatorItem {
            statusBarMenu.removeItem(item)
        }

        let item = NSMenuItem(title: NSLocalizedString("Batas Ngecas", comment: ""), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        let batteryLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        let powerLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let ec0Line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let ec1Line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let summaryLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        let ecStatusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        batteryLine.isEnabled = false
        powerLine.isEnabled = false
        ec0Line.isEnabled = false
        ec1Line.isEnabled = false
        summaryLine.isEnabled = false
        ecStatusLine.isEnabled = false
        thresholdBatteryItem = batteryLine
        thresholdPowerItem = powerLine
        thresholdEC0Item = ec0Line
        thresholdEC1Item = ec1Line
        thresholdSummaryItem = summaryLine
        thresholdECStatusItem = ecStatusLine
        menu.addItem(batteryLine)
        menu.addItem(powerLine)
        menu.addItem(ec0Line)
        menu.addItem(ec1Line)
        menu.addItem(summaryLine)
        menu.addItem(ecStatusLine)
        menu.addItem(NSMenuItem.separator())

        let startItem = NSMenuItem(title: NSLocalizedString("Atur Mulai Ngecas Di", comment: ""), action: nil, keyEquivalent: "")
        startItem.submenu = valueSubmenu(tagBase: 1000, action: #selector(setStart(_:)))
        menu.addItem(startItem)
        thresholdStartItem = startItem

        let stopItem = NSMenuItem(title: NSLocalizedString("Atur Stop Ngecas Di", comment: ""), action: nil, keyEquivalent: "")
        stopItem.submenu = valueSubmenu(tagBase: 2000, action: #selector(setStop(_:)))
        menu.addItem(stopItem)
        thresholdStopItem = stopItem

        menu.addItem(NSMenuItem.separator())
        let enable = NSMenuItem(title: NSLocalizedString("Nyalain Batas", comment: ""), action: #selector(toggleThreshold(_:)), keyEquivalent: "")
        enable.target = self
        menu.addItem(enable)
        thresholdEnableItem = enable

        let refresh = NSMenuItem(title: NSLocalizedString("Refresh Batas", comment: ""), action: #selector(refreshThresholdMenu), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(NSMenuItem.separator())
        let directEC = NSMenuItem(title: NSLocalizedString("EC Langsung (ACPI WE1B)", comment: ""), action: #selector(toggleDirectEC(_:)), keyEquivalent: "")
        directEC.target = self
        menu.addItem(directEC)
        thresholdECDirectItem = directEC

        let ecOffsets = NSMenuItem(title: NSLocalizedString("Atur Offset EC…", comment: ""), action: #selector(setECOffsets(_:)), keyEquivalent: "")
        ecOffsets.target = self
        menu.addItem(ecOffsets)

        item.submenu = menu
        // Sebelum item terakhir (Quit).
        statusBarMenu.insertItem(item, at: max(0, statusBarMenu.items.count - 1))
        refreshThresholdMenu()
    }

    private func setCheckmarks(in menu: NSMenu?, base: Int, current: Int) {
        guard let menu = menu else { return }
        for choice in menu.items {
            choice.state = (choice.tag - base == current) ? .on : .off
        }
    }

    @objc private func refreshThresholdMenu() {
        let manager = BatteryThresholdManager.shared
        let power = MacOSBatteryReader.read()

        // Persen utama = IOPowerSources, sumber yang sama dengan ikon baterai macOS.
        statusBatteryView.update(percent: power?.percent ?? 0, state: power?.stateText ?? NSLocalizedString("Baterai nggak diketahui", comment: ""))

        if let power = power {
            thresholdBatteryItem?.title = String(
                format: NSLocalizedString("Baterai - %d%% - %@", comment: ""),
                power.percent, power.stateText
            )
            let remaining = power.timeRemainingMinutes.map { " / \($0) min" } ?? ""
            NSLog("[BatterySync] source IOPowerSources: %d/%d = %d%%%@ | %@",
                  power.current, power.max, power.percent, remaining, power.stateText)
        } else {
            thresholdBatteryItem?.title = NSLocalizedString("Baterai - Nggak diketahui", comment: "")
        }

        // Detail EC kecil di bawahnya — tidak pernah dipakai sebagai persen utama.
        let details = manager.ecBatteryDetails()
        applyECDetail(thresholdEC0Item, detail: details.indices.contains(0) ? details[0] : nil)
        applyECDetail(thresholdEC1Item, detail: details.indices.contains(1) ? details[1] : nil)

        thresholdSummaryItem?.title = String(
            format: NSLocalizedString("Batas: Mulai %d%% → Stop %d%%", comment: ""),
            manager.start, manager.stop
        )
        thresholdEnableItem?.state = manager.isEnabled ? .on : .off
        thresholdECDirectItem?.state = manager.ecDirectEnabled ? .on : .off
        setCheckmarks(in: thresholdStartItem?.submenu, base: 1000, current: manager.start)
        setCheckmarks(in: thresholdStopItem?.submenu, base: 2000, current: manager.stop)

        let ecStatus: String
        if manager.ecDirectEnabled {
            let s = manager.ecStartOffset.map { String(format: "0x%02X", $0) } ?? "—"
            let p = manager.ecStopOffset.map { String(format: "0x%02X", $0) } ?? "—"
            let i = manager.ecInhibitOffset.map { String(format: "0x%02X", $0) } ?? "—"
            ecStatus = String(format: NSLocalizedString("EC langsung: NYALA · S %@ · P %@ · I %@", comment: ""), s, p, i)
        } else {
            ecStatus = NSLocalizedString("EC langsung: MATI (cuma BCCS/BCSS)", comment: "")
        }
        thresholdECStatusItem?.attributedTitle = NSAttributedString(string: ecStatus, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.systemGreen
        ])

        refreshPowerMenu()

        // Debug saja — tidak pernah tampil di UI.
        manager.logRawThresholds()
        verifyDisplaySync(macOSPercent: power?.percent)
    }

    /// Baris daya masuk baterai. Hilang total kalau charger nggak nyolok
    /// atau data arus/tegangan nggak tersedia.
    private func refreshPowerMenu() {
        let power = LivePowerReader.read()

        // Teks di samping ikon di menu bar.
        // Saat colok: 12.5V · 22.5W · 5.21A · CPU 34% · RAM 58% · 52°C
        // Tanpa colok: CPU 34% · RAM 58% · 52°C
        // Warna standar menu bar (labelColor) mengikuti tema light/dark.
        let stats = SystemStatsReader.shared
        let cpu = stats.cpuUsage().map { "🧠 \($0)%" } ?? "🧠 —"
        let ram = stats.ramUsage().map { "💾 \($0)%" } ?? "💾 —"
        let temp = stats.cpuTemperature().map { "🌡️ \($0)°C" } ?? "🌡️ —°C"

        var parts: [String] = []
        if let power = power, power.acConnected {
            let volts = Double(power.voltageMV) / 1000
            let watts = power.stoppedWhilePlugged ? 0 : power.watts
            let amps = power.stoppedWhilePlugged ? 0 : power.amps
            parts.append(String(
                format: "⚡ %.1fV · 🔌 %.1fW · 🔋 %.2fA",
                locale: Locale(identifier: "en_US_POSIX"), // titik, bukan koma
                volts, watts, amps
            ))
        }
        parts += [cpu, ram, temp]

        statusItem.button?.attributedTitle = NSAttributedString(
            string: parts.joined(separator: "    "),
            attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        guard let item = thresholdPowerItem else { return }
        guard let power = power, power.acConnected else {
            item.attributedTitle = NSAttributedString(string: "")
            item.isHidden = true
            return
        }

        let stopped = power.stoppedWhilePlugged
        let watts = stopped ? 0 : power.watts
        let amps = stopped ? 0 : power.amps
        let status = stopped
            ? NSLocalizedString("Stop, nggak ngisi (threshold jalan)", comment: "")
            : NSLocalizedString("Lagi ngisi", comment: "")
        let format = NSLocalizedString("Daya: %.1f W · %.2f A — %@", comment: "")
        let text = String(
            format: format,
            locale: Locale(identifier: "en_US_POSIX"), // titik, bukan koma
            watts, amps, status
        )

        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.systemGreen
        ])
        item.isHidden = false
    }

    private func applyECDetail(_ item: NSMenuItem?, detail: BatteryStatus?) {
        guard let item = item else { return }
        let text: String
        if let detail = detail {
            text = String(
                format: NSLocalizedString("%@ - %d%% - Detail EC", comment: ""),
                detail.name, detail.percent
            )
        } else {
            text = ""
        }
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.systemGreen
        ])
        item.isHidden = (detail == nil)
    }

    // MARK: - Battery sync monitoring (IOPowerSources)

    private func startBatteryMonitoring() {
        refreshThresholdMenu()

        batteryRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshThresholdMenu()
        }
        if let timer = batteryRefreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // Daya/arus di-refresh lebih cepat dari menu biasa supaya terasa live.
        powerRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPowerMenu()
        }
        if let timer = powerRefreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        // "Realtime": tulis ulang threshold secara berkala. BCCS/BCSS dipanggil
        // lagi lewat ThinkVPC, dan kalau Direct EC aktif byte EC dibaca/ditulis
        // ulang hanya kalau nilainya berubah (lihat applyDirectEC).
        ecReapplyTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reapplyThresholdQuietly()
        }
        if let timer = ecReapplyTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePowerSourceChange),
            name: .powerSourceDidChange,
            object: nil
        )

        // Observer bawaan IOKit: langsung dibangkitkan saat charger dicabut/dicolok.
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .powerSourceDidChange, object: nil)
            }
        }, nil)?.takeRetainedValue()
        powerSourceRunLoopSource = source
        if let source = source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    @objc private func handlePowerSourceChange() {
        refreshThresholdMenu()
        // Bug cabut-colok bablas: tulis ulang threshold EC setelah EC sempat settle.
        pendingForceApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.forceApplyThreshold()
        }
        pendingForceApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func forceApplyThreshold() {
        reapplyThresholdQuietly()
        refreshThresholdMenu()
    }

    /// Dipanggil timer 3 detik, observer charger, dan perubahan menu.
    /// Semua akses IOKit/EC di serial queue supaya tidak ada write bersamaan.
    private func reapplyThresholdQuietly() {
        thresholdQueue.async {
            do {
                try BatteryThresholdManager.shared.apply()
            } catch {
                NSLog("[BatterySync] reapply threshold failed: %@", error.localizedDescription)
            }
        }
    }

    private func displayedPercentFromTitle(_ title: String?) -> Int? {
        guard let title = title else { return nil }
        let parts = title.components(separatedBy: " - ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1].replacingOccurrences(of: "%", with: ""))
    }

    /// Console debug: bandingkan angka sumber macOS dengan angka yang benar-benar tampil.
    private func verifyDisplaySync(macOSPercent: Int?) {
        guard let macOSPercent = macOSPercent else { return }
        let displayPercent = displayedPercentFromTitle(thresholdBatteryItem?.title)
        lastDisplayedPercent = displayPercent
        let match = displayPercent == macOSPercent
        let line = String(
            format: "macOS Percent: %d%% | App Display: %@%% | Match: %@",
            macOSPercent,
            displayPercent.map(String.init) ?? "?",
            match ? "YES" : "NO"
        )
        print("[BatterySync] " + line)
        NSLog("[BatterySync] %@", line)

        if match {
            batteryMismatchSince = nil
            return
        }
        let now = Date()
        if batteryMismatchSince == nil {
            batteryMismatchSince = now
        } else if now.timeIntervalSince(batteryMismatchSince!) >= 10 {
            NSLog("[BatterySync] WARNING: app display tidak sinkron dengan ikon macOS selama >10 detik (%@)", line)
            batteryMismatchSince = now
        }
    }

    deinit {
        batteryRefreshTimer?.invalidate()
        powerRefreshTimer?.invalidate()
        ecReapplyTimer?.invalidate()
        pendingForceApply?.cancel()
        YogaSMCECBridge.shared.closeConnection()
        NotificationCenter.default.removeObserver(self)
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    @objc private func setStart(_ sender: NSMenuItem) {
        applyThreshold(start: sender.tag - 1000)
    }

    @objc private func setStop(_ sender: NSMenuItem) {
        applyThreshold(stop: sender.tag - 2000)
    }

    @objc private func toggleThreshold(_ sender: NSMenuItem) {
        applyThreshold(enabled: !BatteryThresholdManager.shared.isEnabled)
    }

    @objc private func toggleDirectEC(_ sender: NSMenuItem) {
        let manager = BatteryThresholdManager.shared
        manager.ecDirectEnabled = !manager.ecDirectEnabled
        if manager.ecDirectEnabled && (manager.ecStartOffset == nil || manager.ecStopOffset == nil) {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("EC Langsung (ACPI WE1B)", comment: "")
            alert.informativeText = NSLocalizedString("EC Langsung nyala, tapi offset Start/Stop belum diisi. Isi dulu lewat 'Atur Offset EC…' pakai offset yang sudah kamu cek; kalau nggak, nggak ada byte yang ditulis ke EC.", comment: "")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("Oke", comment: ""))
            alert.runModal()
        }
        refreshThresholdMenu()
        reapplyThresholdQuietly()
    }

    @objc private func setECOffsets(_ sender: Any?) {
        let manager = BatteryThresholdManager.shared
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Offset EC (ACPI WE1B)", comment: "")
        alert.informativeText = NSLocalizedString("Offset RAM EC dalam hex (0x01–0x99). Kosongkan atau isi 0 buat hapus. Pakai cuma nilai yang sudah kamu cek di mesinmu — salah offset bisa ngubah perilaku fan/LED/sleep.", comment: "")
        alert.alertStyle = .informational

        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        let labels = ["Start:", "Stop:", "Inhibit:"]
        let current = [manager.ecStartOffset, manager.ecStopOffset, manager.ecInhibitOffset]
        var fields: [NSTextField] = []
        for (index, label) in labels.enumerated() {
            let text = NSTextField(labelWithString: label)
            text.frame = NSRect(x: 0, y: 66 - index * 28, width: 90, height: 20)
            text.alignment = .right
            panel.addSubview(text)

            let field = NSTextField(string: current[index].map { String(format: "0x%02X", $0) } ?? "")
            field.frame = NSRect(x: 100, y: 64 - index * 28, width: 200, height: 22)
            field.placeholderString = "0x00"
            panel.addSubview(field)
            fields.append(field)
        }
        alert.accessoryView = panel
        alert.addButton(withTitle: NSLocalizedString("Oke", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Batal", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        func parse(_ field: NSTextField) -> UInt8? {
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let hex = raw.hasPrefix("0x") || raw.hasPrefix("0X")
                ? String(raw.dropFirst(2)) : raw
            guard !hex.isEmpty, let value = Int(hex, radix: 16), (1...0x99).contains(value) else {
                return nil
            }
            return UInt8(value)
        }

        manager.setECOffsets(start: parse(fields[0]), stop: parse(fields[1]), inhibit: parse(fields[2]))
        refreshThresholdMenu()
        reapplyThresholdQuietly()
    }

    private func applyThreshold(start: Int? = nil, stop: Int? = nil, enabled: Bool? = nil) {
        do {
            try BatteryThresholdManager.shared.apply(start: start, stop: stop, enabled: enabled)
            refreshThresholdMenu()
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Batas Ngecas", comment: "")
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Oke", comment: ""))
            alert.runModal()
        }
    }

    // MARK: - Sparkle auto-update
    //
    // Kode lama yang menanyakan api.github.com dan membuka browser sudah dihapus total.
    // Sparkle membaca SUFeedURL / SUPublicEDKey dari Info.plist dan menangani
    // jaringan yang mati tanpa crash (alert error standar Sparkle).
    @MainActor
    private func setupUpdateMenu() {
        let checkItem = NSMenuItem(
            title: NSLocalizedString("Cek Update...", comment: ""),
            action: #selector(checkForUpdatesPressed(_:)),
            keyEquivalent: ""
        )
        checkItem.target = self
        statusBarMenu.insertItem(checkItem, at: max(0, statusBarMenu.items.count - 1))

        let automaticItem = NSMenuItem(
            title: NSLocalizedString("Cek Update Otomatis", comment: ""),
            action: #selector(toggleAutomaticChecks(_:)),
            keyEquivalent: ""
        )
        automaticItem.target = self
        automaticItem.state = updaterController.updater.automaticallyChecksForUpdates ? .on : .off
        statusBarMenu.insertItem(automaticItem, at: max(0, statusBarMenu.items.count - 1))
    }

    @objc @MainActor
    private func checkForUpdatesPressed(_ sender: Any?) {
        updaterController.checkForUpdates(nil)
    }

    @objc @MainActor
    private func toggleAutomaticChecks(_ sender: NSMenuItem) {
        let enabled = !updaterController.updater.automaticallyChecksForUpdates
        updaterController.updater.automaticallyChecksForUpdates = enabled
        sender.state = enabled ? .on : .off
    }

    // MARK: - Panel pengaturan & About (UI baru)

    @MainActor @objc private func openSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            let controller = SettingsViewController()
            controller.delegate = self

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("Pengaturan", comment: "")
            window.contentViewController = controller
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        (settingsWindowController?.contentViewController as? SettingsViewController)?.reload()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAbout(_ sender: Any?) {
        if aboutWindowController == nil {
            let controller = AboutViewController()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("Tentang Thinkpad Assistant", comment: "")
            window.contentViewController = controller
            window.center()
            window.isReleasedWhenClosed = false
            aboutWindowController = NSWindowController(window: window)
        }
        aboutWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func checkForUpdatesFromAbout() {
        Task { @MainActor in
            updaterController.checkForUpdates(nil)
        }
    }

    @IBAction func quitPressed(_ sender: Any) {
        NSApp.terminate(self)
    }

}

// MARK: - SettingsDelegate

extension AppDelegate: SettingsDelegate {

    var chargeStart: Int { BatteryThresholdManager.shared.start }
    var chargeStop: Int { BatteryThresholdManager.shared.stop }
    var thresholdEnabled: Bool { BatteryThresholdManager.shared.isEnabled }
    var ecDirectEnabled: Bool { BatteryThresholdManager.shared.ecDirectEnabled }
    var ecStartOffset: UInt8? { BatteryThresholdManager.shared.ecStartOffset }
    var ecStopOffset: UInt8? { BatteryThresholdManager.shared.ecStopOffset }
    var ecInhibitOffset: UInt8? { BatteryThresholdManager.shared.ecInhibitOffset }
    var capsLockMonitoring: Bool { CapslockMonitor.isActive }
    var launchAtLogin: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == helperBundleName
        }
    }
    @MainActor var automaticUpdates: Bool { updaterController.updater.automaticallyChecksForUpdates }

    func settingsSetChargeStart(_ value: Int) {
        applyThreshold(start: value)
    }

    func settingsSetChargeStop(_ value: Int) {
        applyThreshold(stop: value)
    }

    func settingsSetThresholdEnabled(_ enabled: Bool) {
        applyThreshold(enabled: enabled)
    }

    func settingsSetECDirectEnabled(_ enabled: Bool) {
        let manager = BatteryThresholdManager.shared
        manager.ecDirectEnabled = enabled
        if enabled && (manager.ecStartOffset == nil || manager.ecStopOffset == nil) {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("EC Langsung (ACPI WE1B)", comment: "")
            alert.informativeText = NSLocalizedString("EC Langsung nyala, tapi offset Start/Stop belum diisi. Isi dulu offset di tab Baterai pakai offset yang sudah kamu cek.", comment: "")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("Oke", comment: ""))
            alert.runModal()
        }
        refreshThresholdMenu()
        reapplyThresholdQuietly()
    }

    func settingsSetECOffsets(start: UInt8?, stop: UInt8?, inhibit: UInt8?) {
        BatteryThresholdManager.shared.setECOffsets(start: start, stop: stop, inhibit: inhibit)
        refreshThresholdMenu()
        reapplyThresholdQuietly()
    }

    func settingsSetCapsLockMonitoring(_ enabled: Bool) {
        if enabled {
            CapslockMonitor.start()
        } else {
            CapslockMonitor.stop()
        }
        monitorCapslocksMenuItem?.state = enabled ? .on : .off
    }

    func settingsSetLaunchAtLogin(_ enabled: Bool) {
        SMLoginItemSetEnabled(helperBundleName as CFString, enabled)
        launchAtLoginMenuItem?.state = enabled ? .on : .off
    }

    @MainActor func settingsSetAutomaticUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    func settingsCheckForUpdates() {
        Task { @MainActor in
            updaterController.checkForUpdates(nil)
        }
    }

    func settingsRefreshBattery() {
        refreshThresholdMenu()
    }
}
