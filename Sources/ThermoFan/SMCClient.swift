import Foundation
import IOKit
import Darwin

private let kSMCKernelIndex: UInt32 = 2
private let kSMCReadBytes: UInt8 = 5
private let kSMCWriteBytes: UInt8 = 6
private let kSMCGetKeyFromIndex: UInt8 = 8
private let kSMCReadKeyInfo: UInt8 = 9

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
        }
    }

    var description: String {
        errorDescription ?? "SMC error"
    }

    private static func kernMessage(_ code: kern_return_t) -> String {
        if let message = mach_error_string(code) {
            return String(cString: message)
        }
        return "kern_return_t \(code)"
    }
}

final class SMCClient: @unchecked Sendable {
    private var connection: io_connect_t = 0
    // Key metadata (size/type) is immutable per boot, so cache it to avoid a
    // second kernel round-trip on every read/write. Nonexistent keys are cached
    // as failures so absent keys are skipped cheaply on later ticks.
    private var infoCache: [UInt32: SMCKeyInfo] = [:]
    private var missingKeys: Set<UInt32> = []

    static var keyDataSize: Int {
        MemoryLayout<SMCKeyData>.stride
    }

    init() throws {
        let service = SMCClient.matchingService()
        guard service != 0 else {
            throw SMCError.serviceUnavailable
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
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

    func writeNumber(key: String, value: Double) throws {
        let rawKey = Self.keyCode(key)
        let info = try readInfo(key: rawKey)
        let type = Self.string(fromKeyCode: info.dataType)
        let encoded = try Self.encode(value: value, type: type, count: Int(info.dataSize))

        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = rawKey
        input.keyInfo = info
        input.data8 = kSMCWriteBytes
        Self.copy(encoded, into: &input.bytes)
        try call(selector: kSMCKernelIndex, input: &input, output: &output)
        try Self.checkSMCResult(output.result)
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

    private func readInfo(key: UInt32) throws -> SMCKeyInfo {
        if let cached = infoCache[key] {
            return cached
        }
        if missingKeys.contains(key) {
            throw SMCError.smcResult(0x84)
        }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = key
        input.data8 = kSMCReadKeyInfo
        try call(selector: kSMCKernelIndex, input: &input, output: &output)
        do {
            try Self.checkSMCResult(output.result)
        } catch {
            missingKeys.insert(key)
            throw error
        }
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

    private static func copy(_ bytes: [UInt8], into tuple: inout SMCBytes) {
        withUnsafeMutableBytes(of: &tuple) { rawBuffer in
            for index in rawBuffer.indices {
                rawBuffer[index] = 0
            }
            for index in 0..<min(bytes.count, rawBuffer.count) {
                rawBuffer[index] = bytes[index]
            }
        }
    }

    private static func decode(bytes: [UInt8], type: String) throws -> Double {
        guard !bytes.isEmpty else { return 0 }

        switch type {
        case "sp78":
            let integer = Int8(bitPattern: bytes[0])
            let fraction = bytes.count > 1 ? Double(bytes[1]) / 256 : 0
            return Double(integer) + fraction
        case "fpe2":
            guard bytes.count >= 2 else { return 0 }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(raw) / 4
        case "flt", "flt ":
            guard bytes.count >= 4 else { return 0 }
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
            return 0
        case "ui8", "ui8 ":
            return Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return 0 }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return 0 }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "si16":
            guard bytes.count >= 2 else { return 0 }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            return Double(Int16(bitPattern: raw))
        default:
            throw SMCError.unknownType(type)
        }
    }

    private static func encode(value: Double, type: String, count: Int) throws -> [UInt8] {
        switch type {
        case "fpe2":
            let raw = UInt16(max(0, min(65535, Int(value * 4))))
            return [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        case "ui8", "ui8 ":
            return [UInt8(max(0, min(255, Int(value))))]
        case "ui16":
            let raw = UInt16(max(0, min(65535, Int(value))))
            return [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        case "ui32":
            let raw = UInt32(max(0, Int(value)))
            return [
                UInt8((raw >> 24) & 0xff),
                UInt8((raw >> 16) & 0xff),
                UInt8((raw >> 8) & 0xff),
                UInt8(raw & 0xff)
            ]
        case "flt", "flt ":
            let raw = Float32(value).bitPattern
            return [
                UInt8(raw & 0xff),
                UInt8((raw >> 8) & 0xff),
                UInt8((raw >> 16) & 0xff),
                UInt8((raw >> 24) & 0xff)
            ]
        default:
            if count == 2 {
                let raw = UInt16(max(0, min(65535, Int(value))))
                return [UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
            }
            throw SMCError.unknownType(type)
        }
    }
}
