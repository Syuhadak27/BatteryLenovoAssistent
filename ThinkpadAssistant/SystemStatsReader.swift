//
//  SystemStatsReader.swift
//  ThinkpadAssistant
//
//  Dikelola oleh Syuhadak27. https://github.com/Syuhadak27/ThinkpadAssistent
//
//  Pembaca CPU%, RAM%, dan suhu CPU rata-rata. Logika diadaptasi dari
//  project Stats (Serhiy Mytrovtsiy) — Samples/Modules/{CPU,RAM}/readers.swift.
//

import Foundation
import Cocoa

final class SystemStatsReader {

    static let shared = SystemStatsReader()

    private let host = mach_host_self()
    private var previousCPUTicks = host_cpu_load_info()
    private var hasPreviousCPU = false
    private var totalMemory: Double = 0

    private init() {
        var stats = host_basic_info()
        var count = UInt32(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_info(host, HOST_BASIC_INFO, $0, &count)
            }
        }
        totalMemory = result == kIOReturnSuccess ? Double(stats.max_mem) : 0
    }

    // MARK: - CPU usage (%)

    func cpuUsage() -> Int? {
        let count = MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(count)
        var info = host_cpu_load_info()
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: count) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == kIOReturnSuccess else { return nil }

        // Sample pertama dibuang supaya tidak menampilkan 100% palsu.
        guard hasPreviousCPU else {
            previousCPUTicks = info
            hasPreviousCPU = true
            return nil
        }

        let user = Double(info.cpu_ticks.0 &- previousCPUTicks.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- previousCPUTicks.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- previousCPUTicks.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- previousCPUTicks.cpu_ticks.3)
        let total = user + system + idle + nice
        previousCPUTicks = info
        guard total > 0 else { return nil }

        // Sama seperti Stats: totalUsage = user + system (nice tidak dihitung sebagai pemakaian).
        let usage = (user + system) / total
        guard !usage.isNaN else { return nil }
        return min(100, max(0, Int(round(usage * 100))))
    }

    // MARK: - RAM usage (%)

    func ramUsage() -> Int? {
        guard totalMemory > 0 else { return nil }
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == kIOReturnSuccess else { return nil }

        let page = Double(vm_page_size)
        let active = Double(stats.active_count) * page
        let speculative = Double(stats.speculative_count) * page
        let inactive = Double(stats.inactive_count) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        let purgeable = Double(stats.purgeable_count) * page
        let external = Double(stats.external_page_count) * page

        let used = active + inactive + speculative + wired + compressed - purgeable - external
        let usage = used / totalMemory
        guard !usage.isNaN else { return nil }
        return min(100, max(0, Int(round(usage * 100))))
    }

    // MARK: - Average CPU temperature (°C)

    func cpuTemperature() -> Int? {
        let smc = SMCReader.shared
        let intelKeys = ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H"]
        for key in intelKeys {
            if let value = smc.getValue(key), value < 110 {
                return Int(round(value))
            }
        }

        // Apple Silicon: rata-rata sensor suhu yang tersedia.
        var appleKeys: [String] = [
            "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
            "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j",
            "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
            "Te09", "Te0H", "Tp0V", "Tp0Y", "Tp0e",
        ]
        #if arch(arm64)
        appleKeys += ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0a", "Tp0d", "Tp0g", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        #endif

        var total = 0.0
        var count = 0
        for key in appleKeys {
            if let value = smc.getValue(key), value >= 10, value <= 120 {
                total += value
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return Int(round(total / Double(count)))
    }
}
