import Foundation

func collectSnapshot() throws -> DeviceSnapshot {
    DeviceSnapshot(
        audioDevices: try collectAudioDevices(),
        usbDevices: try collectScarlettUSBDevices(),
        usbInterfaces: try collectScarlettUSBInterfaces(),
        defaultInputDeviceName: readDefaultDeviceName(selector: coreAudioSelector("dIn ")),
        defaultOutputDeviceName: readDefaultDeviceName(selector: coreAudioSelector("dOut"))
    )
}

func printTextReport(_ snapshot: DeviceSnapshot) {
    if snapshot.audioDevices.isEmpty {
        print("CoreAudio reports no audio devices.")
    }

    for (index, device) in snapshot.audioDevices.enumerated() {
        let inputChannels = device.inputChannels.map(String.init) ?? "Unavailable"
        let outputChannels = device.outputChannels.map(String.init) ?? "Unavailable"
        let sampleRate = device.sampleRateHz.map { String(format: "%.0f Hz", $0) } ?? "Unavailable"

        print("[\(index + 1)] \(device.name)")
        print("    Manufacturer: \(device.manufacturer)")
        print("    Transport: \(device.transport ?? "Unavailable")")
        print("    Input channels: \(inputChannels)")
        print("    Output channels: \(outputChannels)")
        print("    Nominal sample rate: \(sampleRate)")

        if device.name.localizedCaseInsensitiveContains("Scarlett") {
            let inputVolume = device.inputVolumeScalar
                .map { String(format: "%.3f", $0) } ?? "not exposed"
            let outputVolume = device.outputVolumeScalar
                .map { String(format: "%.3f", $0) } ?? "not exposed"
            print("    CoreAudio volume scalar: input \(inputVolume), output \(outputVolume)")
        }
    }

    print("USB registry matches:")
    if snapshot.usbDevices.isEmpty {
        print("    No Focusrite/Scarlett USB host device found.")
    }
    for device in snapshot.usbDevices {
        print("    Product: \(device.productName)")
        print("    Manufacturer: \(device.manufacturer)")
        if let vendorID = device.vendorID, let productID = device.productID {
            print(String(format: "    VID: 0x%04X | PID: 0x%04X", vendorID, productID))
        } else {
            print("    VID/PID: unavailable")
        }
    }

    print("Scarlett USB interfaces:")
    if snapshot.usbInterfaces.isEmpty {
        print("    No Focusrite/Scarlett USB interfaces found.")
    }
    for interface in snapshot.usbInterfaces {
        guard let number = interface.number,
              let classCode = interface.classCode,
              let subclass = interface.subclass,
              let protocolCode = interface.protocolCode,
              let kind = interface.kind else {
            print("    Interface descriptor incomplete")
            continue
        }
        print(String(
            format: "    Interface %u: %@ (class 0x%02X, subclass 0x%02X, protocol 0x%02X)",
            number,
            kind,
            classCode,
            subclass,
            protocolCode
        ))
    }
}

do {
    if let optionIndex = CommandLine.arguments.firstIndex(of: "--read-monitor-input-gains") {
        guard CommandLine.arguments.indices.contains(optionIndex + 1),
              let channel = Int(CommandLine.arguments[optionIndex + 1]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --read-monitor-input-gains <1-8>")
        }
        let rawGains = try readMonitorInputMixGains(channel: channel)
        let dbGains = rawGains.map { Int(Int16(bitPattern: $0)) >> 8 }
        let output: [String: Any] = [
            "channel": channel,
            "rawGains": rawGains.map(Int.init),
            "gainDb": dbGains,
            "muted": rawGains.allSatisfy { $0 == 0x8000 }
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--read-monitor-mix-gain") {
        guard CommandLine.arguments.indices.contains(optionIndex + 2),
              let mix = Int(CommandLine.arguments[optionIndex + 1]),
              let channel = Int(CommandLine.arguments[optionIndex + 2]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --read-monitor-mix-gain <1-8> <1-18>")
        }
        let value = try readMonitorMixChannelGain(mix: mix, channel: channel)
        let output: [String: Any] = [
            "mix": mix,
            "channel": channel,
            "mixerChannel": (channel - 1) * 8 + mix - 1,
            "raw": Int(value.raw),
            "gainDb": value.db
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--read-monitor-mix-range") {
        guard CommandLine.arguments.indices.contains(optionIndex + 2),
              let mix = Int(CommandLine.arguments[optionIndex + 1]),
              let channel = Int(CommandLine.arguments[optionIndex + 2]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --read-monitor-mix-range <1-8> <1-18>")
        }
        let response = try readMonitorMixGainRange(mix: mix, channel: channel)
        let output: [String: Any] = [
            "mix": mix,
            "channel": channel,
            "rangeBytes": response.map(Int.init),
            "rangeCount": response.count >= 2 ? Int(response[0]) | (Int(response[1]) << 8) : 0
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--measure-input") {
        guard CommandLine.arguments.indices.contains(optionIndex + 1),
              let channel = Int(CommandLine.arguments[optionIndex + 1]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --measure-input <1-18>")
        }
        let snapshot = try measureInputSignal(channel: channel)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if CommandLine.arguments.contains("--measure-all-inputs") {
        let readings = try measureAllInputSignals()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(readings), as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--stream-input-meters") {
        guard CommandLine.arguments.indices.contains(optionIndex + 1) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --stream-input-meters <comma-separated channels>")
        }
        let channelArguments = CommandLine.arguments[optionIndex + 1].split(separator: ",")
        let channels = channelArguments.compactMap { Int($0) }
        guard !channelArguments.isEmpty, channels.count == channelArguments.count else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Input channels must be comma-separated integers")
        }
        try streamInputSignals(channels: channels)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--stream-input-meter") {
        guard CommandLine.arguments.indices.contains(optionIndex + 1),
              let channel = Int(CommandLine.arguments[optionIndex + 1]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --stream-input-meter <1-18>")
        }
        try streamInputSignal(channel: channel)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--read-input-gain") {
        guard CommandLine.arguments.indices.contains(optionIndex + 1),
              let channel = Int(CommandLine.arguments[optionIndex + 1]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --read-input-gain <1-8>")
        }
        let value = try readInputGain(channel: channel)
        let output: [String: Int] = ["channel": channel, "value": Int(value)]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--read-input-mode") {
        guard CommandLine.arguments.indices.contains(optionIndex + 1),
              let channel = Int(CommandLine.arguments[optionIndex + 1]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --read-input-mode <1-2>")
        }
        let mode = try readInputMode(channel: channel)
        let output: [String: Any] = ["channel": channel, "mode": mode]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--read-input-pad") {
        guard CommandLine.arguments.indices.contains(optionIndex + 1),
              let channel = Int(CommandLine.arguments[optionIndex + 1]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --read-input-pad <1-4>")
        }
        let enabled = try readInputPad(channel: channel)
        let output: [String: Any] = ["channel": channel, "pad": enabled]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--set-input-pad") {
        guard CommandLine.arguments.indices.contains(optionIndex + 2),
              let channel = Int(CommandLine.arguments[optionIndex + 1]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --set-input-pad <1-4> <on|off>")
        }
        let value = CommandLine.arguments[optionIndex + 2].lowercased()
        guard value == "on" || value == "off" else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "PAD state must be 'on' or 'off'")
        }
        let enabled = try setInputPad(channel: channel, enabled: value == "on")
        let output: [String: Any] = ["channel": channel, "pad": enabled, "verified": true]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--set-input-mode") {
        guard CommandLine.arguments.indices.contains(optionIndex + 2),
              let channel = Int(CommandLine.arguments[optionIndex + 1]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --set-input-mode <1-2> <line|inst>")
        }
        let mode = try setInputMode(channel: channel, mode: CommandLine.arguments[optionIndex + 2])
        let output: [String: Any] = ["channel": channel, "mode": mode, "verified": true]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--set-default-output") {
        guard CommandLine.arguments.indices.contains(optionIndex + 1),
              let deviceID = UInt32(CommandLine.arguments[optionIndex + 1]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --set-default-output <CoreAudio device ID>")
        }
        let name = try setDefaultOutputDevice(deviceID: deviceID)
        let output: [String: Any] = ["deviceID": deviceID, "name": name, "verified": true]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--set-default-input") {
        guard CommandLine.arguments.indices.contains(optionIndex + 1),
              let deviceID = UInt32(CommandLine.arguments[optionIndex + 1]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --set-default-input <CoreAudio device ID>")
        }
        let name = try setDefaultInputDevice(deviceID: deviceID)
        let output: [String: Any] = ["deviceID": deviceID, "name": name, "verified": true]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--set-scarlett-sample-rate") {
        guard CommandLine.arguments.indices.contains(optionIndex + 2),
              let deviceID = UInt32(CommandLine.arguments[optionIndex + 1]),
              let sampleRateHz = Double(CommandLine.arguments[optionIndex + 2]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --set-scarlett-sample-rate <device ID> <Hz>")
        }
        let actualRate = try setScarlettSampleRate(deviceID: deviceID, sampleRateHz: sampleRateHz)
        let output: [String: Any] = [
            "deviceID": deviceID,
            "sampleRateHz": actualRate,
            "verified": true
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    if let optionIndex = CommandLine.arguments.firstIndex(of: "--set-scarlett-clock-source") {
        guard CommandLine.arguments.indices.contains(optionIndex + 2),
              let deviceID = UInt32(CommandLine.arguments[optionIndex + 1]),
              let sourceID = UInt32(CommandLine.arguments[optionIndex + 2]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Usage: --set-scarlett-clock-source <device ID> <source ID>")
        }
        let name = try setScarlettClockSource(deviceID: deviceID, sourceID: sourceID)
        let output: [String: Any] = [
            "deviceID": deviceID,
            "sourceID": sourceID,
            "name": name,
            "verified": true
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(EXIT_SUCCESS)
    }

    let snapshot = try collectSnapshot()
    if CommandLine.arguments.contains("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        print(String(decoding: data, as: UTF8.self))
    } else {
        printTextReport(snapshot)
    }
} catch {
    fputs("CoreAudio probe failed: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}