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
        case "--fanctl":
            exit(runFanControl(arguments: Array(arguments.dropFirst())))
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
            print("  \(fan.id)  \(fan.name): current \(fan.currentRPM) RPM, target \(fan.targetRPM) RPM, range \(fan.minRPM)-\(fan.maxRPM)")
        }
        if realFans.isEmpty {
            print("  none")
        }

        if !snapshot.warnings.isEmpty {
            print("Warnings:")
            snapshot.warnings.forEach { print("  \($0)") }
        }

        print("Raw SMC key reads:")
        runRawReads()
        print("Interesting SMC keys:")
        runKeyEnumeration()
    }

    private static func runRawReads() {
        let keys = [
            "#KEY", "FNum", "FS! ", "F0Ac", "F0Mn", "F0Mx", "F0Tg", "F0Md", "F0St", "F0Dc", "F0CR",
            "F0TE", "F0S0", "F0S1", "F0S2", "F0S3", "F0S4", "F0S5", "F0S6", "F0S7",
            "spf0", "RPF0", "SFF0", "SEF0", "SEf0", "maF0", "mxF0", "rtF0", "of00", "oF00", "isF0",
            "F1Ac", "F1Mn", "F1Mx", "F1Tg",
            "TA0P", "TC0P", "TC0E", "TC0D", "TC1C", "TC2C", "Tp09", "Tp01",
            "TG0P", "TG0D", "Tg05", "Tp0P", "TW0P", "TB0T", "TS0P"
        ]

        do {
            let smc = try SMCClient()
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
                   reading.value.isFinite,
                   reading.value >= 10,
                   reading.value < 130 {
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

    private static func runFanControl(arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else {
            writeError("Usage: ThermoFan --fanctl <fan-index> <automatic|fixed|curve> [rpm]")
            return 64
        }

        guard let fanIndex = Int(arguments[0]) else {
            writeError("Invalid fan index '\(arguments[0])'.")
            return 64
        }

        guard let mode = parseMode(arguments[1]) else {
            writeError("Invalid fan mode '\(arguments[1])'.")
            return 64
        }

        let rpm: Int?
        if mode == .automatic {
            rpm = nil
        } else {
            guard arguments.count >= 3, let parsedRPM = Int(arguments[2]) else {
                writeError("RPM is required for \(mode.rawValue) mode.")
                return 64
            }
            rpm = parsedRPM
        }

        do {
            let message = try FanControlService().applyDirect(fanIndex: fanIndex, mode: mode, rpm: rpm)
            print(message)
            return 0
        } catch {
            writeError(describe(error))
            return 1
        }
    }

    private static func parseMode(_ value: String) -> FanMode? {
        switch value.lowercased() {
        case "auto", "automatic":
            return .automatic
        case "fixed":
            return .fixed
        case "curve":
            return .curve
        default:
            return nil
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static func writeError(_ message: String) {
        let data = Data((message + "\n").utf8)
        FileHandle.standardError.write(data)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
