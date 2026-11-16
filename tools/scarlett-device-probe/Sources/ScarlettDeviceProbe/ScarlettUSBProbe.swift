import CoreAudio
import Foundation
import IOKit
import IOKit.usb

func transportName(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
    if let name = String(bytes: bytes, encoding: .macOSRoman),
       name.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }) {
        return "\(name) (0x\(String(code, radix: 16)))"
    }
    return String(format: "0x%08X", code)
}

func registryProperty(_ service: io_service_t, key: String) -> Any? {
    guard let value = IORegistryEntryCreateCFProperty(
        service,
        key as CFString,
        kCFAllocatorDefault,
        0
    ) else {
        return nil
    }
    return value.takeRetainedValue()
}

func registryUInt32(_ service: io_service_t, key: String) -> UInt32? {
    (registryProperty(service, key: key) as? NSNumber)?.uint32Value
}

func usbUUID(_ bytes: [UInt8]) -> CFUUID? {
    guard bytes.count == 16 else { return nil }
    return CFUUIDGetConstantUUIDWithBytes(
        kCFAllocatorDefault,
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

func readUSBConfigurationDescriptor(service: io_service_t) throws -> Data {
    guard let deviceUserClientUUID = usbUUID([
        0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xd4,
        0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61
    ]), let pluginInterfaceUUID = usbUUID([
        0xc2, 0x44, 0xe8, 0x58, 0x10, 0x9c, 0x11, 0xd4,
        0x91, 0xd4, 0x00, 0x50, 0xe4, 0xc6, 0x42, 0x6f
    ]), let deviceInterfaceUUID = usbUUID([
        0x3c, 0x9e, 0xe1, 0xeb, 0x24, 0x02, 0x11, 0xb2,
        0x8e, 0x7e, 0x00, 0x0a, 0x27, 0x80, 0x1e, 0x86
    ]) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Create USB interface UUIDs")
    }

    var pluginOut: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    try check(
        IOCreatePlugInInterfaceForService(
            service,
            deviceUserClientUUID,
            pluginInterfaceUUID,
            &pluginOut,
            &score
        ),
        operation: "Create read-only USB descriptor interface"
    )
    guard let pluginOut, let pluginVTable = pluginOut.pointee else {
        throw ProbeError.coreAudio(kIOReturnNoDevice, "Create USB descriptor interface")
    }
    defer { _ = IODestroyPlugInInterface(pluginOut) }

    guard let queryInterface = pluginVTable.pointee.QueryInterface else {
        throw ProbeError.coreAudio(kIOReturnUnsupported, "Query USB device interface")
    }
    var rawDeviceInterface: UnsafeMutableRawPointer?
    try check(
        queryInterface(
            UnsafeMutableRawPointer(pluginOut),
            CFUUIDGetUUIDBytes(deviceInterfaceUUID),
            &rawDeviceInterface
        ),
        operation: "Query USB device interface"
    )
    guard let rawDeviceInterface else {
        throw ProbeError.coreAudio(kIOReturnNoDevice, "Query USB device interface")
    }
    let deviceInterface = rawDeviceInterface.assumingMemoryBound(
        to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self
    )
    guard let deviceVTable = deviceInterface.pointee else {
        throw ProbeError.coreAudio(kIOReturnNoDevice, "Query USB device interface")
    }
    defer {
        if let release = deviceVTable.pointee.Release {
            _ = release(UnsafeMutableRawPointer(deviceInterface))
        }
    }

    guard let getDescriptor = deviceVTable.pointee.GetConfigurationDescriptorPtr else {
        throw ProbeError.coreAudio(kIOReturnUnsupported, "Get USB configuration descriptor")
    }
    var descriptor: IOUSBConfigurationDescriptorPtr?
    try check(
        getDescriptor(rawDeviceInterface, 0, &descriptor),
        operation: "Read USB configuration descriptor"
    )
    guard let descriptor else {
        throw ProbeError.coreAudio(kIOReturnNoDevice, "Read USB configuration descriptor")
    }

    let byteCount = Int(UInt16(littleEndian: descriptor.pointee.wTotalLength))
    guard byteCount >= 9, byteCount <= 65_535 else {
        throw ProbeError.unexpectedDataSize(UInt32(byteCount), 65_535)
    }
    return Data(bytes: UnsafeRawPointer(descriptor), count: byteCount)
}

func parseFeatureUnits(_ descriptor: Data) -> [FeatureUnitSnapshot] {
    let bytes = [UInt8](descriptor)
    var features: [FeatureUnitSnapshot] = []
    var offset = 0

    while offset + 2 <= bytes.count {
        let length = Int(bytes[offset])
        guard length >= 2, offset + length <= bytes.count else { break }

        if length >= 7,
           bytes[offset + 1] == 0x24,
           bytes[offset + 2] == 0x06 {
            let unitID = bytes[offset + 3]
            let sourceID = bytes[offset + 4]
            let controlSize = bytes[offset + 5]
            if controlSize > 0 {
                let controlBytesLength = length - 7
                let controlCount = controlBytesLength / Int(controlSize)
                var volumeChannels: [Int] = []
                for entry in 0..<controlCount {
                    let firstControlByte = offset + 6 + entry * Int(controlSize)
                    if bytes[firstControlByte] & 0x02 != 0 {
                        volumeChannels.append(entry)
                    }
                }
                features.append(FeatureUnitSnapshot(
                    unitID: unitID,
                    sourceID: sourceID,
                    controlSize: controlSize,
                    volumeControlChannels: volumeChannels
                ))
            }
        }
        offset += length
    }
    return features
}

func sendScarlettControlRequest(
    channel: Int,
    selector: UInt8,
    requestType: UInt8,
    payload: [UInt8],
    allowedChannels: ClosedRange<Int>,
    entityID: UInt8 = 0x01,
    controlRequest: UInt8 = 0x01
) throws -> [UInt8] {
    guard allowedChannels.contains(channel) else {
        throw ProbeError.coreAudio(
            kIOReturnBadArgument,
            "Input channel must be between \(allowedChannels.lowerBound) and \(allowedChannels.upperBound)"
        )
    }
    var iterator: io_iterator_t = 0
    try check(
        IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOUSBHostDevice"),
            &iterator
        ),
        operation: "Find Scarlett USB device"
    )
    defer { IOObjectRelease(iterator) }

    while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else { break }
        defer { IOObjectRelease(service) }

        let productName = registryProperty(service, key: "USB Product Name") as? String ?? ""
        let vendorID = registryUInt32(service, key: "idVendor")
        let productID = registryUInt32(service, key: "idProduct")
        guard productName.localizedCaseInsensitiveContains("Scarlett"),
              vendorID == 0x1235,
              productID == 0x8014 else {
            continue
        }

        guard let deviceUserClientUUID = usbUUID([
            0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xd4,
            0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61
        ]), let pluginInterfaceUUID = usbUUID([
            0xc2, 0x44, 0xe8, 0x58, 0x10, 0x9c, 0x11, 0xd4,
            0x91, 0xd4, 0x00, 0x50, 0xe4, 0xc6, 0x42, 0x6f
        ]), let deviceInterfaceUUID = usbUUID([
            0x3c, 0x9e, 0xe1, 0xeb, 0x24, 0x02, 0x11, 0xb2,
            0x8e, 0x7e, 0x00, 0x0a, 0x27, 0x80, 0x1e, 0x86
        ]) else {
            throw ProbeError.coreAudio(kIOReturnBadArgument, "Create Scarlett USB interface UUIDs")
        }

        var pluginOut: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        try check(
            IOCreatePlugInInterfaceForService(
                service,
                deviceUserClientUUID,
                pluginInterfaceUUID,
                &pluginOut,
                &score
            ),
            operation: "Create Scarlett read-only gain interface"
        )
        guard let pluginOut, let pluginVTable = pluginOut.pointee else {
            throw ProbeError.coreAudio(kIOReturnNoDevice, "Create Scarlett gain interface")
        }
        defer { _ = IODestroyPlugInInterface(pluginOut) }

        guard let queryInterface = pluginVTable.pointee.QueryInterface else {
            throw ProbeError.coreAudio(kIOReturnUnsupported, "Query Scarlett gain interface")
        }
        var rawDeviceInterface: UnsafeMutableRawPointer?
        try check(
            queryInterface(
                UnsafeMutableRawPointer(pluginOut),
                CFUUIDGetUUIDBytes(deviceInterfaceUUID),
                &rawDeviceInterface
            ),
            operation: "Query Scarlett gain interface"
        )
        guard let rawDeviceInterface else {
            throw ProbeError.coreAudio(kIOReturnNoDevice, "Query Scarlett gain interface")
        }

        let deviceInterface = rawDeviceInterface.assumingMemoryBound(
            to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self
        )
        guard let deviceVTable = deviceInterface.pointee else {
            throw ProbeError.coreAudio(kIOReturnNoDevice, "Query Scarlett device interface")
        }
        defer {
            if let release = deviceVTable.pointee.Release {
                _ = release(UnsafeMutableRawPointer(deviceInterface))
            }
        }

        guard let deviceRequest = deviceVTable.pointee.DeviceRequest else {
            throw ProbeError.coreAudio(kIOReturnUnsupported, "Send Scarlett class control request")
        }
        var response = payload
        var request = IOUSBDevRequest()
        request.bmRequestType = requestType
        request.bRequest = controlRequest
        request.wValue = UInt16(UInt16(selector) << 8) | UInt16(channel)
        request.wIndex = UInt16(entityID) << 8
        request.wLength = UInt16(response.count)
        request.wLenDone = 0
        let requestStatus = response.withUnsafeMutableBytes { buffer in
            request.pData = buffer.baseAddress
            return deviceRequest(rawDeviceInterface, &request)
        }
        try check(requestStatus, operation: "Send Scarlett class control request")
        guard request.wLenDone == UInt32(response.count) else {
            throw ProbeError.unexpectedDataSize(request.wLenDone, response.count)
        }
        return response
    }

    throw ProbeError.coreAudio(kIOReturnNoDevice, "Scarlett 18i8 USB is not connected")
}

func readMonitorMixChannelGain(mix: Int, channel: Int) throws -> (raw: UInt16, db: Int) {
    guard (1...8).contains(mix), (1...18).contains(channel) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Monitor mix must be 1-8 and input channel must be 1-18")
    }
    let mixerChannel = (channel - 1) * 8 + mix - 1
    let response = try sendScarlettControlRequest(
        channel: mixerChannel,
        selector: 0x01,
        requestType: 0xA1,
        payload: [0, 0],
        allowedChannels: 0...143,
        entityID: 0x3C
    )
    let raw = UInt16(response[0]) | (UInt16(response[1]) << 8)
    let db = Int(Int16(bitPattern: raw)) >> 8
    return (raw, db)
}

func readMonitorMixGainRange(mix: Int, channel: Int) throws -> [UInt8] {
    guard (1...8).contains(mix), (1...18).contains(channel) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Monitor mix must be 1-8 and input channel must be 1-18")
    }
    let mixerChannel = (channel - 1) * 8 + mix - 1
    return try sendScarlettControlRequest(
        channel: mixerChannel,
        selector: 0x01,
        requestType: 0xA1,
        payload: [UInt8](repeating: 0, count: 14),
        allowedChannels: 0...143,
        entityID: 0x3C,
        controlRequest: 0x02
    )
}

func readMonitorInputMixGains(channel: Int) throws -> [UInt16] {
    guard (1...8).contains(channel) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Analog input channel must be between 1 and 8")
    }
    return try (1...8).map { mix in
        try readMonitorMixChannelGain(mix: mix, channel: channel).raw
    }
}

func readInputGain(channel: Int) throws -> UInt8 {
    let response = try sendScarlettControlRequest(
        channel: channel,
        selector: 0x08,
        requestType: 0xA1,
        payload: [0],
        allowedChannels: 1...8
    )
    return response[0]
}

func readInputModeValue(channel: Int) throws -> String {
    let response = try sendScarlettControlRequest(
        channel: channel,
        selector: 0x09,
        requestType: 0xA1,
        payload: [0],
        allowedChannels: 1...2
    )
    return response[0] == 0 ? "Line" : "Inst"
}

func readInputMode(channel: Int) throws -> String {
    var previousValue = try readInputModeValue(channel: channel)
    for _ in 0..<2 {
        Thread.sleep(forTimeInterval: 0.03)
        let currentValue = try readInputModeValue(channel: channel)
        if currentValue == previousValue {
            return currentValue
        }
        previousValue = currentValue
    }
    return previousValue
}

func readInputPad(channel: Int) throws -> Bool {
    guard (1...4).contains(channel) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "PAD status is supported only on analog inputs 1-4")
    }
    let response = try sendScarlettControlRequest(
        channel: channel,
        selector: 0x0B,
        requestType: 0xA1,
        payload: [0],
        allowedChannels: 1...4
    )
    return response[0] != 0
}

func setInputPad(channel: Int, enabled: Bool) throws -> Bool {
    guard (1...4).contains(channel) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "PAD control is supported only on analog inputs 1-4")
    }
    let value: UInt8 = enabled ? 1 : 0
    _ = try sendScarlettControlRequest(
        channel: channel,
        selector: 0x0B,
        requestType: 0x21,
        payload: [value, 0],
        allowedChannels: 1...4
    )
    let actualState = try readInputPad(channel: channel)
    guard actualState == enabled else {
        throw ProbeError.coreAudio(kAudioHardwareUnspecifiedError, "Input PAD read-back did not match the requested state")
    }
    return actualState
}

func setInputMode(channel: Int, mode: String) throws -> String {
    guard mode == "line" || mode == "inst" else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Mode must be 'line' or 'inst'")
    }
    let payload: UInt8 = mode == "inst" ? 1 : 0
    _ = try sendScarlettControlRequest(
        channel: channel,
        selector: 0x09,
        requestType: 0x21,
        payload: [payload, 0],
        allowedChannels: 1...2
    )
    let actualMode = try readInputMode(channel: channel)
    guard actualMode.lowercased() == mode else {
        throw ProbeError.coreAudio(kAudioHardwareUnspecifiedError, "Input mode read-back did not match the requested mode")
    }
    return actualMode
}

func summarizeAudioClassDescriptors(_ descriptor: Data) -> [String] {
    let bytes = [UInt8](descriptor)
    var summaries: [String] = []
    var offset = 0

    while offset + 2 <= bytes.count {
        let length = Int(bytes[offset])
        guard length >= 2, offset + length <= bytes.count else { break }
        if bytes[offset + 1] == 0x24 {
            let subtype = length >= 3 ? bytes[offset + 2] : 0
            let displayedLength = subtype == 0x06 || subtype == 0x04 ? length : min(length, 12)
            let prefix = bytes[offset..<offset + displayedLength]
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
            summaries.append(String(
                format: "offset 0x%03X: subtype 0x%02X, length %u, bytes %@",
                offset,
                subtype,
                length,
                prefix
            ))
        }
        offset += length
    }
    return summaries
}

func collectScarlettUSBDevices() throws -> [USBDeviceSnapshot] {
    var iterator: io_iterator_t = 0
    try check(
        IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOUSBHostDevice"),
            &iterator
        ),
        operation: "Enumerate USB host devices"
    )
    defer { IOObjectRelease(iterator) }

    var devices: [USBDeviceSnapshot] = []
    while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else { break }

        let productName = registryProperty(service, key: "USB Product Name") as? String ?? ""
        let manufacturer = registryProperty(service, key: "USB Vendor Name") as? String ?? ""
        let isScarlett = productName.localizedCaseInsensitiveContains("Scarlett")
        let isFocusrite = manufacturer.localizedCaseInsensitiveContains("Focusrite")

        if isScarlett || isFocusrite {
            let descriptor = try? readUSBConfigurationDescriptor(service: service)
            devices.append(USBDeviceSnapshot(
                productName: productName.isEmpty ? "Unknown" : productName,
                manufacturer: manufacturer.isEmpty ? "Unknown" : manufacturer,
                vendorID: registryUInt32(service, key: "idVendor"),
                productID: registryUInt32(service, key: "idProduct"),
                configurationDescriptorBytes: descriptor?.count,
                classSpecificAudioDescriptors: descriptor.map(summarizeAudioClassDescriptors) ?? [],
                featureUnits: descriptor.map(parseFeatureUnits) ?? []
            ))
        }

        IOObjectRelease(service)
    }

    return devices
}

func usbInterfaceKind(classCode: UInt32, subclass: UInt32) -> String {
    switch (classCode, subclass) {
    case (0x01, 0x01): return "Audio Control"
    case (0x01, 0x02): return "Audio Streaming"
    case (0x01, 0x03): return "MIDI Streaming"
    case (0xFE, 0x01): return "DFU"
    default: return "Other"
    }
}

func collectScarlettUSBInterfaces() throws -> [USBInterfaceSnapshot] {
    var iterator: io_iterator_t = 0
    try check(
        IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOUSBHostInterface"),
            &iterator
        ),
        operation: "Enumerate USB interfaces"
    )
    defer { IOObjectRelease(iterator) }

    var interfaces: [USBInterfaceSnapshot] = []
    while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else { break }

        let productName = registryProperty(service, key: "USB Product Name") as? String ?? ""
        let manufacturer = registryProperty(service, key: "USB Vendor Name") as? String ?? ""
        let isScarlett = productName.localizedCaseInsensitiveContains("Scarlett")
        let isFocusrite = manufacturer.localizedCaseInsensitiveContains("Focusrite")

        if isScarlett || isFocusrite {
            let number = registryUInt32(service, key: "bInterfaceNumber")
            let classCode = registryUInt32(service, key: "bInterfaceClass")
            let subclass = registryUInt32(service, key: "bInterfaceSubClass")
            let protocolCode = registryUInt32(service, key: "bInterfaceProtocol")
            interfaces.append(USBInterfaceSnapshot(
                number: number,
                classCode: classCode,
                subclass: subclass,
                protocolCode: protocolCode,
                kind: classCode.flatMap { code in
                    subclass.map { usbInterfaceKind(classCode: code, subclass: $0) }
                }
            ))
        }

        IOObjectRelease(service)
    }

    return interfaces
}