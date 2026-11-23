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
    
    let statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
    
    let helperBundleName = "de.mszturc.AutoLaunchHelper"

    // Battery threshold (YogaSMC ThinkVPC) — lihat SUMMARY.md bagian 4 dan 9.
    private weak var thresholdBatteryItem: NSMenuItem?
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
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var batteryMismatchSince: Date?
    private var lastDisplayedPercent: Int?
    private var pendingForceApply: DispatchWorkItem?
    private var ecReapplyTimer: Timer?
    private let thresholdQueue = DispatchQueue(label: "BatteryThreshold.ECReapply", qos: .utility)

    @IBOutlet weak var statusBarMenu: NSMenu!
    
    @IBOutlet weak var monitorCapslocksMenuItem: NSMenuItem!
    @IBOutlet weak var launchAtLoginMenuItem: NSMenuItem!
    
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
        
        let foundHelper = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == helperBundleName
        }
        
        launchAtLoginMenuItem.state = foundHelper ? .on : .off

        monitorCapslocksMenuItem.state = CapslockMonitor.isActive ? .on : .off

        setupBatteryThresholdMenu()
        startBatteryMonitoring()
        setupUpdateMenu()
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
                return NSLocalizedString("ThinkVPC (YogaSMC) service not found. Make sure YogaSMC 1.5.3 is loaded.", comment: "")
            case .setFailed(let kr):
                return String(format: NSLocalizedString("Could not write threshold (0x%08X). Administrator rights may be required.", comment: ""), kr)
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
                return NSLocalizedString("ThinkVPC (YogaSMC) service not found.", comment: "")
            case .openFailed(let kr):
                return String(format: NSLocalizedString("Could not open YogaSMC user client (0x%08X).", comment: ""), kr)
            case .callFailed(let name, let kr):
                return String(format: NSLocalizedString("YogaSMC %@ failed (0x%08X).", comment: ""), name, kr)
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
                    stateText = NSLocalizedString("Charging", comment: "")
                } else if state == kIOPSACPowerValue {
                    stateText = NSLocalizedString("Not Charging", comment: "")
                } else {
                    stateText = NSLocalizedString("Discharging", comment: "")
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
                stateText = NSLocalizedString("Charging ⚡", comment: "")
            } else if connected {
                stateText = NSLocalizedString("Not Charging 🔌", comment: "")
            } else {
                stateText = NSLocalizedString("Discharging 🔋", comment: "")
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

        let item = NSMenuItem(title: NSLocalizedString("Battery Threshold", comment: ""), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        let batteryLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        let ec0Line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let ec1Line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let summaryLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        let ecStatusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        batteryLine.isEnabled = false
        ec0Line.isEnabled = false
        ec1Line.isEnabled = false
        summaryLine.isEnabled = false
        ecStatusLine.isEnabled = false
        thresholdBatteryItem = batteryLine
        thresholdEC0Item = ec0Line
        thresholdEC1Item = ec1Line
        thresholdSummaryItem = summaryLine
        thresholdECStatusItem = ecStatusLine
        menu.addItem(batteryLine)
        menu.addItem(ec0Line)
        menu.addItem(ec1Line)
        menu.addItem(summaryLine)
        menu.addItem(ecStatusLine)
        menu.addItem(NSMenuItem.separator())

        let startItem = NSMenuItem(title: NSLocalizedString("Set Start Charge At", comment: ""), action: nil, keyEquivalent: "")
        startItem.submenu = valueSubmenu(tagBase: 1000, action: #selector(setStart(_:)))
        menu.addItem(startItem)
        thresholdStartItem = startItem

        let stopItem = NSMenuItem(title: NSLocalizedString("Set Stop Charge At", comment: ""), action: nil, keyEquivalent: "")
        stopItem.submenu = valueSubmenu(tagBase: 2000, action: #selector(setStop(_:)))
        menu.addItem(stopItem)
        thresholdStopItem = stopItem

        menu.addItem(NSMenuItem.separator())
        let enable = NSMenuItem(title: NSLocalizedString("Enable Threshold", comment: ""), action: #selector(toggleThreshold(_:)), keyEquivalent: "")
        enable.target = self
        menu.addItem(enable)
        thresholdEnableItem = enable

        let refresh = NSMenuItem(title: NSLocalizedString("Refresh Threshold", comment: ""), action: #selector(refreshThresholdMenu), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(NSMenuItem.separator())
        let directEC = NSMenuItem(title: NSLocalizedString("Direct EC (ACPI WE1B)", comment: ""), action: #selector(toggleDirectEC(_:)), keyEquivalent: "")
        directEC.target = self
        menu.addItem(directEC)
        thresholdECDirectItem = directEC

        let ecOffsets = NSMenuItem(title: NSLocalizedString("Set EC Offsets…", comment: ""), action: #selector(setECOffsets(_:)), keyEquivalent: "")
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
        if let power = power {
            thresholdBatteryItem?.title = String(
                format: NSLocalizedString("Battery - %d%% - %@", comment: ""),
                power.percent, power.stateText
            )
            let remaining = power.timeRemainingMinutes.map { " / \($0) min" } ?? ""
            NSLog("[BatterySync] source IOPowerSources: %d/%d = %d%%%@ | %@",
                  power.current, power.max, power.percent, remaining, power.stateText)
        } else {
            thresholdBatteryItem?.title = NSLocalizedString("Battery - Unknown", comment: "")
        }

        // Detail EC kecil di bawahnya — tidak pernah dipakai sebagai persen utama.
        let details = manager.ecBatteryDetails()
        applyECDetail(thresholdEC0Item, detail: details.indices.contains(0) ? details[0] : nil)
        applyECDetail(thresholdEC1Item, detail: details.indices.contains(1) ? details[1] : nil)

        thresholdSummaryItem?.title = String(
            format: NSLocalizedString("Threshold: Start %d%% → Stop %d%%", comment: ""),
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
            ecStatus = String(format: NSLocalizedString("EC direct: ON · S %@ · P %@ · I %@", comment: ""), s, p, i)
        } else {
            ecStatus = NSLocalizedString("EC direct: OFF (ACPI BCCS/BCSS only)", comment: "")
        }
        thresholdECStatusItem?.attributedTitle = NSAttributedString(string: ecStatus, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ])

        // Debug saja — tidak pernah tampil di UI.
        manager.logRawThresholds()
        verifyDisplaySync(macOSPercent: power?.percent)
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
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
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
            alert.messageText = NSLocalizedString("Direct EC (ACPI WE1B)", comment: "")
            alert.informativeText = NSLocalizedString("Direct EC is ON, but Start/Stop EC offsets are not set. Use 'Set EC Offsets…' with offsets verified for your machine; otherwise no byte will be written to EC.", comment: "")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
        }
        refreshThresholdMenu()
        reapplyThresholdQuietly()
    }

    @objc private func setECOffsets(_ sender: Any?) {
        let manager = BatteryThresholdManager.shared
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("EC Offsets (ACPI WE1B)", comment: "")
        alert.informativeText = NSLocalizedString("Hex EC RAM offsets (0x01–0x99). Leave empty or set 0 to clear. Only use values verified for your laptop model — a wrong offset can change unrelated EC behaviour.", comment: "")
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
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
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
            alert.messageText = NSLocalizedString("Battery Threshold", comment: "")
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
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
            title: NSLocalizedString("Check for Updates...", comment: ""),
            action: #selector(checkForUpdatesPressed(_:)),
            keyEquivalent: ""
        )
        checkItem.target = self
        statusBarMenu.insertItem(checkItem, at: max(0, statusBarMenu.items.count - 1))

        let automaticItem = NSMenuItem(
            title: NSLocalizedString("Automatically Check for Updates", comment: ""),
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

    @IBAction func quitPressed(_ sender: Any) {
        NSApp.terminate(self)
    }
    
}

