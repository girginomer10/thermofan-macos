import Foundation
import FanSafetyPolicy
import IOKit
import Darwin

private let kSMCKernelIndex: UInt32 = 2
private let kSMCReadBytes: UInt8 = 5
private let kSMCGetKeyFromIndex: UInt8 = 8
private let kSMCReadKeyInfo: UInt8 = 9
/// `kSMCKeyNotFound`: the only SMC result that proves a key does not exist.
private let kSMCKeyNotFound: UInt8 = 0x84

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var padding0: UInt8 = 0
    var padding1: UInt8 = 0
    var padding2: UInt8 = 0
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

struct SMCReading {
    var key: String
    var type: String
    var value: Double
}

struct SMCRawReading {
    var key: String
    var type: String
    var bytes: [UInt8]
}

enum SMCError: Error, LocalizedError, CustomStringConvertible {
    case serviceUnavailable
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcResult(UInt8)
    case unknownType(String)
    case malformedData(type: String, byteCount: Int)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "Apple SMC service is unavailable."
        case .openFailed(let code):
            return "Could not open Apple SMC: \(Self.kernMessage(code))."
        case .callFailed(let code):
            return "SMC call failed: \(Self.kernMessage(code))."
        case .smcResult(let result):
            return "SMC returned error 0x\(String(result, radix: 16))."
        case .unknownType(let type):
            return "Unsupported SMC data type '\(type)'."
        case .malformedData(let type, let byteCount):
            return "SMC returned \(byteCount) byte\(byteCount == 1 ? "" : "s") that do not decode as '\(type)'."
        }
    }

    var description: String {
        errorDescription ?? "SMC error"
    }

    private static func kernMessage(_ code: kern_return_t) -> String {
        let hexCode = "0x\(String(UInt32(bitPattern: code), radix: 16))"
        if let message = mach_error_string(code) {
            return "\(String(cString: message)) (\(hexCode))"
        }
        return "kern_return_t \(hexCode)"
    }
}

/// Read-only AppleSMC client for the app process. It deliberately has no
/// write entry point: every fan write goes through the privileged daemon.
final class SMCClient: @unchecked Sendable {
    private var connection: io_connect_t = 0
    // Key metadata (size/type) is immutable within a wake cycle, so cache it
    // to avoid a second kernel round-trip on every read. Only keys the SMC
    // reports as nonexistent (`kSMCKeyNotFound`) are cached as missing; a busy,
    // timed-out, or otherwise failed lookup is retried on the next read.
    private var infoCache: [UInt32: SMCKeyInfo] = [:]
    private var missingKeys: Set<UInt32> = []
    private let cacheLock = NSLock()

    static var keyDataSize: Int {
        MemoryLayout<SMCKeyData>.stride
    }

    init() throws {
        let service = SMCClient.matchingService()
        guard service != 0 else {
            throw SMCError.serviceUnavailable
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, thermofan_current_task_port(), 0, &connection)
        guard result == KERN_SUCCESS else {
            throw SMCError.openFailed(result)
        }

    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func readNumber(key: String) throws -> SMCReading {
        let raw = try readRaw(key: key)
        let value = try Self.decode(bytes: raw.bytes, type: raw.type)
        return SMCReading(key: key, type: raw.type, value: value)
    }

    func readRaw(key: String) throws -> SMCRawReading {
        let rawKey = Self.keyCode(key)
        let info = try readInfo(key: rawKey)
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = rawKey
        input.keyInfo = info
        input.data8 = kSMCReadBytes
        try call(selector: kSMCKernelIndex, input: &input, output: &output)
        try Self.checkSMCResult(output.result)

        let bytes = Self.array(from: output.bytes, count: Int(info.dataSize))
        let type = Self.string(fromKeyCode: info.dataType)
        return SMCRawReading(key: key, type: type, bytes: bytes)
    }

    func key(at index: Int) throws -> String {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.data8 = kSMCGetKeyFromIndex
        input.data32 = UInt32(max(0, index))
        try call(selector: kSMCKernelIndex, input: &input, output: &output)
        try Self.checkSMCResult(output.result)
        return Self.string(fromKeyCode: output.key)
    }

    /// SMC key availability can change across sleep/wake on Apple Silicon.
    /// Metadata remains immutable within a wake cycle, but negative entries
    /// must not survive into the next one.
    func resetCacheAfterWake() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        infoCache.removeAll(keepingCapacity: true)
        missingKeys.removeAll(keepingCapacity: true)
    }

    private func readInfo(key: UInt32) throws -> SMCKeyInfo {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = infoCache[key] {
            return cached
        }
        if missingKeys.contains(key) {
            throw SMCError.smcResult(kSMCKeyNotFound)
        }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = key
        input.data8 = kSMCReadKeyInfo
        // A transport failure throws here without touching either cache.
        try call(selector: kSMCKernelIndex, input: &input, output: &output)
        if output.result == kSMCKeyNotFound {
            missingKeys.insert(key)
        }
        try Self.checkSMCResult(output.result)
        infoCache[key] = output.keyInfo
        return output.keyInfo
    }

    private func call(selector: UInt32, input: inout SMCKeyData, output: inout SMCKeyData) throws {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    selector,
                    inputPointer,
                    inputSize,
                    outputPointer,
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw SMCError.callFailed(result)
        }
    }

    private static func matchingService() -> io_service_t {
        let names = ["AppleSMC", "AppleSMCKeysEndpoint"]
        for name in names {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            if service != 0 {
                return service
            }
        }
        return 0
    }

    private static func keyCode(_ key: String) -> UInt32 {
        var bytes = Array(key.utf8.prefix(4))
        while bytes.count < 4 {
            bytes.append(32)
        }
        return bytes.reduce(UInt32(0)) { result, byte in
            (result << 8) | UInt32(byte)
        }
    }

    private static func checkSMCResult(_ result: UInt8) throws {
        guard result == 0 else {
            throw SMCError.smcResult(result)
        }
    }

    private static func string(fromKeyCode code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ].filter { $0 != 0 && $0 != 32 }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func array(from tuple: SMCBytes, count: Int) -> [UInt8] {
        withUnsafeBytes(of: tuple) { rawBuffer in
            Array(rawBuffer.prefix(max(0, min(count, rawBuffer.count))))
        }
    }

    /// Decodes an SMC payload by its declared data type. A payload that is too
    /// short for its type, or a float that is implausible in both byte orders,
    /// throws instead of decoding as 0: a synthesized 0 would read as a
    /// confirmed fanless `FNum` or as Auto for a fan-mode key.
    static func decode(bytes: [UInt8], type: String) throws -> Double {
        func require(_ count: Int) throws {
            guard bytes.count >= count else {
                throw SMCError.malformedData(type: type, byteCount: bytes.count)
            }
        }

        switch type {
        case "sp78":
            try require(1)
            let integer = Int8(bitPattern: bytes[0])
            let fraction = bytes.count > 1 ? Double(bytes[1]) / 256 : 0
            return Double(integer) + fraction
        case "fpe2":
            try require(2)
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw) / 4
        case "flt", "flt ":
            try require(4)
            let bigEndian = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            let littleEndian = UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
            let bigFloat = Float32(bitPattern: bigEndian)
            let littleFloat = Float32(bitPattern: littleEndian)
            if littleFloat.isFinite, bigFloat.isFinite {
                let littleMagnitude = abs(littleFloat)
                let bigMagnitude = abs(bigFloat)
                if littleMagnitude < 1e-20, bigMagnitude >= 1e-6, bigMagnitude < 200_000 {
                    return Double(bigFloat)
                }
                if bigMagnitude < 1e-20, littleMagnitude >= 1e-6, littleMagnitude < 200_000 {
                    return Double(littleFloat)
                }
            }
            if littleFloat.isFinite, abs(littleFloat) < 200_000 {
                return Double(littleFloat)
            }
            if bigFloat.isFinite, abs(bigFloat) < 200_000 {
                return Double(bigFloat)
            }
            throw SMCError.malformedData(type: type, byteCount: bytes.count)
        case "ui8", "ui8 ":
            try require(1)
            return Double(bytes[0])
        case "ui16":
            try require(2)
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            try require(4)
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "si16":
            try require(2)
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw))
        default:
            throw SMCError.unknownType(type)
        }
    }
}
