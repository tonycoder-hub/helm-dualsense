import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
  let id: AudioDeviceID
  let name: String
  let isDefault: Bool
}

enum AudioInputCatalog {
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
        isDefault: defaultID.map { identifier == $0 } ?? false
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
}

enum AudioInputError: LocalizedError {
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let message): return message
    }
  }
}
