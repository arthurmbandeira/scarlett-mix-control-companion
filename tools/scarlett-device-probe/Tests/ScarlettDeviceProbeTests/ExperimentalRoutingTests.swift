import XCTest
@testable import ScarlettDeviceProbe

final class ExperimentalRoutingTests: XCTestCase {
  func testMonitorSourceWritesBothChannelsInOrder() throws {
    var channels: [Int] = []
    var sources: [UInt16] = []
    try setExperimentalMonitor12Source("daw12") { entity, selector, channel, value in
      XCTAssertEqual(entity, 0x33)
      XCTAssertEqual(selector, 0)
      channels.append(channel)
      sources.append(value)
    }
    XCTAssertEqual(channels, [0, 1])
    XCTAssertEqual(sources, [0, 1])
  }

  func testMonitorSourceRejectsInvalidSelectionWithoutWriting() {
    var written = false
    XCTAssertThrowsError(try setExperimentalMonitor12Source("daw34") { _, _, _, _ in
      written = true
    })
    XCTAssertFalse(written)
  }

  func testMonitorSourceReportsPartialWriteAndStops() {
    enum TestError: Error { case disconnected }
    var channels: [Int] = []
    XCTAssertThrowsError(try setExperimentalMonitor12Source("daw12") { _, _, channel, _ in
      channels.append(channel)
      if channel == 1 { throw TestError.disconnected }
    }) { error in
      guard case ProbeError.routingWriteFailed(let completed, _) = error else {
        return XCTFail("Expected partial routing error, got \(error)")
      }
      XCTAssertEqual(completed, 1)
    }
    XCTAssertEqual(channels, [0, 1])
  }

  func testHeadphonePresetsWriteBothChannelsInOrder() throws {
    let cases: [(Headphone01Preset, [UInt16])] = [
      (.clear, [0xffff, 0xffff]),
      (.dawTracking, [0, 1]),
      (.mixing, [2, 3]),
      (.mix1Left, [26, 1]),
    ]
    for (preset, expected) in cases {
      var channels: [Int] = []
      var sources: [UInt16] = []
      try setHeadphone01Preset(preset) { entity, selector, channel, value in
        XCTAssertEqual(entity, 0x33)
        XCTAssertEqual(selector, 0)
        channels.append(channel)
        sources.append(value)
      }
      XCTAssertEqual(channels, [2, 3])
      XCTAssertEqual(sources, expected)
    }
  }

  func testHeadphonePresetReportsPartialWriteAndStops() {
    enum TestError: Error { case disconnected }
    var channels: [Int] = []
    XCTAssertThrowsError(try setHeadphone01Preset(.dawTracking) { _, _, channel, _ in
      channels.append(channel)
      if channel == 3 { throw TestError.disconnected }
    }) { error in
      guard case ProbeError.routingWriteFailed(let completed, _) = error else {
        return XCTFail("Expected partial routing error, got \(error)")
      }
      XCTAssertEqual(completed, 1)
    }
    XCTAssertEqual(channels, [2, 3])
  }

  func testUnsupportedMixerSelectionsAreRejected() {
    XCTAssertThrowsError(try setExperimentalMixer18Source("daw1"))
    XCTAssertThrowsError(try setExperimentalMixer18Gain("0"))
    XCTAssertNil(Headphone01Preset(rawValue: "zero-latency"))
  }
}
