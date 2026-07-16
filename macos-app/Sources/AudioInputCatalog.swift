import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum AudioInputTransport: String, Hashable {
  case builtIn
  case usb
  case bluetooth
  case bluetoothLE
  case virtual
  case continuity
  case other

  var mayInterruptPlayback: Bool {
    self == .bluetooth || self == .bluetoothLE
  }

  var label: String {
    switch self {
    case .builtIn: return "内置"
    case .usb: return "USB"
    case .bluetooth, .bluetoothLE: return "蓝牙"
    case .virtual: return "虚拟"
    case .continuity: return "连续互通"
    case .other: return "其他"
    }
  }
}

struct AudioInputDevice: Identifiable, Hashable {
  let id: AudioDeviceID
  let name: String
  let isDefault: Bool
  let transport: AudioInputTransport

  var mayInterruptPlayback: Bool { transport.mayInterruptPlayback }
}

struct AudioPlaybackProtectionPlan {
  let replacement: AudioInputDevice?
  let shouldStopCapture: Bool
}

enum AudioInputCatalog {
  static func preferredInput(
    from devices: [AudioInputDevice],
    protectPlayback: Bool
  ) -> AudioInputDevice? {
    guard protectPlayback else {
      return devices.first(where: \.isDefault) ?? devices.first
    }

    let safe = devices.filter { !$0.transport.mayInterruptPlayback }
    return safe.first(where: \.isDefault)
      ?? safe.first(where: { $0.transport == .builtIn })
      ?? safe.first(where: { $0.transport == .usb })
      ?? safe.first
  }

  static func playbackProtectionPlan(
    selected: AudioInputDevice,
    from devices: [AudioInputDevice],
    captureActive: Bool
  ) -> AudioPlaybackProtectionPlan? {
    guard selected.mayInterruptPlayback else { return nil }
    return AudioPlaybackProtectionPlan(
      replacement: preferredInput(from: devices, protectPlayback: true),
      shouldStopCapture: captureActive
    )
  }

  static func devices() -> [AudioInputDevice] {
    let defaultID = defaultInputDeviceID()
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size
      ) == noErr
    else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var identifiers = [AudioDeviceID](repeating: 0, count: count)
    let status = identifiers.withUnsafeMutableBytes { bytes in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size,
        bytes.baseAddress!
      )
    }
    guard status == noErr else { return [] }

    return identifiers.compactMap { identifier in
      guard hasInputStreams(identifier), let name = deviceName(identifier) else { return nil }
      return AudioInputDevice(
        id: identifier,
        name: name,
        isDefault: defaultID.map { identifier == $0 } ?? false,
        transport: transportType(identifier)
      )
    }
    .sorted {
      if $0.isDefault != $1.isDefault { return $0.isDefault }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  static func defaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var identifier = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &identifier
    )
    return status == noErr && identifier != 0 ? identifier : nil
  }

  static func apply(_ deviceID: AudioDeviceID, to inputNode: AVAudioInputNode) throws {
    guard let audioUnit = inputNode.audioUnit else {
      throw AudioInputError.unavailable("无法创建麦克风 Audio Unit")
    }
    var mutableID = deviceID
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &mutableID,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else {
      throw AudioInputError.unavailable("无法选择麦克风（CoreAudio \(status)）")
    }
  }

  private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
  }

  private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var unmanagedName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &unmanagedName) { pointer in
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let unmanagedName else { return nil }
    return unmanagedName.takeUnretainedValue() as String
  }

  private static func transportType(_ deviceID: AudioDeviceID) -> AudioInputTransport {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value = UInt32(kAudioDeviceTransportTypeUnknown)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
      return .other
    }

    switch value {
    case kAudioDeviceTransportTypeBuiltIn:
      return .builtIn
    case kAudioDeviceTransportTypeUSB:
      return .usb
    case kAudioDeviceTransportTypeBluetooth:
      return .bluetooth
    case kAudioDeviceTransportTypeBluetoothLE:
      return .bluetoothLE
    case kAudioDeviceTransportTypeVirtual:
      return .virtual
    case kAudioDeviceTransportTypeContinuityCaptureWired,
      kAudioDeviceTransportTypeContinuityCaptureWireless:
      return .continuity
    default:
      return .other
    }
  }
}

enum AudioInputError: LocalizedError {
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let message): return message
    }
  }
}
