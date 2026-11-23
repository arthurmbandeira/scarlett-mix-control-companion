import CoreAudio
import Foundation

enum ProbeError: Error, CustomStringConvertible {
  case coreAudio(OSStatus, String)
  case unexpectedDataSize(UInt32, Int)
  case routingWriteFailed(Int, String)

  var description: String {
    switch self {
    case .coreAudio(let status, let operation):
      return "\(operation) failed with CoreAudio status \(status)"
    case .unexpectedDataSize(let actual, let expected):
      return "CoreAudio returned \(actual) bytes; expected \(expected)"
    case .routingWriteFailed(let completed, let detail):
      return "Output routing stopped after \(completed) channel(s); earlier writes may have changed the device. \(detail)"
    }
  }
}

struct AudioDeviceSnapshot: Encodable {
  let deviceID: UInt32
  let name: String
  let manufacturer: String
  let transport: String?
  let inputChannels: Int?
  let outputChannels: Int?
  let sampleRateHz: Double?
  let supportedSampleRateRanges: [SampleRateRangeSnapshot]
  let currentClockSourceID: UInt32?
  let currentClockSourceName: String?
  let supportedClockSources: [ClockSourceSnapshot]
  let inputVolumeScalar: Float32?
  let outputVolumeScalar: Float32?
  let inputChannelVolumeScalars: [ChannelVolumeSnapshot]
  let outputChannelVolumeScalars: [ChannelVolumeSnapshot]
}

struct SampleRateRangeSnapshot: Encodable {
  let minimumHz: Double
  let maximumHz: Double
}

struct ClockSourceSnapshot: Encodable {
  let id: UInt32
  let name: String
}

struct USBDeviceSnapshot: Encodable {
  let productName: String
  let manufacturer: String
  let vendorID: UInt32?
  let productID: UInt32?
  let configurationDescriptorBytes: Int?
  let classSpecificAudioDescriptors: [String]
  let featureUnits: [FeatureUnitSnapshot]
}

struct FeatureUnitSnapshot: Encodable {
  let unitID: UInt8
  let sourceID: UInt8
  let controlSize: UInt8
  let volumeControlChannels: [Int]
}

struct USBInterfaceSnapshot: Encodable {
  let number: UInt32?
  let classCode: UInt32?
  let subclass: UInt32?
  let protocolCode: UInt32?
  let kind: String?
}

struct DeviceSnapshot: Encodable {
  let audioDevices: [AudioDeviceSnapshot]
  let usbDevices: [USBDeviceSnapshot]
  let usbInterfaces: [USBInterfaceSnapshot]
  let defaultInputDeviceName: String?
  let defaultOutputDeviceName: String?
}

struct ChannelVolumeSnapshot: Encodable {
  let element: Int
  let scalar: Float32
}

struct InputMeterSnapshot: Encodable {
  let device: String
  let channel: Int
  let durationMilliseconds: Int
  let sampleRateHz: Double
  let frames: UInt64
  let rms: Double
  let peak: Double
  let rmsDbFS: Double
  let peakDbFS: Double
}

enum MeterDirection: String, Encodable {
  case input
  case output
  case softwareMonitor = "software-monitor"
}

struct MeterStreamFrame: Encodable {
  let device: String
  let direction: MeterDirection
  let channel: Int
  let sampleRateHz: Double
  let frames: UInt64
  let rmsDbFS: Double
  let peakDbFS: Double
}

func check(_ status: OSStatus, operation: String) throws {
  guard status == noErr else {
    throw ProbeError.coreAudio(status, operation)
  }
}
