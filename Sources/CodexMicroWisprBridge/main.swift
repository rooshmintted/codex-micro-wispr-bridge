import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid

private enum Device {
    static let vendorID = 0x303A
    static let productID = 0x8360
    static let vendorReportID: UInt32 = 6
    static let micKeyIDs: Set<String> = ["ACT10", "ACT11", "ACT10_ACT11"]
}

private struct Configuration {
    var dryRun = false
    var verbose = false
    var requestPermissions = true
    var triggerOnce = false
    var checkPermissions = false
    var showHelp = false

    init(arguments: ArraySlice<String>) throws {
        for argument in arguments {
            switch argument {
            case "--dry-run":
                dryRun = true
            case "--verbose":
                verbose = true
            case "--no-permission-prompts":
                requestPermissions = false
            case "--trigger-once":
                triggerOnce = true
            case "--check-permissions":
                checkPermissions = true
            case "--help", "-h":
                showHelp = true
            default:
                throw BridgeError.invalidArgument(argument)
            }
        }
    }
}

private enum BridgeError: Error, CustomStringConvertible {
    case invalidArgument(String)

    var description: String {
        switch self {
        case let .invalidArgument(argument):
            return "Unknown argument: \(argument)"
        }
    }
}

private enum Log {
    static func info(_ message: String) {
        write("[bridge] \(message)")
    }

    static func error(_ message: String) {
        write("[bridge] error: \(message)")
    }

    private static func write(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private struct PermissionState {
    let canListenToHID: Bool
    let canPostKeyboardEvents: Bool

    var isReady: Bool {
        canListenToHID && canPostKeyboardEvents
    }

    static func evaluate(requestIfNeeded: Bool, needsPosting: Bool) -> PermissionState {
        var listenAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if listenAccess != kIOHIDAccessTypeGranted && requestIfNeeded {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            listenAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        }

        var canPost = true
        if needsPosting {
            canPost = CGPreflightPostEventAccess()
            if !canPost && requestIfNeeded {
                _ = CGRequestPostEventAccess()
                canPost = CGPreflightPostEventAccess()
            }
        }

        return PermissionState(
            canListenToHID: listenAccess == kIOHIDAccessTypeGranted,
            canPostKeyboardEvents: canPost
        )
    }

    func printSummary(needsPosting: Bool) {
        Log.info("Input Monitoring: \(canListenToHID ? "granted" : "not granted")")
        if needsPosting {
            Log.info("Accessibility: \(canPostKeyboardEvents ? "granted" : "not granted")")
        }

        if !canListenToHID {
            Log.error("Grant Input Monitoring to this executable in System Settings > Privacy & Security > Input Monitoring.")
        }
        if needsPosting && !canPostKeyboardEvents {
            Log.error("Grant Accessibility to this executable in System Settings > Privacy & Security > Accessibility.")
        }
    }
}

private final class WisprShortcutEmitter {
    private let dryRun: Bool

    init(dryRun: Bool) {
        self.dryRun = dryRun
    }

    func trigger() {
        if dryRun {
            Log.info("Dry run: would send Control+Option+Space.")
            return
        }

        guard CGPreflightPostEventAccess() else {
            Log.error("Accessibility permission is not granted; cannot send Control+Option+Space.")
            return
        }

        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)
        else {
            Log.error("Unable to create synthetic keyboard events.")
            return
        }

        let flags: CGEventFlags = [.maskControl, .maskAlternate]
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        usleep(12_000)
        keyUp.post(tap: .cghidEventTap)
        Log.info("Sent Control+Option+Space to toggle Wispr Flow hands-free mode.")
    }
}

private final class CodexMicroBridge {
    private let manager: IOHIDManager
    private let configuration: Configuration
    private let emitter: WisprShortcutEmitter
    private var receiveBuffer = Data()
    private var pressedMicKeys = Set<String>()
    private var lastMicEventTime: TimeInterval = 0
    private var lastTriggerTime: TimeInterval = 0
    private var connectedDeviceCount = 0

    init(configuration: Configuration) throws {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.configuration = configuration
        self.emitter = WisprShortcutEmitter(dryRun: configuration.dryRun)
    }

    func start() -> Bool {
        let permissions = PermissionState.evaluate(
            requestIfNeeded: configuration.requestPermissions,
            needsPosting: !configuration.dryRun
        )
        permissions.printSummary(needsPosting: !configuration.dryRun)

        guard permissions.canListenToHID else {
            return false
        }
        guard configuration.dryRun || permissions.canPostKeyboardEvents else {
            return false
        }

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Device.vendorID,
            kIOHIDProductIDKey as String: Device.productID
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, context)
        IOHIDManagerRegisterInputReportCallback(manager, inputReportCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            Log.error("Unable to open the Codex Micro HID interface (IOReturn \(result)).")
            return false
        }

        Log.info("Listening non-exclusively for Codex Micro Mic reports on Layer 1.")
        Log.info(configuration.dryRun ? "Dry-run mode is enabled." : "Wispr shortcut: Control+Option+Space.")
        return true
    }

    func deviceMatched(_ device: IOHIDDevice) {
        connectedDeviceCount += 1
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        Log.info("Connected to \(product ?? "Codex Micro") (\(connectedDeviceCount) matching interface(s)).")
    }

    func deviceRemoved(_ device: IOHIDDevice) {
        connectedDeviceCount = max(0, connectedDeviceCount - 1)
        pressedMicKeys.removeAll()
        receiveBuffer.removeAll(keepingCapacity: true)
        Log.info("Codex Micro disconnected; waiting for it to reconnect.")
    }

    func handleReport(result: IOReturn, reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard result == kIOReturnSuccess else {
            Log.error("HID report failed with IOReturn \(result).")
            return
        }
        guard reportID == Device.vendorReportID, length > 0 else {
            return
        }

        var bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
        if bytes.count == 64 && bytes.first == UInt8(Device.vendorReportID) {
            bytes.removeFirst()
        }

        guard bytes.count >= 2, bytes[0] == 2 else {
            if configuration.verbose {
                Log.info("Ignored report 6 with an unknown frame type.")
            }
            return
        }

        let payloadLength = Int(bytes[1])
        guard payloadLength <= 61, bytes.count >= payloadLength + 2 else {
            Log.error("Ignored a malformed report 6 frame.")
            receiveBuffer.removeAll(keepingCapacity: true)
            return
        }

        let fragment = Data(bytes[2..<(payloadLength + 2)])
        if
            !receiveBuffer.isEmpty,
            fragment.starts(with: Data("{\"method\"".utf8)) || fragment.starts(with: Data("{\"m\"".utf8))
        {
            receiveBuffer.removeAll(keepingCapacity: true)
        }
        receiveBuffer.append(fragment)

        if receiveBuffer.count > 65_536 {
            Log.error("Protocol receive buffer exceeded 64 KiB; resetting it.")
            receiveBuffer.removeAll(keepingCapacity: true)
            return
        }

        drainMessages()
    }

    private func drainMessages() {
        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            let message = receiveBuffer.prefix(upTo: newlineIndex)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newlineIndex)
            guard !message.isEmpty else {
                continue
            }
            handleMessage(Data(message))
        }
    }

    private func handleMessage(_ data: Data) {
        if configuration.verbose, let raw = String(data: data, encoding: .utf8) {
            Log.info("Protocol: \(raw)")
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            ((object["method"] as? String) ?? (object["m"] as? String)) == "v.oai.hid",
            let parameters = (object["params"] as? [String: Any]) ?? (object["p"] as? [String: Any]),
            let keyID = parameters["k"] as? String,
            Device.micKeyIDs.contains(keyID),
            let action = intValue(parameters["act"])
        else {
            return
        }

        handleMicEvent(keyID: keyID, action: action)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let integer = value as? Int {
            return integer
        }
        return nil
    }

    private func handleMicEvent(keyID: String, action: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMicEventTime > 1.5 {
            pressedMicKeys.removeAll()
        }
        lastMicEventTime = now

        switch action {
        case 1:
            let wasIdle = pressedMicKeys.isEmpty
            pressedMicKeys.insert(keyID)

            guard wasIdle, now - lastTriggerTime > 0.25 else {
                return
            }
            lastTriggerTime = now
            Log.info("Mic pressed (\(keyID)).")
            emitter.trigger()
        case 0:
            pressedMicKeys.remove(keyID)
            if configuration.verbose {
                Log.info("Mic released (\(keyID)).")
            }
        default:
            if configuration.verbose {
                Log.info("Ignored Mic action \(action) for \(keyID).")
            }
        }
    }
}

private let deviceMatchedCallback: IOHIDDeviceCallback = { context, result, _, device in
    guard
        result == kIOReturnSuccess,
        let context
    else {
        return
    }
    Unmanaged<CodexMicroBridge>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
}

private let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else {
        return
    }
    Unmanaged<CodexMicroBridge>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
}

private let inputReportCallback: IOHIDReportCallback = { context, result, _, _, reportID, report, reportLength in
    guard let context else {
        return
    }
    Unmanaged<CodexMicroBridge>.fromOpaque(context).takeUnretainedValue().handleReport(
        result: result,
        reportID: reportID,
        report: report,
        length: reportLength
    )
}

private let usage = """
Usage: codex-micro-wispr-bridge [options]

Options:
  --dry-run                Decode Mic reports without sending a shortcut.
  --verbose                Log every decoded vendor-protocol message.
  --trigger-once           Send Control+Option+Space once, then exit.
  --check-permissions      Request and print required macOS permissions, then exit.
  --no-permission-prompts  Do not ask macOS to open permission settings.
  -h, --help               Show this help.
"""

do {
    let configuration = try Configuration(arguments: CommandLine.arguments.dropFirst())

    if configuration.showHelp {
        print(usage)
        exit(EXIT_SUCCESS)
    }

    if configuration.checkPermissions {
        let permissions = PermissionState.evaluate(requestIfNeeded: true, needsPosting: true)
        permissions.printSummary(needsPosting: true)
        exit(permissions.isReady ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    if configuration.triggerOnce {
        let permissions = PermissionState.evaluate(
            requestIfNeeded: configuration.requestPermissions,
            needsPosting: true
        )
        permissions.printSummary(needsPosting: true)
        guard permissions.canPostKeyboardEvents else {
            exit(EXIT_FAILURE)
        }
        WisprShortcutEmitter(dryRun: configuration.dryRun).trigger()
        exit(EXIT_SUCCESS)
    }

    let bridge = try CodexMicroBridge(configuration: configuration)
    guard bridge.start() else {
        exit(EXIT_FAILURE)
    }
    CFRunLoopRun()
} catch {
    Log.error(String(describing: error))
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(EXIT_FAILURE)
}
