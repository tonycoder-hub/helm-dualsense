import Foundation

struct SDLHapticBackend: HapticBackend {
  func isAvailable() -> Bool {
    HelmSDLHasRumble()
  }

  func play(_ pulse: HapticPulse) -> Bool {
    HelmSDLRumble(
      pulse.lowFrequency,
      pulse.highFrequency,
      pulse.durationMilliseconds
    )
  }

  func stop() {
    HelmSDLStopRumble()
  }
}
