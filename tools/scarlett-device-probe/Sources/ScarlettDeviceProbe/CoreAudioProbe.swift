import CoreAudio
import Foundation

func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

func coreAudioSelector(_ fourCharacterCode: String) -> AudioObjectPropertySelector {
    precondition(fourCharacterCode.utf8.count == 4)
    return fourCharacterCode.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

func readDeviceIDs() throws -> [AudioObjectID] {
    var propertyAddress = address(kAudioHardwarePropertyDevices)
    var dataSize: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ),
        operation: "Read device-list size"
    )

    let itemSize = MemoryLayout<AudioObjectID>.stride
    guard Int(dataSize) % itemSize == 0 else {
        throw ProbeError.unexpectedDataSize(dataSize, itemSize)
    }

    var deviceIDs = [AudioObjectID](repeating: 0, count: Int(dataSize) / itemSize)
    try deviceIDs.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var returnedSize = dataSize
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &returnedSize,
                baseAddress
            ),
            operation: "Read device list"
        )
        guard returnedSize == dataSize else {
            throw ProbeError.unexpectedDataSize(returnedSize, Int(dataSize))
        }
    }
    return deviceIDs
}

func readDefaultDeviceID(selector: AudioObjectPropertySelector) -> AudioObjectID? {
    var propertyAddress = address(selector)
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &dataSize,
        &deviceID
    )
    guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
    return deviceID
}

func readDefaultDeviceName(selector: AudioObjectPropertySelector) -> String? {
    guard let deviceID = readDefaultDeviceID(selector: selector) else { return nil }
    return try? readString(deviceID, selector: kAudioObjectPropertyName)
}

func setDefaultAudioDevice(
    deviceID: UInt32,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    routeName: String
) throws -> String {
    let requestedDeviceID = AudioObjectID(deviceID)
    guard try readDeviceIDs().contains(requestedDeviceID) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Selected \(routeName) device is no longer available")
    }
    let channelCount = try readChannelCount(requestedDeviceID, scope: scope)
    guard channelCount > 0 else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Selected device has no \(routeName) channels")
    }

    var propertyAddress = address(selector)
    var isSettable = DarwinBoolean(false)
    try check(
        AudioObjectIsPropertySettable(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            &isSettable
        ),
        operation: "Check default output settable state"
    )
    guard isSettable.boolValue else {
        throw ProbeError.coreAudio(kAudioHardwareUnspecifiedError, "macOS does not allow changing the default \(routeName)")
    }

    try check(
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            withUnsafePointer(to: requestedDeviceID) { UnsafeRawPointer($0) }
        ),
        operation: "Set macOS default \(routeName) device"
    )
    guard readDefaultDeviceID(selector: selector) == requestedDeviceID else {
        throw ProbeError.coreAudio(kAudioHardwareUnspecifiedError, "Default \(routeName) read-back did not match")
    }
    return try readString(requestedDeviceID, selector: kAudioObjectPropertyName) ?? "Unknown audio device"
}

func setDefaultOutputDevice(deviceID: UInt32) throws -> String {
    try setDefaultAudioDevice(
        deviceID: deviceID,
        selector: coreAudioSelector("dOut"),
        scope: kAudioObjectPropertyScopeOutput,
        routeName: "output"
    )
}

func setDefaultInputDevice(deviceID: UInt32) throws -> String {
    try setDefaultAudioDevice(
        deviceID: deviceID,
        selector: coreAudioSelector("dIn "),
        scope: kAudioObjectPropertyScopeInput,
        routeName: "input"
    )
}

func readString(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
) throws -> String? {
    var propertyAddress = address(selector)
    var value: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(
        AudioObjectGetPropertyData(
            objectID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &value
        ),
        operation: "Read string property \(selector)"
    )
    guard let value else { return nil }
    return value.takeUnretainedValue() as String
}

func readUInt32(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
) throws -> UInt32 {
    var propertyAddress = address(selector)
    var value: UInt32 = 0
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    try check(
        AudioObjectGetPropertyData(
            objectID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &value
        ),
        operation: "Read integer property \(selector)"
    )
    return value
}

func readUInt32Array(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    operation: String
) throws -> [UInt32] {
    var propertyAddress = address(selector)
    var dataSize: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &dataSize),
        operation: "Read \(operation) size"
    )
    guard dataSize > 0 else { return [] }
    let itemSize = MemoryLayout<UInt32>.stride
    guard Int(dataSize) % itemSize == 0 else {
        throw ProbeError.unexpectedDataSize(dataSize, itemSize)
    }

    var values = [UInt32](repeating: 0, count: Int(dataSize) / itemSize)
    try values.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        try check(
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, baseAddress),
            operation: "Read \(operation)"
        )
    }
    return values
}

func readClockSourceName(_ objectID: AudioObjectID, sourceID: UInt32) throws -> String? {
    var sourceID = sourceID
    var translatedName: Unmanaged<CFString>?
    var translation = AudioValueTranslation(
        mInputData: withUnsafeMutablePointer(to: &sourceID) { UnsafeMutableRawPointer($0) },
        mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
        mOutputData: withUnsafeMutablePointer(to: &translatedName) { UnsafeMutableRawPointer($0) },
        mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    )
    var propertyAddress = address(kAudioDevicePropertyClockSourceNameForIDCFString)
    var dataSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
    try check(
        AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, &translation),
        operation: "Translate clock source name"
    )
    guard let translatedName else { return nil }
    return translatedName.takeRetainedValue() as String
}

func setScarlettClockSource(deviceID: UInt32, sourceID: UInt32) throws -> String {
    let audioDeviceID = AudioObjectID(deviceID)
    guard try readDeviceIDs().contains(audioDeviceID) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Selected audio device is no longer available")
    }
    guard let name = try readString(audioDeviceID, selector: kAudioObjectPropertyName),
          name == "Scarlett 18i8 USB" else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Clock-source changes are enabled only for Scarlett 18i8 USB")
    }
    let supportedSourceIDs = try readUInt32Array(
        audioDeviceID,
        selector: kAudioDevicePropertyClockSources,
        operation: "supported clock sources"
    )
    guard supportedSourceIDs.contains(sourceID) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Clock source is not reported as supported by the Scarlett")
    }

    var propertyAddress = address(kAudioDevicePropertyClockSource)
    var isSettable = DarwinBoolean(false)
    try check(
        AudioObjectIsPropertySettable(audioDeviceID, &propertyAddress, &isSettable),
        operation: "Check Scarlett clock-source settable state"
    )
    guard isSettable.boolValue else {
        throw ProbeError.coreAudio(kAudioHardwareUnspecifiedError, "Scarlett clock source is not settable")
    }

    var requestedSourceID = sourceID
    try check(
        AudioObjectSetPropertyData(
            audioDeviceID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            withUnsafePointer(to: &requestedSourceID) { UnsafeRawPointer($0) }
        ),
        operation: "Set Scarlett clock source"
    )
    let actualSourceID = try readUInt32(audioDeviceID, selector: kAudioDevicePropertyClockSource)
    guard actualSourceID == sourceID else {
        throw ProbeError.coreAudio(kAudioHardwareUnspecifiedError, "Scarlett clock-source read-back did not match")
    }
    return try readClockSourceName(audioDeviceID, sourceID: actualSourceID) ?? "Unknown clock source"
}

func readSampleRate(_ objectID: AudioObjectID) throws -> Double {
    var propertyAddress = address(kAudioDevicePropertyNominalSampleRate)
    var value: Float64 = 0
    var dataSize = UInt32(MemoryLayout<Float64>.size)
    try check(
        AudioObjectGetPropertyData(
            objectID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &value
        ),
        operation: "Read nominal sample rate"
    )
    return value
}

func readVolumeScalar(
    _ objectID: AudioObjectID,
    scope: AudioObjectPropertyScope
) -> Float32? {
    var propertyAddress = address(kAudioDevicePropertyVolumeScalar, scope: scope)
    guard AudioObjectHasProperty(objectID, &propertyAddress) else { return nil }

    var value: Float32 = 0
    var dataSize = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(
        objectID,
        &propertyAddress,
        0,
        nil,
        &dataSize,
        &value
    )
    return status == noErr ? value : nil
}

func readChannelVolumeScalars(
    _ objectID: AudioObjectID,
    scope: AudioObjectPropertyScope,
    channelCount: Int
) -> [ChannelVolumeSnapshot] {
    guard channelCount > 0 else { return [] }
    return (1...channelCount).compactMap { channel in
        var propertyAddress = address(kAudioDevicePropertyVolumeScalar, scope: scope)
        propertyAddress.mElement = AudioObjectPropertyElement(channel)
        guard AudioObjectHasProperty(objectID, &propertyAddress) else { return nil }

        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr else { return nil }
        return ChannelVolumeSnapshot(element: channel, scalar: value)
    }
}

func readChannelCount(
    _ objectID: AudioObjectID,
    scope: AudioObjectPropertyScope
) throws -> Int {
    var propertyAddress = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var dataSize: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(
            objectID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        ),
        operation: "Read stream-configuration size"
    )
    guard dataSize > 0 else { return 0 }

    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }

    try check(
        AudioObjectGetPropertyData(
            objectID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            storage
        ),
        operation: "Read stream configuration"
    )

    let buffers = UnsafeMutableAudioBufferListPointer(
        storage.assumingMemoryBound(to: AudioBufferList.self)
    )
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func measureInputSignal(channel: Int, durationMilliseconds: Int = 2000) throws -> InputMeterSnapshot {
    guard let snapshot = try measureInputSignals(
        channels: [channel],
        durationMilliseconds: durationMilliseconds
    ).first else {
        throw ProbeError.coreAudio(kAudioHardwareUnspecifiedError, "No input samples were measured")
    }
    return snapshot
}

func measureAllInputSignals(durationMilliseconds: Int = 2000) throws -> [InputMeterSnapshot] {
    try measureInputSignals(channels: nil, durationMilliseconds: durationMilliseconds)
}

func measureInputSignals(
    channels requestedChannels: [Int]?,
    durationMilliseconds: Int
) throws -> [InputMeterSnapshot] {
    let deviceIDs = try readDeviceIDs()
    var selectedDevice: AudioObjectID?
    for deviceID in deviceIDs {
        if let name = try? readString(deviceID, selector: kAudioObjectPropertyName),
           name.localizedCaseInsensitiveContains("Scarlett 18i8 USB") {
            selectedDevice = deviceID
            break
        }
    }
    guard let selectedDevice else {
        throw ProbeError.coreAudio(kAudioHardwareBadDeviceError, "Scarlett 18i8 USB is not an audio device")
    }

    let channelCount = try readChannelCount(selectedDevice, scope: kAudioObjectPropertyScopeInput)
    let channels = requestedChannels ?? Array(1...channelCount)
    guard !channels.isEmpty, channels.allSatisfy({ (1...channelCount).contains($0) }) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Input channels must be between 1 and \(channelCount)")
    }

    var streamAddress = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    var streamsSize: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(selectedDevice, &streamAddress, 0, nil, &streamsSize),
        operation: "Read Scarlett input-stream list size"
    )
    let streamStride = MemoryLayout<AudioStreamID>.stride
    guard streamsSize >= UInt32(streamStride), Int(streamsSize) % streamStride == 0 else {
        throw ProbeError.unexpectedDataSize(streamsSize, streamStride)
    }
    var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / streamStride)
    try streams.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        try check(
            AudioObjectGetPropertyData(selectedDevice, &streamAddress, 0, nil, &streamsSize, baseAddress),
            operation: "Read Scarlett input-stream list"
        )
    }
    guard let inputStream = streams.first else {
        throw ProbeError.coreAudio(kAudioHardwareBadDeviceError, "Scarlett has no input stream")
    }

    var formatAddress = address(kAudioStreamPropertyVirtualFormat)
    var streamFormat = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(
        AudioObjectGetPropertyData(inputStream, &formatAddress, 0, nil, &formatSize, &streamFormat),
        operation: "Read Scarlett input sample format"
    )
    guard streamFormat.mFormatID == kAudioFormatLinearPCM,
          streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
          streamFormat.mBitsPerChannel == 32,
                    streamFormat.mChannelsPerFrame >= UInt32(channelCount) else {
        throw ProbeError.coreAudio(kAudioHardwareUnspecifiedError, "Unsupported Scarlett input format for meter")
    }

        let selectedChannelIndexes = Set(channels.map { $0 - 1 })
        let sumSquares = UnsafeMutablePointer<Double>.allocate(capacity: channelCount)
        let peaks = UnsafeMutablePointer<Double>.allocate(capacity: channelCount)
        let frameCounters = UnsafeMutablePointer<UInt64>.allocate(capacity: channelCount)
        sumSquares.initialize(repeating: 0, count: channelCount)
        peaks.initialize(repeating: 0, count: channelCount)
        frameCounters.initialize(repeating: 0, count: channelCount)
    defer {
                sumSquares.deinitialize(count: channelCount)
        sumSquares.deallocate()
                peaks.deinitialize(count: channelCount)
                peaks.deallocate()
                frameCounters.deinitialize(count: channelCount)
                frameCounters.deallocate()
    }

    var ioProcID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcIDWithBlock(
        &ioProcID,
        selectedDevice,
        DispatchQueue.global(qos: .userInitiated)
    ) { _, inputData, _, _, _ in
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        var channelOffset = 0

        for buffer in buffers {
            let bufferChannels = Int(buffer.mNumberChannels)
            if let data = buffer.mData, bufferChannels > 0 {
                let samples = data.assumingMemoryBound(to: Float32.self)
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride
                let frames = sampleCount / bufferChannels
                for bufferChannel in 0..<bufferChannels {
                    let channelIndex = channelOffset + bufferChannel
                    guard channelIndex < channelCount,
                          selectedChannelIndexes.contains(channelIndex) else {
                        continue
                    }
                    var localSumSquares = 0.0
                    var localPeak = 0.0
                    for frame in 0..<frames {
                        let sample = Double(samples[frame * bufferChannels + bufferChannel])
                        localSumSquares += sample * sample
                        localPeak = max(localPeak, abs(sample))
                    }
                    sumSquares[channelIndex] += localSumSquares
                    peaks[channelIndex] = max(peaks[channelIndex], localPeak)
                    frameCounters[channelIndex] += UInt64(frames)
                }
            }
            channelOffset += bufferChannels
        }
    }
    try check(createStatus, operation: "Create Scarlett input meter callback")
    guard let ioProcID else {
        throw ProbeError.coreAudio(kAudioHardwareBadDeviceError, "Create Scarlett input meter callback")
    }
    defer { _ = AudioDeviceDestroyIOProcID(selectedDevice, ioProcID) }

    try check(AudioDeviceStart(selectedDevice, ioProcID), operation: "Start 2-second Scarlett input meter")
    let captureFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + .milliseconds(durationMilliseconds)
    ) {
        captureFinished.signal()
    }
    _ = captureFinished.wait(timeout: .now() + .milliseconds(durationMilliseconds + 3000))
    try check(AudioDeviceStop(selectedDevice, ioProcID), operation: "Stop Scarlett input meter")

    return try channels.map { channel in
        let channelIndex = channel - 1
        let frames = frameCounters[channelIndex]
        guard frames > 0 else {
            throw ProbeError.coreAudio(
                kAudioHardwareUnspecifiedError,
                "No input samples were received for channel \(channel)"
            )
        }
        let rms = sqrt(sumSquares[channelIndex] / Double(frames))
        return InputMeterSnapshot(
            device: "Scarlett 18i8 USB",
            channel: channel,
            durationMilliseconds: durationMilliseconds,
            sampleRateHz: streamFormat.mSampleRate,
            frames: frames,
            rms: rms,
            peak: peaks[channelIndex],
            rmsDbFS: 20 * log10(max(rms, 1e-12)),
            peakDbFS: 20 * log10(max(peaks[channelIndex], 1e-12))
        )
    }
}

func readSampleRateRanges(_ objectID: AudioObjectID) throws -> [SampleRateRangeSnapshot] {
    var propertyAddress = address(
        kAudioDevicePropertyAvailableNominalSampleRates,
        scope: kAudioObjectPropertyScopeOutput
    )
    var dataSize: UInt32 = 0
    try check(
        AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &dataSize),
        operation: "Read supported sample-rate range size"
    )

    let rangeStride = MemoryLayout<AudioValueRange>.stride
    guard dataSize > 0 else { return [] }
    guard Int(dataSize) % rangeStride == 0 else {
        throw ProbeError.unexpectedDataSize(dataSize, rangeStride)
    }
    let rangeCount = Int(dataSize) / rangeStride
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<AudioValueRange>.alignment
    )
    defer { storage.deallocate() }

    try check(
        AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, storage),
        operation: "Read supported sample-rate ranges"
    )
    let ranges = UnsafeBufferPointer(
        start: storage.assumingMemoryBound(to: AudioValueRange.self),
        count: rangeCount
    )
    return ranges.map { SampleRateRangeSnapshot(minimumHz: $0.mMinimum, maximumHz: $0.mMaximum) }
}

func setScarlettSampleRate(deviceID: UInt32, sampleRateHz: Double) throws -> Double {
    let audioDeviceID = AudioObjectID(deviceID)
    guard try readDeviceIDs().contains(audioDeviceID) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Selected audio device is no longer available")
    }
    guard let name = try readString(audioDeviceID, selector: kAudioObjectPropertyName),
          name == "Scarlett 18i8 USB" else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Sample-rate changes are enabled only for Scarlett 18i8 USB")
    }
    let supportedRanges = try readSampleRateRanges(audioDeviceID)
    guard supportedRanges.contains(where: { sampleRateHz >= $0.minimumHz && sampleRateHz <= $0.maximumHz }) else {
        throw ProbeError.coreAudio(kIOReturnBadArgument, "Requested rate is not reported as supported by the Scarlett")
    }

    var propertyAddress = address(
        kAudioDevicePropertyNominalSampleRate,
        scope: kAudioObjectPropertyScopeInput
    )
    var isSettable = DarwinBoolean(false)
    try check(
        AudioObjectIsPropertySettable(audioDeviceID, &propertyAddress, &isSettable),
        operation: "Check Scarlett sample-rate settable state"
    )
    guard isSettable.boolValue else {
        throw ProbeError.coreAudio(kAudioHardwareUnspecifiedError, "Scarlett sample rate is not settable")
    }

    let requestedRate = Float64(sampleRateHz)
    try check(
        AudioObjectSetPropertyData(
            audioDeviceID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            withUnsafePointer(to: requestedRate) { UnsafeRawPointer($0) }
        ),
        operation: "Set Scarlett sample rate"
    )
    let actualRate = try readSampleRate(audioDeviceID)
    guard abs(actualRate - sampleRateHz) < 0.5 else {
        throw ProbeError.coreAudio(kAudioHardwareUnspecifiedError, "Scarlett sample-rate read-back did not match")
    }
    return actualRate
}

func collectAudioDevices() throws -> [AudioDeviceSnapshot] {
    let deviceIDs = try readDeviceIDs()

    return deviceIDs.map { deviceID in
        let name = (try? readString(deviceID, selector: kAudioObjectPropertyName)) ?? nil
            ?? "Unnamed device \(deviceID)"
        let manufacturer = (try? readString(deviceID, selector: kAudioObjectPropertyManufacturer)) ?? nil
            ?? "Unknown"
        let transport = (try? readUInt32(deviceID, selector: kAudioDevicePropertyTransportType))
            .map(transportName)
        let inputChannels = (try? readChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput))
        let outputChannels = (try? readChannelCount(deviceID, scope: kAudioObjectPropertyScopeOutput))
        let sampleRate = try? readSampleRate(deviceID)
        let isScarlett = name.localizedCaseInsensitiveContains("Scarlett")
        let currentClockSourceID = try? readUInt32(deviceID, selector: kAudioDevicePropertyClockSource)
        let currentClockSourceName = currentClockSourceID.flatMap { sourceID in
            try? readClockSourceName(deviceID, sourceID: sourceID)
        } ?? nil
        let supportedClockSourceIDs = (try? readUInt32Array(
            deviceID,
            selector: kAudioDevicePropertyClockSources,
            operation: "supported clock sources"
        )) ?? []
        let supportedClockSources = supportedClockSourceIDs.compactMap { sourceID -> ClockSourceSnapshot? in
            guard let sourceName = try? readClockSourceName(deviceID, sourceID: sourceID) else {
                return nil
            }
            return ClockSourceSnapshot(id: sourceID, name: sourceName)
        }

        return AudioDeviceSnapshot(
            deviceID: deviceID,
            name: name,
            manufacturer: manufacturer,
            transport: transport,
            inputChannels: inputChannels,
            outputChannels: outputChannels,
            sampleRateHz: sampleRate,
            supportedSampleRateRanges: isScarlett
                ? (try? readSampleRateRanges(deviceID)) ?? []
                : [],
            currentClockSourceID: currentClockSourceID,
            currentClockSourceName: currentClockSourceName,
            supportedClockSources: supportedClockSources,
            inputVolumeScalar: isScarlett
                ? readVolumeScalar(deviceID, scope: kAudioObjectPropertyScopeInput)
                : nil,
            outputVolumeScalar: isScarlett
                ? readVolumeScalar(deviceID, scope: kAudioObjectPropertyScopeOutput)
                : nil,
            inputChannelVolumeScalars: isScarlett
                ? readChannelVolumeScalars(
                    deviceID,
                    scope: kAudioObjectPropertyScopeInput,
                    channelCount: inputChannels ?? 0
                )
                : [],
            outputChannelVolumeScalars: isScarlett
                ? readChannelVolumeScalars(
                    deviceID,
                    scope: kAudioObjectPropertyScopeOutput,
                    channelCount: outputChannels ?? 0
                )
                : []
        )
    }
}