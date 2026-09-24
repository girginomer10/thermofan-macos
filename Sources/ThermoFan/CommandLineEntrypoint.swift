import Darwin
import Foundation

enum CommandLineEntrypoint {
    static func runIfNeeded() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { return }

        switch command {
        case "--diagnose":
            runDiagnostics()
            exit(0)
        default:
            return
        }
    }

    private static func runDiagnostics() {
        var preferences = AppPreferences.defaults
        preferences.showEstimatedReadings = false

        let probe = HardwareProbe()
        let snapshot = probe.sample(preferences: preferences)
        let realSensors = snapshot.sensors.filter { $0.source != .estimated }
        let smcSensors = snapshot.sensors.filter { $0.source == .smc }
        let systemSensors = snapshot.sensors.filter { $0.source == .system }
        let realFans = snapshot.fans.filter { $0.source != .estimated }

        print("ThermoFan diagnostics")
        print("Machine: \(snapshot.machine.modelIdentifier) / \(snapshot.machine.chipName) / \(snapshot.machine.osVersion)")
        print("macOS build: \(HardwareProbe.sysctlString("kern.osversion") ?? "unknown")")
        print("SMC open: \(probe.isSMCAvailable ? "yes" : "no")")
        print("SMC key data size: \(SMCClient.keyDataSize)")
        print("Real temperature sensors: \(realSensors.count) (\(smcSensors.count) SMC, \(systemSensors.count) system)")
        for sensor in realSensors.sorted(by: { $0.name < $1.name }) {
            print("  \(sensor.source.label.padding(toLength: 6, withPad: " ", startingAt: 0)) \(sensor.id)  \(sensor.name): \(String(format: "%.1f", sensor.temperatureC)) C")
        }
        if realSensors.isEmpty {
            print("  none")
        }

        print("Real fans: \(realFans.count)")
        for fan in realFans {
            let rawTarget = fan.hardwareTargetRPM.map { "\($0) RPM" } ?? "unreadable"
            print("  \(fan.id)  \(fan.name): current \(fan.currentRPM) RPM, hardware mode \(hardwareModeLabel(fan.hardwareMode)), raw target \(rawTarget), staged target \(fan.targetRPM) RPM, range \(fan.minRPM)-\(fan.maxRPM), \(fan.controlInterface.diagnosticLabel)")
        }
        if realFans.isEmpty {
            print("  none")
        }

        if !snapshot.warnings.isEmpty {
            print("Warnings:")
            snapshot.warnings.forEach { print("  \($0)") }
        }

        print("Raw SMC key reads:")
        runRawReads(discoveredFanIndexes: realFans.compactMap { Int($0.id.dropFirst("fan".count)) })
        print("Interesting SMC keys:")
        runKeyEnumeration()
    }

    private static func hardwareModeLabel(_ mode: FanMode?) -> String {
        switch mode {
        case .automatic?: "auto"
        case .fixed?: "manual"
        case .curve?: "curve"
        case nil: "unknown"
        }
    }

    private static func runRawReads(discoveredFanIndexes: [Int]) {
        do {
            let smc = try SMCClient()
            // Every fan index the SMC reports or the probe exposed, plus 0 and
            // 1 so a missing or zero FNum still shows what those keys hold.
            let reportedFanCount = SMCNumericPolicy.fanCount(try? smc.readNumber(key: "FNum").value) ?? 0
            let fanIndexes = Set(0..<max(reportedFanCount, 2))
                .union(discoveredFanIndexes)
                .filter { (0..<SMCNumericPolicy.maximumFanCount).contains($0) }
                .sorted()
            let fanKeys = fanIndexes.flatMap { index in
                ["Ac", "Mn", "Mx", "Tg", "Md", "md"].map { "F\(index)\($0)" }
            }
            let keys: [String] = ["#KEY", "FNum", "FS! ", "Ftst"]
                + fanKeys
                + [
                    "F0St", "F0Dc", "F0CR", "F0TE", "F0S0", "F0S1", "F0S2", "F0S3", "F0S4", "F0S5", "F0S6", "F0S7",
                    "spf0", "RPF0", "SFF0", "SEF0", "SEf0", "maF0", "mxF0", "rtF0", "of00", "oF00", "isF0",
                    "TA0P", "TC0P", "TC0E", "TC0D", "TC1C", "TC2C", "Tp09", "Tp01",
                    "TG0P", "TG0D", "Tg05", "Tp0P", "TW0P", "TB0T", "TS0P"
                ]

            for key in keys {
                do {
                    let raw = try smc.readRaw(key: key)
                    if let reading = try? smc.readNumber(key: key) {
                        print("  \(key.padding(toLength: 4, withPad: " ", startingAt: 0))  \(reading.type.padding(toLength: 4, withPad: " ", startingAt: 0))  \(String(format: "%.2f", reading.value))  [\(hex(raw.bytes))]")
                    } else {
                        print("  \(key.padding(toLength: 4, withPad: " ", startingAt: 0))  \(raw.type.padding(toLength: 4, withPad: " ", startingAt: 0))  raw  [\(hex(raw.bytes))]")
                    }
                } catch {
                    print("  \(key.padding(toLength: 4, withPad: " ", startingAt: 0))  error  \(describe(error))")
                }
            }
        } catch {
            print("  SMC open failed: \(describe(error))")
        }
    }

    private static func runKeyEnumeration() {
        do {
            let smc = try SMCClient()
            let count = Int((try? smc.readNumber(key: "#KEY").value) ?? 0)
            guard count > 0 else {
                print("  unavailable")
                return
            }

            var fanKeys: [String] = []
            var temperatureReadings: [SMCReading] = []
            for index in 0..<min(count, 20_000) {
                guard let key = try? smc.key(at: index) else { continue }
                if isInterestingSMCKey(key) {
                    fanKeys.append(key)
                }
                if key.hasPrefix("T"),
                   let reading = try? smc.readNumber(key: key),
                   TemperaturePlausibility.isPlausible(reading.value) {
                    temperatureReadings.append(reading)
                }
            }

            if fanKeys.isEmpty {
                print("  none")
            } else {
                for key in fanKeys.sorted().prefix(160) {
                    print("  \(key)")
                }
            }

            print("Plausible SMC temperature keys:")
            if temperatureReadings.isEmpty {
                print("  none")
            } else {
                for reading in temperatureReadings.sorted(by: { $0.key < $1.key }) {
                    print("  \(reading.key)  \(reading.type.padding(toLength: 4, withPad: " ", startingAt: 0))  \(String(format: "%.2f", reading.value)) C")
                }
            }
        } catch {
            print("  error  \(describe(error))")
        }
    }

    private static func isInterestingSMCKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return key.hasPrefix("F")
            || key == "FS!"
            || lower.hasPrefix("spf")
            || lower.hasPrefix("pwm")
            || lower.contains("fan")
            || lower.contains("rpm")
            || lower.contains("f0")
            || lower.contains("f1")
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
