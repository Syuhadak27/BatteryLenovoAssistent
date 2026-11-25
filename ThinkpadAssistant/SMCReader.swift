//
//  SMCReader.swift
//  ThinkpadAssistant
//
//  Dikelola oleh Syuhadak27. https://github.com/Syuhadak27/ThinkpadAssistent
//
//  Pembaca SMC minimal (hanya getValue) — diadaptasi dari project Stats
//  (Serhiy Mytrovtsiy, © 2021), file Samples/SMC/smc.swift.
//  Tidak memerlukan root / SMJobBless, hanya IOKit AppleSMC read.
//

import Foundation
import IOKit

private enum SMCDataType: String {
    case UI8 = "ui8 "
    case UI16 = "ui16"
    case UI32 = "ui32"
    case SP1E = "sp1e"
    case SP3C = "sp3c"
    case SP4B = "sp4b"
    case SP5A = "sp5a"
    case SPA5 = "spa5"
    case SP69 = "sp69"
    case SP78 = "sp78"
    case SP87 = "sp87"
    case SP96 = "sp96"
    case SPB4 = "spb4"
    case SPF0 = "spf0"
    case FLT = "flt "
    case FPE2 = "fpe2"
}

private enum SMCKeys: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case readKeyInfo = 9
}

private struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)

    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0))
}

private struct SMCVal_t {
    var key: String
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: [UInt8] = Array(repeating: 0, count: 32)

    init(_ key: String) { self.key = key }
}

private extension FourCharCode {
    init(fromString str: String) {
        precondition(str.count == 4)
        self = str.utf8.reduce(0) { sum, character in sum << 8 | UInt32(character) }
    }

    func toString() -> String {
        String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
        String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
        String(describing: UnicodeScalar(self >> 8 & 0xff)!) +
        String(describing: UnicodeScalar(self & 0xff)!)
    }
}

private extension UInt16 {
    init(bytes: (UInt8, UInt8)) {
        self = UInt16(bytes.0) << 8 | UInt16(bytes.1)
    }
}

private extension UInt32 {
    init(bytes: (UInt8, UInt8, UInt8, UInt8)) {
        self = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
    }
}

private extension Int {
    init(fromFPE2 bytes: (UInt8, UInt8)) {
        self = (Int(bytes.0) << 6) + (Int(bytes.1) >> 2)
    }
}

private extension Float {
    init?(_ bytes: [UInt8]) {
        self = bytes.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Self.self) }
    }
}

final class SMCReader {
    static let shared = SMCReader()

    private var conn: io_connect_t = 0
    private let keyInfoLock = NSLock()
    private var keyInfoCache: [UInt32: SMCKeyData_t.keyInfo_t] = [:]

    private init() {
        var iterator: io_iterator_t = 0
        let matchingDictionary: CFMutableDictionary = IOServiceMatching("AppleSMC")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        guard result == kIOReturnSuccess else { return }

        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return }

        let openResult = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        if openResult != kIOReturnSuccess { conn = 0 }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    /// Membaca nilai numerik dari key SMC (misalnya "TC0D" untuk suhu CPU).
    func getValue(_ key: String) -> Double? {
        guard conn != 0 else { return nil }
        var val = SMCVal_t(key)
        let result = read(&val)
        guard result == kIOReturnSuccess, val.dataSize > 0 else { return nil }
        guard val.bytes.contains(where: { $0 != 0 }) else { return nil }

        switch val.dataType {
        case SMCDataType.UI8.rawValue:
            return Double(val.bytes[0])
        case SMCDataType.UI16.rawValue:
            return Double(UInt16(bytes: (val.bytes[0], val.bytes[1])))
        case SMCDataType.UI32.rawValue:
            return Double(UInt32(bytes: (val.bytes[0], val.bytes[1], val.bytes[2], val.bytes[3])))
        case SMCDataType.SP1E.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 16384
        case SMCDataType.SP3C.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 4096
        case SMCDataType.SP4B.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 2048
        case SMCDataType.SP5A.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 1024
        case SMCDataType.SPA5.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 32
        case SMCDataType.SP69.rawValue:
            return Double(UInt16(val.bytes[0]) * 256 + UInt16(val.bytes[1])) / 512
        case SMCDataType.SP78.rawValue:
            return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 256
        case SMCDataType.SP87.rawValue:
            return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 128
        case SMCDataType.SP96.rawValue:
            return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 64
        case SMCDataType.SPB4.rawValue:
            return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1])) / 16
        case SMCDataType.SPF0.rawValue:
            return Double(Int(val.bytes[0]) * 256 + Int(val.bytes[1]))
        case SMCDataType.FLT.rawValue:
            guard let value = Float(val.bytes) else { return nil }
            return Double(value)
        case SMCDataType.FPE2.rawValue:
            return Double(Int(fromFPE2: (val.bytes[0], val.bytes[1])))
        default:
            return nil
        }
    }

    private func read(_ value: UnsafeMutablePointer<SMCVal_t>) -> kern_return_t {
        guard value.pointee.key.count == 4, value.pointee.key.utf8.count == 4 else { return kIOReturnBadArgument }
        keyInfoLock.lock()
        defer { keyInfoLock.unlock() }

        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = FourCharCode(fromString: value.pointee.key)

        let keyInfo: SMCKeyData_t.keyInfo_t
        var cacheable = true
        if let cached = keyInfoCache[input.key] {
            keyInfo = cached
        } else {
            input.data8 = SMCKeys.readKeyInfo.rawValue
            let result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
            guard result == kIOReturnSuccess else { return result }
            if output.result == 0x84 { return kIOReturnNotFound }
            if output.result != 0 { return kIOReturnError }
            keyInfo = output.keyInfo
            cacheable = keyInfo.dataSize > 0 && keyInfo.dataSize <= value.pointee.bytes.count && keyInfo.dataType != 0
        }

        value.pointee.dataSize = UInt32(keyInfo.dataSize)
        value.pointee.dataType = keyInfo.dataType.toString()
        input.keyInfo.dataSize = keyInfo.dataSize
        input.data8 = SMCKeys.readBytes.rawValue

        let result = call(SMCKeys.kernelIndex.rawValue, input: &input, output: &output)
        if result == kIOReturnSuccess && output.result == 0 && cacheable {
            keyInfoCache[input.key] = keyInfo
        }
        guard result == kIOReturnSuccess else { return result }
        if output.result == 0x84 { return kIOReturnNotFound }
        if output.result != 0 { return kIOReturnError }

        memcpy(&value.pointee.bytes, &output.bytes, min(Int(value.pointee.dataSize), value.pointee.bytes.count))
        return kIOReturnSuccess
    }

    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }
}
