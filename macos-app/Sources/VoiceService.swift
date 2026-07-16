import AVFoundation
import CoreAudio
import Foundation
import Speech

@MainActor
final class VoiceService {
  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var tapInstalled = false
  private var latestTranscript = ""
  private var shouldCommit = false
  private var stopRequested = false
  private var recognitionEnded = false
  private var completionDelivered = false
  private var fallbackWorkItem: DispatchWorkItem?
  private var currentSession = UUID()
  private var onPartial: (@MainActor (String) -> Void)?
  private var onComplete: (@MainActor (String?, String?) -> Void)?

  var isListening: Bool { engine.isRunning }

  func start(
    deviceID: AudioDeviceID,
    localeIdentifier: String,
    onPartial: @escaping @MainActor (String) -> Void,
    onComplete: @escaping @MainActor (String?, String?) -> Void
  ) throws -> Double {
    cancelCurrent()
    let session = UUID()
    currentSession = session

    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
      throw VoiceError.unavailable("当前语言没有可用的语音识别器")
    }
    guard recognizer.isAvailable else {
      throw VoiceError.unavailable("语音识别服务当前不可用")
    }

    self.onPartial = onPartial
    self.onComplete = onComplete
    latestTranscript = ""
    shouldCommit = false
    stopRequested = false
    recognitionEnded = false
    completionDelivered = false

    let input = engine.inputNode
    try AudioInputCatalog.apply(deviceID, to: input)
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw VoiceError.unavailable("选择的麦克风没有有效音频格式")
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    self.request = request

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor [weak self] in
        guard let self, self.currentSession == session else { return }
        if let result {
          let text = result.bestTranscription.formattedString
          self.latestTranscript = text
          self.onPartial?(text)
          if result.isFinal {
            self.recognitionEnded = true
            if self.stopRequested { self.finish(error: nil, session: session) }
            return
          }
        }
        if let error {
          self.finish(error: error.localizedDescription, session: session)
        }
      }
    }

    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      request.append(buffer)
    }
    tapInstalled = true
    engine.prepare()
    do {
      try engine.start()
    } catch {
      if tapInstalled {
        input.removeTap(onBus: 0)
        tapInstalled = false
      }
      task?.cancel()
      task = nil
      self.request = nil
      throw error
    }
    return format.sampleRate
  }

  func stop(commit: Bool) {
    guard engine.isRunning || request != nil else { return }
    let session = currentSession
    shouldCommit = commit
    stopRequested = true
    engine.stop()
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    request?.endAudio()

    if !commit {
      finish(error: nil, session: session)
      return
    }

    if recognitionEnded {
      finish(error: nil, session: session)
      return
    }

    let fallback = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.finish(error: nil, session: session)
      }
    }
    fallbackWorkItem = fallback
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: fallback)
  }

  func cancelCurrent() {
    currentSession = UUID()
    fallbackWorkItem?.cancel()
    fallbackWorkItem = nil
    if engine.isRunning { engine.stop() }
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
    latestTranscript = ""
    shouldCommit = false
    stopRequested = false
    recognitionEnded = false
    completionDelivered = false
  }

  private func finish(error: String?, session: UUID) {
    guard currentSession == session, !completionDelivered else { return }
    completionDelivered = true
    currentSession = UUID()
    fallbackWorkItem?.cancel()
    fallbackWorkItem = nil
    if engine.isRunning { engine.stop() }
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil

    let text = shouldCommit && !latestTranscript.isEmpty ? latestTranscript : nil
    let callback = onComplete
    callback?(text, error)
  }
}

enum VoiceError: LocalizedError {
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let message): return message
    }
  }
}
