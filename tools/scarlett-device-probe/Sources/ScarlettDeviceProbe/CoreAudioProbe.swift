import CoreAudio
import Dispatch
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
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Selected \(routeName) device is no longer available")
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
    throw ProbeError.coreAudio(
      kAudioHardwareUnspecifiedError, "macOS does not allow changing the default \(routeName)")
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
    throw ProbeError.coreAudio(
      kAudioHardwareUnspecifiedError, "Default \(routeName) read-back did not match")
  }
  return try readString(requestedDeviceID, selector: kAudioObjectPropertyName)
    ?? "Unknown audio device"
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
    name == "Scarlett 18i8 USB"
  else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Clock-source changes are enabled only for Scarlett 18i8 USB")
  }
  let supportedSourceIDs = try readUInt32Array(
    audioDeviceID,
    selector: kAudioDevicePropertyClockSources,
    operation: "supported clock sources"
  )
  guard supportedSourceIDs.contains(sourceID) else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Clock source is not reported as supported by the Scarlett")
  }

  var propertyAddress = address(kAudioDevicePropertyClockSource)
  var isSettable = DarwinBoolean(false)
  try check(
    AudioObjectIsPropertySettable(audioDeviceID, &propertyAddress, &isSettable),
    operation: "Check Scarlett clock-source settable state"
  )
  guard isSettable.boolValue else {
    throw ProbeError.coreAudio(
      kAudioHardwareUnspecifiedError, "Scarlett clock source is not settable")
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
    throw ProbeError.coreAudio(
      kAudioHardwareUnspecifiedError, "Scarlett clock-source read-back did not match")
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

func readFirstStreamFormat(
  _ deviceID: AudioObjectID,
  scope: AudioObjectPropertyScope,
  operation: String
) throws -> AudioStreamBasicDescription {
  var streamAddress = address(kAudioDevicePropertyStreams, scope: scope)
  var streamsSize: UInt32 = 0
  try check(
    AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamsSize),
    operation: "Read \(operation) stream-list size"
  )
  let stride = MemoryLayout<AudioStreamID>.stride
  guard streamsSize >= UInt32(stride), Int(streamsSize) % stride == 0 else {
    throw ProbeError.unexpectedDataSize(streamsSize, stride)
  }
  var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / stride)
  try streams.withUnsafeMutableBytes { buffer in
    guard let baseAddress = buffer.baseAddress else { return }
    try check(
      AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamsSize, baseAddress),
      operation: "Read \(operation) stream list"
    )
  }
  guard let streamID = streams.first else {
    throw ProbeError.coreAudio(kAudioHardwareBadDeviceError, "No \(operation) stream")
  }

  var formatAddress = address(kAudioStreamPropertyVirtualFormat)
  var format = AudioStreamBasicDescription()
  var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
  try check(
    AudioObjectGetPropertyData(streamID, &formatAddress, 0, nil, &formatSize, &format),
    operation: "Read \(operation) sample format"
  )
  return format
}

func measureInputSignal(channel: Int, durationMilliseconds: Int = 2000) throws -> InputMeterSnapshot
{
  guard
    let snapshot = try measureInputSignals(
      channels: [channel],
      durationMilliseconds: durationMilliseconds
    ).first
  else {
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
      name.localizedCaseInsensitiveContains("Scarlett 18i8 USB")
    {
      selectedDevice = deviceID
      break
    }
  }
  guard let selectedDevice else {
    throw ProbeError.coreAudio(
      kAudioHardwareBadDeviceError, "Scarlett 18i8 USB is not an audio device")
  }

  let channelCount = try readChannelCount(selectedDevice, scope: kAudioObjectPropertyScopeInput)
  let channels = requestedChannels ?? Array(1...channelCount)
  guard !channels.isEmpty, channels.allSatisfy({ (1...channelCount).contains($0) }) else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Input channels must be between 1 and \(channelCount)")
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
    streamFormat.mChannelsPerFrame >= UInt32(channelCount)
  else {
    throw ProbeError.coreAudio(
      kAudioHardwareUnspecifiedError, "Unsupported Scarlett input format for meter")
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
            selectedChannelIndexes.contains(channelIndex)
          else {
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

  try check(
    AudioDeviceStart(selectedDevice, ioProcID), operation: "Start 2-second Scarlett input meter")
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

private final class InputMeterAccumulator {
  private var sumSquares: Double = 0.0
  private var peak: Double = 0.0
  private var frames: UInt64 = 0

  func add(sumSquares: Double, peak: Double, frames: UInt64) {
    self.sumSquares += sumSquares
    self.peak = max(self.peak, peak)
    self.frames += frames
  }

  func take() -> (sumSquares: Double, peak: Double, frames: UInt64) {
    let value: (Double, Double, UInt64) = (sumSquares, peak, frames)
    sumSquares = 0
    peak = 0
    frames = 0
    return value
  }
}

func streamInputSignal(channel: Int, intervalMilliseconds: Int = 50) throws -> Never {
  try streamInputSignals(channels: [channel], intervalMilliseconds: intervalMilliseconds)
}

func streamInputSignals(
  channels: [Int],
  intervalMilliseconds: Int = 50,
  deviceID: AudioObjectID? = nil,
  deviceName: String = "Scarlett 18i8 USB",
  direction: MeterDirection = .input,
  startDeviceAsynchronously: Bool = false,
  onTermination: @escaping () -> Void = {}
) throws -> Never {
  let selectedDevice: AudioObjectID
  if let deviceID {
    selectedDevice = deviceID
  } else {
    let deviceIDs = try readDeviceIDs()
    var scarlettDeviceID: AudioObjectID?
    for candidateDeviceID in deviceIDs {
      if let name = try? readString(candidateDeviceID, selector: kAudioObjectPropertyName),
        name == "Scarlett 18i8 USB"
      {
        scarlettDeviceID = candidateDeviceID
        break
      }
    }
    guard let scarlettDeviceID else {
      throw ProbeError.coreAudio(
        kAudioHardwareBadDeviceError, "Scarlett 18i8 USB is not an audio device")
    }
    selectedDevice = scarlettDeviceID
  }

  let channelCount = try readChannelCount(selectedDevice, scope: kAudioObjectPropertyScopeInput)
  guard !channels.isEmpty,
    Set(channels).count == channels.count,
    channels.allSatisfy({ (1...channelCount).contains($0) })
  else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Input channels must be unique values between 1 and \(channelCount)")
  }
  guard intervalMilliseconds >= 20, intervalMilliseconds <= 1000 else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Meter stream interval must be between 20 and 1000 ms")
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
    streamFormat.mChannelsPerFrame >= UInt32(channels.max() ?? 0)
  else {
    throw ProbeError.coreAudio(
      kAudioHardwareUnspecifiedError, "Unsupported Scarlett input format for meter stream")
  }

  let channelIndexes = Set(channels.map { $0 - 1 })
  let accumulators = Dictionary(
    uniqueKeysWithValues: channels.map { ($0 - 1, InputMeterAccumulator()) })
  let captureQueue = DispatchQueue(
    label: "ScarlettDeviceProbe.liveMeterCapture", qos: .userInitiated)
  let outputQueue = DispatchQueue(label: "ScarlettDeviceProbe.liveMeterOutput", qos: .utility)
  var ioProcID: AudioDeviceIOProcID?
  let createStatus = AudioDeviceCreateIOProcIDWithBlock(
    &ioProcID,
    selectedDevice,
    captureQueue
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
            channelIndexes.contains(channelIndex),
            let accumulator = accumulators[channelIndex]
          else {
            continue
          }
          var sumSquares = 0.0
          var peak = 0.0
          for frame in 0..<frames {
            let sample = Double(samples[frame * bufferChannels + bufferChannel])
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
          }
          accumulator.add(sumSquares: sumSquares, peak: peak, frames: UInt64(frames))
        }
      }
      channelOffset += bufferChannels
    }
  }
  try check(createStatus, operation: "Create Scarlett live meter callback")
  guard let ioProcID else {
    throw ProbeError.coreAudio(kAudioHardwareBadDeviceError, "Create Scarlett live meter callback")
  }
  let startDevice = {
    let status = AudioDeviceStart(selectedDevice, ioProcID)
    if status != noErr {
      fputs("Start Scarlett output tap failed with CoreAudio status \(status)\n", stderr)
      exit(EXIT_FAILURE)
    }
  }
  if startDeviceAsynchronously {
    DispatchQueue.global(qos: .userInitiated).async(execute: startDevice)
  } else {
    try check(
      AudioDeviceStart(selectedDevice, ioProcID), operation: "Start Scarlett live input meter")
  }

  let encoder = JSONEncoder()
  let timer = DispatchSource.makeTimerSource(queue: outputQueue)
  timer.schedule(
    deadline: .now(), repeating: .milliseconds(intervalMilliseconds), leeway: .milliseconds(5))
  timer.setEventHandler {
    captureQueue.async {
      let frames = channels.sorted().compactMap { channel -> MeterStreamFrame? in
        guard let accumulator = accumulators[channel - 1] else { return nil }
        let interval = accumulator.take()
        let rms =
          interval.frames > 0
          ? sqrt(interval.sumSquares / Double(interval.frames))
          : 0
        return MeterStreamFrame(
          device: deviceName,
          direction: direction,
          channel: channel,
          sampleRateHz: streamFormat.mSampleRate,
          frames: interval.frames,
          rmsDbFS: 20 * log10(max(rms, 1e-12)),
          peakDbFS: 20 * log10(max(interval.peak, 1e-12))
        )
      }
      outputQueue.async {
        if let data = try? encoder.encode(frames) {
          FileHandle.standardOutput.write(data)
          FileHandle.standardOutput.write(Data([0x0A]))
        }
      }
    }
  }
  timer.resume()

  Darwin.signal(SIGTERM, SIG_IGN)
  let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: outputQueue)
  termination.setEventHandler {
    timer.cancel()
    _ = AudioDeviceStop(selectedDevice, ioProcID)
    _ = AudioDeviceDestroyIOProcID(selectedDevice, ioProcID)
    onTermination()
    exit(EXIT_SUCCESS)
  }
  termination.resume()
  dispatchMain()
}

func playScarlettOutputTone(
  channels: [Int], frequencyHz: Double = 440, durationMilliseconds: Int = 2000
) throws {
  guard !channels.isEmpty,
    Set(channels).count == channels.count,
    channels.allSatisfy({ (1...8).contains($0) })
  else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Scarlett output channels must be unique values between 1 and 8")
  }
  guard frequencyHz >= 20, frequencyHz <= 20_000 else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Tone frequency must be between 20 and 20000 Hz")
  }
  guard durationMilliseconds >= 100, durationMilliseconds <= 10_000 else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Tone duration must be between 100 and 10000 ms")
  }

  let deviceIDs = try readDeviceIDs()
  var selectedDevice: AudioObjectID?
  for deviceID in deviceIDs {
    if let name = try? readString(deviceID, selector: kAudioObjectPropertyName),
      name == "Scarlett 18i8 USB"
    {
      selectedDevice = deviceID
      break
    }
  }
  guard let selectedDevice else {
    throw ProbeError.coreAudio(
      kAudioHardwareBadDeviceError, "Scarlett 18i8 USB is not an audio device")
  }

  let channelCount = try readChannelCount(selectedDevice, scope: kAudioObjectPropertyScopeOutput)
  guard channels.allSatisfy({ (1...channelCount).contains($0) }) else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Output channels must be between 1 and \(channelCount)")
  }

  var streamAddress = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
  var streamsSize: UInt32 = 0
  try check(
    AudioObjectGetPropertyDataSize(selectedDevice, &streamAddress, 0, nil, &streamsSize),
    operation: "Read Scarlett output-stream list size")
  let streamStride = MemoryLayout<AudioStreamID>.stride
  guard streamsSize >= UInt32(streamStride), Int(streamsSize) % streamStride == 0 else {
    throw ProbeError.unexpectedDataSize(streamsSize, streamStride)
  }
  var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / streamStride)
  try streams.withUnsafeMutableBytes { buffer in
    guard let baseAddress = buffer.baseAddress else { return }
    try check(
      AudioObjectGetPropertyData(selectedDevice, &streamAddress, 0, nil, &streamsSize, baseAddress),
      operation: "Read Scarlett output-stream list")
  }
  guard let outputStream = streams.first else {
    throw ProbeError.coreAudio(kAudioHardwareBadDeviceError, "Scarlett has no output stream")
  }

  var formatAddress = address(kAudioStreamPropertyVirtualFormat)
  var streamFormat = AudioStreamBasicDescription()
  var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
  try check(
    AudioObjectGetPropertyData(outputStream, &formatAddress, 0, nil, &formatSize, &streamFormat),
    operation: "Read Scarlett output sample format")
  guard streamFormat.mFormatID == kAudioFormatLinearPCM,
    streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
    streamFormat.mBitsPerChannel == 32,
    streamFormat.mChannelsPerFrame >= UInt32(channelCount)
  else {
    throw ProbeError.coreAudio(
      kAudioHardwareUnspecifiedError, "Unsupported Scarlett output format for tone")
  }

  let selectedChannels = Set(channels.map { $0 - 1 })
  var phase = 0.0
  var ioProcID: AudioDeviceIOProcID?
  let createStatus = AudioDeviceCreateIOProcIDWithBlock(
    &ioProcID, selectedDevice, DispatchQueue.global(qos: .userInitiated)
  ) { _, _, _, outputData, _ in
    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
    var channelOffset = 0
    for buffer in buffers {
      let bufferChannels = Int(buffer.mNumberChannels)
      if let data = buffer.mData, bufferChannels > 0 {
        let samples = data.assumingMemoryBound(to: Float32.self)
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride
        let frames = sampleCount / bufferChannels
        for frame in 0..<frames {
          let tone = Float32(sin(phase) * 0.12)
          for bufferChannel in 0..<bufferChannels {
            let channelIndex = channelOffset + bufferChannel
            samples[frame * bufferChannels + bufferChannel] =
              selectedChannels.contains(channelIndex) ? tone : 0
          }
          phase += 2 * Double.pi * frequencyHz / streamFormat.mSampleRate
          if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
      }
      channelOffset += bufferChannels
    }
  }
  try check(createStatus, operation: "Create Scarlett output tone callback")
  guard let ioProcID else {
    throw ProbeError.coreAudio(kAudioHardwareBadDeviceError, "Create Scarlett output tone callback")
  }
  defer { _ = AudioDeviceDestroyIOProcID(selectedDevice, ioProcID) }

  try check(AudioDeviceStart(selectedDevice, ioProcID), operation: "Start Scarlett output tone")
  Thread.sleep(forTimeInterval: Double(durationMilliseconds) / 1000)
  try check(AudioDeviceStop(selectedDevice, ioProcID), operation: "Stop Scarlett output tone")
}

func streamScarlettSoftwareMonitor(
  inputChannel: Int,
  outputChannels: [Int],
  gainDecibels: Double = -12,
  intervalMilliseconds: Int = 50
) throws -> Never {
  let deviceIDs = try readDeviceIDs()
  var selectedDevice: AudioObjectID?
  for deviceID in deviceIDs {
    if let name = try? readString(deviceID, selector: kAudioObjectPropertyName),
      name == "Scarlett 18i8 USB"
    {
      selectedDevice = deviceID
      break
    }
  }
  guard let selectedDevice else {
    throw ProbeError.coreAudio(
      kAudioHardwareBadDeviceError, "Scarlett 18i8 USB is not an audio device")
  }

  let inputChannelCount = try readChannelCount(
    selectedDevice, scope: kAudioObjectPropertyScopeInput)
  let outputChannelCount = try readChannelCount(
    selectedDevice, scope: kAudioObjectPropertyScopeOutput)

  guard (1...inputChannelCount).contains(inputChannel) else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Input channel must be between 1 and \(inputChannelCount)")
  }
  guard !outputChannels.isEmpty,
    Set(outputChannels).count == outputChannels.count,
    outputChannels.allSatisfy({ (1...outputChannelCount).contains($0) })
  else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument,
      "Output channels must be unique values between 1 and \(outputChannelCount)")
  }
  guard gainDecibels >= -30, gainDecibels <= 0 else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Software monitor gain must be between -30 and 0 dB")
  }
  guard intervalMilliseconds >= 20, intervalMilliseconds <= 1000 else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Meter stream interval must be between 20 and 1000 ms")
  }

  let inputFormat = try readFirstStreamFormat(
    selectedDevice, scope: kAudioObjectPropertyScopeInput, operation: "Scarlett input")
  let outputFormat = try readFirstStreamFormat(
    selectedDevice, scope: kAudioObjectPropertyScopeOutput, operation: "Scarlett output")
  guard inputFormat.mFormatID == kAudioFormatLinearPCM,
    inputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
    inputFormat.mBitsPerChannel == 32,
    inputFormat.mChannelsPerFrame >= UInt32(inputChannel),
    outputFormat.mFormatID == kAudioFormatLinearPCM,
    outputFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
    outputFormat.mBitsPerChannel == 32,
    outputFormat.mChannelsPerFrame >= UInt32(outputChannels.max() ?? 0),
    abs(inputFormat.mSampleRate - outputFormat.mSampleRate) < 0.5
  else {
    throw ProbeError.coreAudio(
      kAudioHardwareUnspecifiedError,
      "Scarlett input/output formats are incompatible for software monitoring")
  }

  let gain = pow(10, gainDecibels / 20)
  let selectedOutputIndexes = Set(outputChannels.map { $0 - 1 })
  let accumulators = Dictionary(
    uniqueKeysWithValues: outputChannels.map { ($0 - 1, InputMeterAccumulator()) })
  let sumSquares = UnsafeMutablePointer<Double>.allocate(capacity: outputChannelCount)
  let peaks = UnsafeMutablePointer<Double>.allocate(capacity: outputChannelCount)
  let frameCounters = UnsafeMutablePointer<UInt64>.allocate(capacity: outputChannelCount)
  sumSquares.initialize(repeating: 0, count: outputChannelCount)
  peaks.initialize(repeating: 0, count: outputChannelCount)
  frameCounters.initialize(repeating: 0, count: outputChannelCount)
  defer {
    sumSquares.deinitialize(count: outputChannelCount)
    sumSquares.deallocate()
    peaks.deinitialize(count: outputChannelCount)
    peaks.deallocate()
    frameCounters.deinitialize(count: outputChannelCount)
    frameCounters.deallocate()
  }

  let captureQueue = DispatchQueue(
    label: "ScarlettDeviceProbe.softwareMonitorCapture", qos: .userInitiated)
  let outputQueue = DispatchQueue(
    label: "ScarlettDeviceProbe.softwareMonitorOutput", qos: .utility)
  var ioProcID: AudioDeviceIOProcID?
  let createStatus = AudioDeviceCreateIOProcIDWithBlock(
    &ioProcID,
    selectedDevice,
    captureQueue
  ) { _, inputData, _, outputData, _ in
    let inputBuffers = UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: inputData))
    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
    let inputIndex = inputChannel - 1
    var inputChannelOffset = 0
    var inputSamples: UnsafePointer<Float32>?
    var inputBufferChannels = 0
    var inputBufferChannel = 0
    var inputFrames = 0

    for buffer in inputBuffers {
      let bufferChannels = Int(buffer.mNumberChannels)
      if let data = buffer.mData,
        bufferChannels > 0,
        inputIndex >= inputChannelOffset,
        inputIndex < inputChannelOffset + bufferChannels
      {
        inputSamples = UnsafeRawPointer(data).assumingMemoryBound(to: Float32.self)
        inputBufferChannels = bufferChannels
        inputBufferChannel = inputIndex - inputChannelOffset
        inputFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride / bufferChannels
        break
      }
      inputChannelOffset += bufferChannels
    }

    for channel in 0..<outputChannelCount {
      sumSquares[channel] = 0
      peaks[channel] = 0
      frameCounters[channel] = 0
    }

    var outputChannelOffset = 0
    for buffer in outputBuffers {
      let bufferChannels = Int(buffer.mNumberChannels)
      if let data = buffer.mData, bufferChannels > 0 {
        let outputSamples = data.assumingMemoryBound(to: Float32.self)
        let outputFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride / bufferChannels
        for frame in 0..<outputFrames {
          let inputValue: Double
          if let inputSamples, frame < inputFrames {
            inputValue = Double(
              inputSamples[frame * inputBufferChannels + inputBufferChannel])
          } else {
            inputValue = 0
          }
          let monitoredSample = Float32(max(-1, min(1, inputValue * gain)))
          for bufferChannel in 0..<bufferChannels {
            let outputIndex = outputChannelOffset + bufferChannel
            let isSelected = selectedOutputIndexes.contains(outputIndex)
            outputSamples[frame * bufferChannels + bufferChannel] =
              isSelected ? monitoredSample : 0
            if isSelected {
              let sample = Double(monitoredSample)
              sumSquares[outputIndex] += sample * sample
              peaks[outputIndex] = max(peaks[outputIndex], abs(sample))
              frameCounters[outputIndex] += 1
            }
          }
        }
      }
      outputChannelOffset += bufferChannels
    }

    for outputChannel in outputChannels {
      let index = outputChannel - 1
      accumulators[index]?.add(
        sumSquares: sumSquares[index],
        peak: peaks[index],
        frames: frameCounters[index]
      )
    }
  }
  try check(createStatus, operation: "Create Scarlett software-monitor callback")
  guard let ioProcID else {
    throw ProbeError.coreAudio(
      kAudioHardwareBadDeviceError, "Create Scarlett software-monitor callback")
  }
  defer { _ = AudioDeviceDestroyIOProcID(selectedDevice, ioProcID) }
  try check(
    AudioDeviceStart(selectedDevice, ioProcID), operation: "Start Scarlett software monitor")

  let encoder = JSONEncoder()
  let timer = DispatchSource.makeTimerSource(queue: outputQueue)
  timer.schedule(
    deadline: .now(), repeating: .milliseconds(intervalMilliseconds), leeway: .milliseconds(5))
  timer.setEventHandler {
    captureQueue.async {
      let frames = outputChannels.sorted().compactMap { channel -> MeterStreamFrame? in
        guard let accumulator = accumulators[channel - 1] else { return nil }
        let interval = accumulator.take()
        let rms =
          interval.frames > 0
          ? sqrt(interval.sumSquares / Double(interval.frames))
          : 0
        return MeterStreamFrame(
          device: "Scarlett 18i8 USB software monitor",
          direction: .softwareMonitor,
          channel: channel,
          sampleRateHz: outputFormat.mSampleRate,
          frames: interval.frames,
          rmsDbFS: 20 * log10(max(rms, 1e-12)),
          peakDbFS: 20 * log10(max(interval.peak, 1e-12))
        )
      }
      outputQueue.async {
        if let data = try? encoder.encode(frames) {
          FileHandle.standardOutput.write(data)
          FileHandle.standardOutput.write(Data([0x0A]))
        }
      }
    }
  }
  timer.resume()

  Darwin.signal(SIGTERM, SIG_IGN)
  let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: outputQueue)
  termination.setEventHandler {
    timer.cancel()
    _ = AudioDeviceStop(selectedDevice, ioProcID)
    _ = AudioDeviceDestroyIOProcID(selectedDevice, ioProcID)
    exit(EXIT_SUCCESS)
  }
  termination.resume()
  dispatchMain()
}

@available(macOS 14.2, *)
func streamScarlettOutputSignals(channels: [Int], intervalMilliseconds: Int = 50) throws -> Never {
  let deviceIDs = try readDeviceIDs()
  var scarlettDeviceID: AudioObjectID?
  for deviceID in deviceIDs {
    if let name = try? readString(deviceID, selector: kAudioObjectPropertyName),
      name == "Scarlett 18i8 USB"
    {
      scarlettDeviceID = deviceID
      break
    }
  }
  guard let scarlettDeviceID else {
    throw ProbeError.coreAudio(
      kAudioHardwareBadDeviceError, "Scarlett 18i8 USB is not an audio device")
  }
  guard let deviceUID = try readString(scarlettDeviceID, selector: kAudioDevicePropertyDeviceUID)
  else {
    throw ProbeError.coreAudio(kAudioHardwareBadDeviceError, "Read Scarlett device UID")
  }
  guard !channels.isEmpty,
    Set(channels).count == channels.count,
    channels.allSatisfy({ (1...8).contains($0) })
  else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Scarlett output channels must be between 1 and 8")
  }

  let tapDescription = CATapDescription(
    __excludingProcesses: [],
    andDeviceUID: deviceUID,
    withStream: 0
  )
  tapDescription.name = "Scarlett 18i8 Main Output Meter"
  tapDescription.isPrivate = true
  tapDescription.muteBehavior = CATapMuteBehavior.unmuted

  var tapID: AudioObjectID = kAudioObjectUnknown
  try check(
    AudioHardwareCreateProcessTap(tapDescription, &tapID),
    operation: "Create read-only Scarlett output tap"
  )
  guard tapID != kAudioObjectUnknown else {
    throw ProbeError.coreAudio(kAudioHardwareBadDeviceError, "Create Scarlett output tap")
  }

  let tapList: [[String: Any]] = [
    [
      kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
      kAudioSubTapDriftCompensationKey: true,
    ]
  ]
  let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Scarlett 18i8 Main Output Meter",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapListKey: tapList,
  ]
  var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
  do {
    try check(
      AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
      operation: "Create private Scarlett output meter device"
    )
  } catch {
    _ = AudioHardwareDestroyProcessTap(tapID)
    throw error
  }
  guard aggregateDeviceID != kAudioObjectUnknown else {
    _ = AudioHardwareDestroyProcessTap(tapID)
    throw ProbeError.coreAudio(kAudioHardwareBadDeviceError, "Create Scarlett output meter device")
  }

  let destroyTap: () -> Void = {
    _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    _ = AudioHardwareDestroyProcessTap(tapID)
  }
  do {
    try streamInputSignals(
      channels: channels,
      intervalMilliseconds: intervalMilliseconds,
      deviceID: aggregateDeviceID,
      deviceName: "Scarlett 18i8 USB output tap",
      direction: .output,
      startDeviceAsynchronously: true,
      onTermination: destroyTap
    )
  } catch {
    destroyTap()
    throw error
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
    name == "Scarlett 18i8 USB"
  else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Sample-rate changes are enabled only for Scarlett 18i8 USB")
  }
  let supportedRanges = try readSampleRateRanges(audioDeviceID)
  guard
    supportedRanges.contains(where: { sampleRateHz >= $0.minimumHz && sampleRateHz <= $0.maximumHz }
    )
  else {
    throw ProbeError.coreAudio(
      kIOReturnBadArgument, "Requested rate is not reported as supported by the Scarlett")
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
    throw ProbeError.coreAudio(
      kAudioHardwareUnspecifiedError, "Scarlett sample rate is not settable")
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
    throw ProbeError.coreAudio(
      kAudioHardwareUnspecifiedError, "Scarlett sample-rate read-back did not match")
  }
  return actualRate
}

func collectAudioDevices() throws -> [AudioDeviceSnapshot] {
  let deviceIDs = try readDeviceIDs()

  return deviceIDs.map { deviceID in
    let name =
      (try? readString(deviceID, selector: kAudioObjectPropertyName)) ?? nil
      ?? "Unnamed device \(deviceID)"
    let manufacturer =
      (try? readString(deviceID, selector: kAudioObjectPropertyManufacturer)) ?? nil
      ?? "Unknown"
    let transport = (try? readUInt32(deviceID, selector: kAudioDevicePropertyTransportType))
      .map(transportName)
    let inputChannels = (try? readChannelCount(deviceID, scope: kAudioObjectPropertyScopeInput))
    let outputChannels = (try? readChannelCount(deviceID, scope: kAudioObjectPropertyScopeOutput))
    let sampleRate = try? readSampleRate(deviceID)
    let isScarlett = name.localizedCaseInsensitiveContains("Scarlett")
    let currentClockSourceID = try? readUInt32(deviceID, selector: kAudioDevicePropertyClockSource)
    let currentClockSourceName =
      currentClockSourceID.flatMap { sourceID in
        try? readClockSourceName(deviceID, sourceID: sourceID)
      } ?? nil
    let supportedClockSourceIDs =
      (try? readUInt32Array(
        deviceID,
        selector: kAudioDevicePropertyClockSources,
        operation: "supported clock sources"
      )) ?? []
    let supportedClockSources = supportedClockSourceIDs.compactMap {
      sourceID -> ClockSourceSnapshot? in
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
