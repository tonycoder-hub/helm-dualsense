import AVFoundation
import AppKit
import Combine
import CoreAudio
import CoreGraphics
import Foundation
import OSLog
import Speech

private enum MotionDiagnostic {
  case rightStickY(Double)
  case leftStick(x: Double, y: Double)
  case triggers(left: Double, right: Double, multiplier: Double)
  case touchDelta(x: Double, y: Double)

  var label: String {
    switch self {
    case .rightStickY(let value):
      return String(format: "右摇杆 Y  %.2f", value)
    case .leftStick(let x, let y):
      return hypot(x, y) > ControlMath.stickDeadZone
        ? String(format: "左摇杆  %.2f, %.2f", x, y)
        : "左摇杆居中"
    case .triggers(let left, let right, let multiplier):
      return String(
        format: "L2 刹车 %.0f%% · R2 加速 %.0f%% · %.2f×",
        left * 100,
        right * 100,
        multiplier
      )
    case .touchDelta(let x, let y):
      return String(format: "触控板  Δ %.0f, %.0f", x, y)
    }
  }
}

@MainActor
final class AppModel: ObservableObject {
  private static let interfaceVoiceSource = UInt64.max

  @Published var controllerConnected = false
  @Published var controllerName = "未连接手柄"
  @Published var controllerFamily = ControllerFamily.generic
  @Published var connectionLabel = "—"
  @Published var microphoneButtonAvailable = false
  @Published var touchpadCount: Int32 = 0
  @Published var controlsEnabled = false
  @Published var autoEnableControlsOnLaunch = LaunchControlAutoEnablePolicy.defaultEnabled {
    didSet {
      UserDefaults.standard.set(
        autoEnableControlsOnLaunch,
        forKey: "autoEnableControlsOnLaunch"
      )
    }
  }
  @Published var accessibilityGranted = false
  @Published var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
  @Published var speechAuthorization = SFSpeechRecognizer.authorizationStatus()
  @Published var isListening = false
  @Published var voiceInputMode = VoiceInputMode.defaultMode {
    didSet {
      UserDefaults.standard.set(voiceInputMode.rawValue, forKey: "voiceInputMode")
      if started, voiceInputMode != oldValue {
        applyVoiceInputModeTransition(from: oldValue)
      }
    }
  }
  @Published var lastAudioSampleRate = 0.0
  @Published var transcript = "选择麦克风模式后说话，识别结果会显示在这里。"
  @Published var autoInsert = true {
    didSet { UserDefaults.standard.set(autoInsert, forKey: "autoInsert") }
  }
  @Published var localeIdentifier = "zh-CN"
  @Published var protectPlaybackAudio = true {
    didSet {
      UserDefaults.standard.set(protectPlaybackAudio, forKey: "protectPlaybackAudio")
      if started, protectPlaybackAudio { enforcePlaybackProtection(announce: true) }
    }
  }
  @Published var pointerGain = 1.0 {
    didSet {
      UserDefaults.standard.set(pointerGain, forKey: "pointerGain")
      if started { syncMotionConfiguration() }
    }
  }
  @Published var scrollGain = 8.0 {
    didSet {
      UserDefaults.standard.set(scrollGain, forKey: "scrollGain")
      if started { syncMotionConfiguration() }
    }
  }
  @Published var inputPollingRate = InputCadencePolicy.defaultRate {
    didSet {
      UserDefaults.standard.set(inputPollingRate, forKey: "inputPollingRate")
      if started { startCadence() }
    }
  }
  @Published var measuredInputRate = 0.0
  @Published var measuredDisplayRate = 0.0
  @Published var inputCadenceLabel = "240 Hz 主动采样"
  @Published var outputCadenceLabel = "显示同步"
  @Published var inputJitterLabel = "等待 5 秒节拍样本"
  @Published var stickResponseExponent = ControlMath.defaultStickResponseExponent {
    didSet {
      UserDefaults.standard.set(stickResponseExponent, forKey: "stickResponseExponent")
      if started { syncMotionConfiguration() }
    }
  }
  @Published var stickSmoothingMilliseconds = ControlMath.defaultStickSmoothingTime * 1_000 {
    didSet {
      UserDefaults.standard.set(stickSmoothingMilliseconds, forKey: "stickSmoothingMilliseconds")
      if started { syncMotionConfiguration() }
    }
  }
  @Published var stickAccelerationDuration = 1.6 {
    didSet {
      UserDefaults.standard.set(stickAccelerationDuration, forKey: "stickAccelerationDuration")
      if started { syncMotionConfiguration() }
    }
  }
  @Published var stickMaximumBoost = 2.2 {
    didSet {
      UserDefaults.standard.set(stickMaximumBoost, forKey: "stickMaximumBoost")
      if started { syncMotionConfiguration() }
    }
  }
  @Published var brakeMinimumSpeed = 0.28 {
    didSet {
      UserDefaults.standard.set(brakeMinimumSpeed, forKey: "brakeMinimumSpeed")
      if started { syncMotionConfiguration() }
    }
  }
  @Published var acceleratorMaximumSpeed = 2.6 {
    didSet {
      UserDefaults.standard.set(acceleratorMaximumSpeed, forKey: "acceleratorMaximumSpeed")
      if started { syncMotionConfiguration() }
    }
  }
  @Published var hapticsEnabled = HapticFeedbackPolicy.defaultEnabled {
    didSet {
      UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled")
      if started, !hapticsEnabled { hapticCoordinator.stop(backend: hapticBackend) }
    }
  }
  @Published var hapticIntensity = HapticFeedbackPolicy.defaultIntensity {
    didSet { UserDefaults.standard.set(hapticIntensity, forKey: "hapticIntensity") }
  }
  @Published var hapticsAvailable = false
  @Published var leftTriggerValue = 0.0
  @Published var rightTriggerValue = 0.0
  @Published var mapping = ControllerMapping.standard {
    didSet {
      if mapping != oldValue { mappingDidChange() }
    }
  }
  @Published var shortcutSettings = ControllerShortcutSettings.standard {
    didSet {
      if shortcutSettings != oldValue { shortcutSettingsDidChange() }
    }
  }
  @Published var latestInput = "等待手柄连接"
  @Published var statusMessage = "GripPilot 已就绪；桌面控制和麦克风模式可以分别配置。"
  @Published var activity: [String] = []
  @Published var audioDevices: [AudioInputDevice] = []
  @Published var selectedAudioDeviceID = AudioDeviceID(0)
  @Published var isRecordingMapping = false
  @Published var mappingCapturePrompt = ""
  @Published var pendingMappingAction = ControllerAction.primaryClick

  private let voice = VoiceService()
  private let updateController = HelmUpdateController()
  private let eventCadenceDriver = MainEventCadenceDriver()
  private let motionSamplingDriver = MotionSamplingDriver(
    analogReader: {
      var analog = HelmSDLAnalogState()
      guard HelmSDLReadAnalogState(&analog) else { return nil }
      return ControllerAnalogSample(
        leftX: Double(analog.left_x),
        leftY: Double(analog.left_y),
        rightY: Double(analog.right_y),
        leftTrigger: Double(analog.left_trigger),
        rightTrigger: Double(analog.right_trigger)
      )
    },
    pointerOutput: { delta, leftButtonDown, rightButtonDown in
      InputInjector.movePointer(
        dx: delta.x,
        dy: delta.y,
        leftButtonDown: leftButtonDown,
        rightButtonDown: rightButtonDown
      )
    },
    scrollOutput: { sample in
      InputInjector.scroll(sample: sample)
    }
  )
  private let permissionLogger = Logger(
    subsystem: "io.github.tonycoder-hub.helm",
    category: "permissions"
  )
  private let voiceDeliveryLogger = Logger(
    subsystem: "io.github.tonycoder-hub.helm",
    category: "voice-delivery"
  )
  private let motionCadenceLogger = Logger(
    subsystem: "io.github.tonycoder-hub.helm",
    category: "motion-cadence"
  )
  private var terminationObserver: NSObjectProtocol?
  private var workspaceActivationObserver: NSObjectProtocol?
  private var started = false
  private var nextPermissionRefresh = 0.0
  private var nextAudioRefresh = 0.0
  private var nextDiagnosticsRefresh = 0.0
  private var nextMotionCadenceLog = 0.0
  private var analogState = ControllerAnalogState()
  private var lastTouch: CGPoint?
  private var lastTouchTime: TimeInterval?
  private var leftMouseDown = false
  private var rightMouseDown = false
  private var leftMouseSources = Set<UInt64>()
  private var rightMouseSources = Set<UInt64>()
  private var pushToTalkSources = Set<UInt64>()
  private var pendingLatestInput = "等待手柄连接"
  private var pendingMotionDiagnostic: MotionDiagnostic?
  private var audioSelectionInitialized = false
  private var audioRefreshGate = AudioRefreshGate()
  private var activeVoiceAudioDevice: AudioInputDevice?
  private var voiceFinalizing = false
  private var alwaysOnSegmentWorkItem: DispatchWorkItem?
  private var alwaysOnRestartWorkItem: DispatchWorkItem?
  private var alwaysOnRestartPending = false
  private var focusHistory = ExternalFocusHistory()
  private var voiceTestFinishing = false
  private var suppressAutoInsertForCurrentVoice = false
  private var voiceTestGeneration = VoiceTestSessionGeneration()
  private var activeVoiceTestToken: UInt64?
  private var voiceDeliveryGeneration = VoiceTestSessionGeneration()
  private var activeVoiceDeliveryToken: UInt64?
  private var voiceInsertionTarget: Int32?
  private var voiceInsertionProcessIdentity: ExternalProcessIdentity?
  private var voiceInsertionFocusSnapshot: ExternalTextFocusSnapshot?
  private var lastCompletedTranscript: String?
  private var manualDeliveryActivationBaseline: UInt64?
  private let hapticBackend = SDLHapticBackend()
  private var hapticCoordinator = HapticCoordinator(minimumInterval: 0.055)
  private var bindingResolver = ControllerBindingResolver()
  private var modifierHoldCoordinator = ModifierHoldCoordinator()
  private var chordRecorder = ControllerChordRecorder()
  private var safetyChordTracker = SafetyChordTracker()
  private var mappingCaptureOriginalChord: ControllerChord?
  private var controllerIdentity: ControllerIdentity?
  private var controllerConnection = ControllerConnection.unknown
  private var pendingReconnectIdentity: ControllerIdentity?
  private var pendingReconnectWorkItem: DispatchWorkItem?
  private var launchAutoEnableGate = LaunchControlAutoEnableGate(
    settingEnabled: false,
    controllerAlreadyConnected: false
  )
  private var latencyActivity: NSObjectProtocol?
  private var permissionDiagnosticTracker = PermissionDiagnosticTracker()

  init() {
    let defaults = UserDefaults.standard
    if let value = defaults.object(forKey: "pointerGain") as? Double {
      pointerGain = min(max(value, 0.45), 2.2)
    }
    if let value = defaults.object(forKey: "scrollGain") as? Double {
      scrollGain = min(max(value, 2), 18)
    }
    if let value = defaults.object(forKey: "inputPollingRate") as? Double {
      inputPollingRate = InputCadencePolicy.clampedRate(value)
    }
    if let value = defaults.object(forKey: "stickResponseExponent") as? Double {
      stickResponseExponent = min(max(value, 0.7), 2.4)
    }
    if let value = defaults.object(forKey: "stickSmoothingMilliseconds") as? Double {
      stickSmoothingMilliseconds = min(max(value, 0), 60)
    }
    if let value = defaults.object(forKey: "stickAccelerationDuration") as? Double {
      stickAccelerationDuration = min(max(value, 0.4), 3.5)
    }
    if let value = defaults.object(forKey: "stickMaximumBoost") as? Double {
      stickMaximumBoost = min(max(value, 1), 3)
    }
    if let value = defaults.object(forKey: "brakeMinimumSpeed") as? Double {
      brakeMinimumSpeed = min(max(value, 0.1), 1)
    }
    if let value = defaults.object(forKey: "acceleratorMaximumSpeed") as? Double {
      acceleratorMaximumSpeed = min(max(value, 1), 4)
    }
    if defaults.object(forKey: "hapticsEnabled") != nil {
      hapticsEnabled = defaults.bool(forKey: "hapticsEnabled")
    }
    if let value = defaults.object(forKey: "hapticIntensity") as? Double {
      hapticIntensity = min(max(value, 0.2), 1)
    }
    if defaults.object(forKey: "protectPlaybackAudio") != nil {
      protectPlaybackAudio = defaults.bool(forKey: "protectPlaybackAudio")
    }
    if defaults.object(forKey: "autoInsert") != nil {
      autoInsert = defaults.bool(forKey: "autoInsert")
    }
    if let rawMode = defaults.string(forKey: "voiceInputMode"),
      let storedMode = VoiceInputMode(rawValue: rawMode)
    {
      voiceInputMode = storedMode
    }
    if defaults.object(forKey: "autoEnableControlsOnLaunch") != nil {
      autoEnableControlsOnLaunch = defaults.bool(forKey: "autoEnableControlsOnLaunch")
    }
    if let data = defaults.data(forKey: "controllerMapping"),
      let decoded = try? JSONDecoder().decode(ControllerMapping.self, from: data)
    {
      mapping = decoded
    }
    if let data = defaults.data(forKey: "controllerShortcutSettings"),
      let decoded = try? JSONDecoder().decode(ControllerShortcutSettings.self, from: data)
    {
      shortcutSettings = decoded
    }
    motionSamplingDriver.setTelemetryHandler(queue: .main) { [weak self] telemetry in
      MainActor.assumeIsolated {
        self?.applyMotionTelemetry(telemetry)
      }
    }
  }

  var selectedAudioDeviceName: String {
    audioDevices.first(where: { $0.id == selectedAudioDeviceID })?.name ?? "未选择麦克风"
  }

  var selectedAudioDevice: AudioInputDevice? {
    audioDevices.first(where: { $0.id == selectedAudioDeviceID })
  }

  var canEnable: Bool {
    controllerConnected && accessibilityGranted
  }

  var voicePermissionsGranted: Bool {
    microphoneAuthorization == .authorized && speechAuthorization == .authorized
  }

  var currentRacingSpeedMultiplier: Double {
    ControlMath.racingSpeedMultiplier(
      brake: analogState.leftTrigger,
      accelerator: analogState.rightTrigger,
      minimumSpeed: brakeMinimumSpeed,
      maximumSpeed: acceleratorMaximumSpeed
    )
  }

  var hapticCapabilityLabel: String {
    guard controllerConnected else { return "等待连接手柄" }
    return hapticsAvailable ? "SDL 已报告整机震动能力" : "当前连接未报告震动能力"
  }

  var updateChannelLabel: String {
    updateController.isConfigured ? "签名更新通道已配置" : "Demo 未配置正式更新通道"
  }

  var canCheckForUpdates: Bool {
    updateController.isConfigured
  }

  var microphonePermissionLabel: String {
    switch microphoneAuthorization {
    case .authorized: return "已授权"
    case .denied: return "已拒绝"
    case .restricted: return "受限"
    case .notDetermined: return "未请求"
    @unknown default: return "未知"
    }
  }

  var speechPermissionLabel: String {
    switch speechAuthorization {
    case .authorized: return "已授权"
    case .denied: return "已拒绝"
    case .restricted: return "受限"
    case .notDetermined: return "未请求"
    @unknown default: return "未知"
    }
  }

  func start() {
    guard !started else { return }
    started = true
    refreshEnvironment(forceAudio: true)

    var errorBuffer = [CChar](repeating: 0, count: 512)
    let ok = errorBuffer.withUnsafeMutableBufferPointer { buffer in
      HelmSDLStart(buffer.baseAddress, Int32(buffer.count))
    }
    if !ok {
      let message = String(cString: errorBuffer)
      setStatus("SDL3 启动失败：\(message)", log: true)
    } else {
      appendActivity("SDL3 3.4.12 事件层已启动")
    }

    var launchAnalogState = HelmSDLAnalogState()
    let controllerAlreadyConnected = ok
      && HelmSDLReadAnalogState(&launchAnalogState)
      && launchAnalogState.connected != 0
    launchAutoEnableGate = LaunchControlAutoEnableGate(
      settingEnabled: autoEnableControlsOnLaunch,
      controllerAlreadyConnected: controllerAlreadyConnected
    )

    startCadence()

    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.shutdown()
      }
    }

    if let application = NSWorkspace.shared.frontmostApplication {
      recordApplicationActivation(application)
    }
    workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        guard
          let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else { return }
        self?.recordApplicationActivation(application)
      }
    }
  }

  func toggleControls() {
    toggleControls(promptForAccessibility: true)
  }

  private func toggleControls(promptForAccessibility: Bool) {
    if controlsEnabled {
      emergencyStop(reason: "用户停用")
      return
    }
    guard controllerConnected else {
      setStatus("请先用 USB-C 或蓝牙连接 DualSense。", log: true)
      return
    }
    refreshPermissionState()
    guard accessibilityGranted else {
      if promptForAccessibility {
        _ = InputInjector.accessibilityTrusted(prompt: true)
        setStatus("请在系统设置中允许 GripPilot 使用辅助功能，然后再次启用。", log: true)
      } else {
        setStatus("请先从 GripPilot 界面请求辅助功能权限，再使用手柄启用控制。", log: true)
      }
      return
    }
    controlsEnabled = true
    resetMotionState()
    InputInjector.beginPointerSession()
    syncMotionConfiguration()
    updateLatencyActivity()
    setStatus("控制已启用。固定安全组合键可随时紧急停止。", log: true)
    playHaptic(.controlEnabled)
  }

  func requestAccessibility() {
    refreshPermissionState()
    switch PermissionRequestActionPolicy.accessibility(isTrusted: accessibilityGranted) {
    case .requestAccessibility:
      let granted = InputInjector.accessibilityTrusted(prompt: true)
      refreshPermissionState()
      if granted {
        setStatus("辅助功能已经授权。", log: true)
      } else {
        let opened = InputInjector.openAccessibilitySettings()
        setStatus(
          opened
            ? "已打开辅助功能设置；勾选 GripPilot 后返回并点“刷新”。"
            : "无法自动打开辅助功能设置，请在系统设置的“隐私与安全性”中手动打开。",
          log: true
        )
      }
    case .openAccessibilitySettings:
      let opened = InputInjector.openAccessibilitySettings()
      setStatus(
        opened
          ? "辅助功能已授权；已打开系统设置，可在这里管理或重新授权。"
          : "辅助功能已授权，但无法自动打开系统设置。",
        log: true
      )
    default:
      preconditionFailure("Unexpected accessibility permission action")
    }
  }

  func requestVoicePermissions() {
    refreshPermissionState()
    let action = PermissionRequestActionPolicy.voice(
      microphone: permissionGrantState(microphoneAuthorization),
      speech: permissionGrantState(speechAuthorization)
    )
    switch action {
    case .requestMicrophone:
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
        Task { @MainActor in
          self?.refreshPermissionState()
          self?.requestSpeechPermissionIfNeeded()
        }
      }
      setStatus("正在按顺序请求麦克风与语音识别权限。", log: true)
    case .requestSpeech:
      requestSpeechPermissionIfNeeded()
      setStatus("正在请求语音识别权限。", log: true)
    case .openMicrophoneSettings:
      startAlwaysOnAfterPermissionGrantIfNeeded()
      let opened = InputInjector.openMicrophoneSettings()
      setStatus(
        opened
          ? "已打开麦克风权限设置；可在这里管理或重新授权 GripPilot。"
          : "无法自动打开麦克风权限设置，请在系统设置的“隐私与安全性”中手动打开。",
        log: true
      )
    case .openSpeechSettings:
      let opened = InputInjector.openSpeechRecognitionSettings()
      setStatus(
        opened
          ? "已打开语音识别权限设置；授权 GripPilot 后返回并点“刷新”。"
          : "无法自动打开语音识别权限设置，请在系统设置的“隐私与安全性”中手动打开。",
        log: true
      )
    default:
      preconditionFailure("Unexpected voice permission action")
    }
  }

  func refreshEnvironment(forceAudio: Bool = true) {
    refreshPermissionState()
    if forceAudio { refreshAudioDevices() }
  }

  func beginVoiceTest() {
    guard voiceInputMode == .pushToTalk else {
      setStatus("界面按住测试仅在按键模式可用。", log: true)
      return
    }
    activeVoiceTestToken = voiceTestGeneration.begin()
    voiceTestFinishing = false
    updatePushToTalkSource(
      Self.interfaceVoiceSource,
      pressed: true,
      commitOnRelease: true,
      label: "界面测试"
    )
  }

  func endVoiceTest() {
    guard pushToTalkSources.contains(Self.interfaceVoiceSource),
      let token = activeVoiceTestToken, voiceTestGeneration.accepts(token)
    else { return }
    guard let target = restoreExternalFocusForVoiceTest() else {
      invalidateVoiceTestSession()
      suppressAutoInsertForCurrentVoice = true
      updatePushToTalkSource(
        Self.interfaceVoiceSource,
        pressed: false,
        commitOnRelease: true,
        label: "界面测试"
      )
      setStatus("未找到可恢复的外部文本焦点；识别结果只会保留在 GripPilot 中。", log: true)
      return
    }
    voiceTestFinishing = true
    finishVoiceTestAfterFocusRestoration(
      target: target,
      token: token,
      attemptsRemaining: 12
    )
  }

  func cancelVoiceTest() {
    guard !voiceTestFinishing,
      pushToTalkSources.contains(Self.interfaceVoiceSource)
    else { return }
    invalidateVoiceTestSession()
    updatePushToTalkSource(
      Self.interfaceVoiceSource,
      pressed: false,
      commitOnRelease: false,
      label: "界面测试中断"
    )
  }

  func clearTranscript() {
    transcript = ""
    lastCompletedTranscript = nil
    manualDeliveryActivationBaseline = nil
  }

  var canRetryExternalTextDelivery: Bool {
    VoiceManualDeliveryPolicy.deliverableText(
      lastCompletedTranscript,
      isListening: isListening,
      isFinalizing: voiceFinalizing,
      deliveryInProgress: activeVoiceDeliveryToken != nil
    ) != nil
  }

  func retryExternalTextDelivery() {
    guard
      let text = VoiceManualDeliveryPolicy.deliverableText(
        lastCompletedTranscript,
        isListening: isListening,
        isFinalizing: voiceFinalizing,
        deliveryInProgress: activeVoiceDeliveryToken != nil
      )
    else {
      setStatus("当前没有已完成且可重新发送的识别文本。", log: true)
      return
    }

    guard
      let activationBaseline = manualDeliveryActivationBaseline,
      let targetIdentity = focusHistory.manualRetryTarget(after: activationBaseline)
    else {
      setStatus("请在识别完成后重新聚焦外部文本框，再返回 GripPilot 发送。", log: true)
      return
    }

    invalidateVoiceTextDelivery()
    manualDeliveryActivationBaseline = focusHistory.activationGeneration
    voiceInsertionTarget = targetIdentity.processIdentifier
    voiceInsertionProcessIdentity = targetIdentity
    voiceInsertionFocusSnapshot = InputInjector.captureExternalTextFocus(
      processIdentifier: targetIdentity.processIdentifier,
      allowsApplicationFallback: true
    )
    let token = voiceDeliveryGeneration.begin()
    activeVoiceDeliveryToken = token
    setStatus("正在把已识别文本重新发送到上一个外部焦点…", log: true)
    deliverRecognizedText(text, token: token, attemptsRemaining: 12)
  }

  func testHaptics() {
    guard controllerConnected else {
      setStatus("请先连接 DualSense，再测试震动。", log: true)
      return
    }
    hapticsAvailable = hapticBackend.isAvailable()
    guard hapticsEnabled else {
      setStatus("请先开启操作震动。", log: true)
      return
    }
    guard hapticsAvailable else {
      setStatus("SDL 未报告当前连接支持整机震动；请稍后用 USB 与蓝牙分别验证。", log: true)
      return
    }
    if playHaptic(.preview, allowsDisabledControls: true) {
      setStatus("已发送一次 58ms 震动测试。", log: true)
    } else {
      setStatus("震动测试未发送；请稍后重试或重新连接手柄。", log: true)
    }
  }

  func checkForUpdates() {
    if updateController.checkForUpdates() {
      setStatus("正在通过签名更新通道检查新版本。", log: true)
    } else {
      setStatus("当前 Demo 未配置正式更新通道；不会连接占位 feed。", log: true)
    }
  }

  func restoreDefaultMappings() {
    mapping = .standard
    shortcutSettings = .standard
    setStatus("已恢复默认按键映射与快捷键。", log: true)
  }

  var safetyChordLabel: String {
    if controllerFamily == .playStation { return "Options + 触控板" }
    return "\(ControllerPresentation.label(for: .start, family: controllerFamily)) + \(ControllerPresentation.label(for: .back, family: controllerFamily))"
  }

  var controllerSystemImage: String {
    switch controllerFamily {
    case .playStation: return "playstation.logo"
    case .xbox: return "xbox.logo"
    case .nintendo, .generic: return "gamecontroller.fill"
    }
  }

  func setMappingAction(_ action: ControllerAction, for chord: ControllerChord) {
    var updated = mapping
    _ = updated.upsert(ControllerBinding(chord: chord, action: action))
    mapping = updated
  }

  func removeMapping(_ chord: ControllerChord) {
    var updated = mapping
    updated.remove(chord: chord)
    mapping = updated
  }

  func beginMappingCapture(replacing chord: ControllerChord? = nil) {
    guard !isRecordingMapping else { return }
    motionSamplingDriver.disableOutputAndWait()
    let voiceActive = VoiceSessionPolicy.isActiveForMappingCapture(
      isListening: isListening,
      isFinalizing: voiceFinalizing,
      deliveryInProgress: activeVoiceDeliveryToken != nil,
      restartPending: alwaysOnRestartPending,
      hasPressOwner: !pushToTalkSources.isEmpty
    )
    let plan = MappingCapturePolicy.begin(
      controlsEnabled: controlsEnabled,
      voiceActive: voiceActive,
      injectedInputActive: leftMouseDown || rightMouseDown
        || !leftMouseSources.isEmpty || !rightMouseSources.isEmpty
    )
    if plan.shouldStopVoice { stopVoiceForMappingCapture() }
    if plan.shouldReleaseInjectedInputs { releaseInjectedInputsPreservingControlSession() }
    controlsEnabled = plan.controlsEnabledAfterTransition
    mappingCaptureOriginalChord = chord
    chordRecorder.begin()
    isRecordingMapping = true
    syncMotionConfiguration()
    mappingCapturePrompt = chord == nil
      ? "请按住 1–4 个手柄键，再松开全部按键"
      : "请录入替代 \(chord!.label(family: controllerFamily)) 的新按键或组合键"
    setStatus("映射录入已开始；控制连接保持，录入期间暂不注入桌面动作。", log: true)
  }

  func cancelMappingCapture() {
    guard isRecordingMapping else { return }
    cancelMappingCaptureState()
    setStatus("已取消按键映射录入。", log: true)
  }

  func openAccessibilitySettings() {
    InputInjector.openAccessibilitySettings()
  }

  func openSoundSettings() {
    InputInjector.openSoundSettings()
  }

  func shutdown() {
    eventCadenceDriver.stop()
    motionSamplingDriver.stop()
    emergencyStop(reason: "应用退出")
    HelmSDLStop()
    if let terminationObserver {
      NotificationCenter.default.removeObserver(terminationObserver)
      self.terminationObserver = nil
    }
    if let workspaceActivationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
      self.workspaceActivationObserver = nil
    }
  }

  private func startCadence() {
    measuredInputRate = 0
    measuredDisplayRate = 0
    inputJitterLabel = "等待 5 秒独立节拍样本"
    let now = ProcessInfo.processInfo.systemUptime
    nextPermissionRefresh = now + 1
    nextAudioRefresh = now + 3
    nextDiagnosticsRefresh = now
    syncMotionConfiguration()
    inputCadenceLabel = motionSamplingDriver.start(rate: inputPollingRate)
    let eventLabel = eventCadenceDriver.start(rate: 60) { [weak self] in
      self?.eventTick()
    }
    outputCadenceLabel = "240 Hz 独立队列直接输出"
    appendActivity("输入节拍：\(inputCadenceLabel)；\(eventLabel)")
  }

  private func requestSpeechPermissionIfNeeded() {
    guard speechAuthorization == .notDetermined else {
      refreshPermissionState()
      startAlwaysOnAfterPermissionGrantIfNeeded()
      return
    }
    SFSpeechRecognizer.requestAuthorization { [weak self] _ in
      Task { @MainActor in
        self?.refreshPermissionState()
        self?.startAlwaysOnAfterPermissionGrantIfNeeded()
      }
    }
  }

  private func permissionGrantState(
    _ status: AVAuthorizationStatus
  ) -> PermissionGrantState {
    switch status {
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .restricted: return .restricted
    case .authorized: return .authorized
    @unknown default: return .restricted
    }
  }

  private func permissionGrantState(
    _ status: SFSpeechRecognizerAuthorizationStatus
  ) -> PermissionGrantState {
    switch status {
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .restricted: return .restricted
    case .authorized: return .authorized
    @unknown default: return .restricted
    }
  }

  private func startAlwaysOnAfterPermissionGrantIfNeeded() {
    guard voiceInputMode == .alwaysOn,
      voicePermissionsGranted,
      !isListening,
      !voiceFinalizing,
      activeVoiceDeliveryToken == nil
    else { return }
    beginVoice(source: "语音权限已就绪")
  }

  private func eventTick() {
    let now = ProcessInfo.processInfo.systemUptime
    var processed = 0
    var event = HelmSDLEvent()
    while processed < 512, HelmSDLPoll(&event) {
      handle(event, now: now)
      processed += 1
      event = HelmSDLEvent()
    }

    if now >= nextDiagnosticsRefresh {
      if let pendingMotionDiagnostic {
        pendingLatestInput = pendingMotionDiagnostic.label
        self.pendingMotionDiagnostic = nil
      }
      if latestInput != pendingLatestInput { latestInput = pendingLatestInput }
      if abs(leftTriggerValue - analogState.leftTrigger) >= 0.01 {
        leftTriggerValue = analogState.leftTrigger
      }
      if abs(rightTriggerValue - analogState.rightTrigger) >= 0.01 {
        rightTriggerValue = analogState.rightTrigger
      }
      nextDiagnosticsRefresh = now + 1.0 / 15.0
    }

    if now >= nextPermissionRefresh {
      refreshPermissionState()
      let hasMicrophoneButton = controllerConnected && HelmSDLHasMicrophoneButton()
      if microphoneButtonAvailable != hasMicrophoneButton {
        microphoneButtonAvailable = hasMicrophoneButton
      }
      let detectedTouchpadCount = controllerConnected ? HelmSDLTouchpadCount() : 0
      if touchpadCount != detectedTouchpadCount { touchpadCount = detectedTouchpadCount }
      let detectedHaptics = controllerConnected && hapticBackend.isAvailable()
      if hapticsAvailable != detectedHaptics { hapticsAvailable = detectedHaptics }
      nextPermissionRefresh = now + 1
    }
    if now >= nextAudioRefresh {
      refreshAudioDevices()
      nextAudioRefresh = now + 3
    }
    syncMotionConfiguration()
    updateLatencyActivity()
  }

  private func syncMotionConfiguration() {
    motionSamplingDriver.updateConfiguration(
      MotionSamplingConfiguration(
        outputEnabled: controllerConnected && controlsEnabled && accessibilityGranted
          && !isRecordingMapping,
        leftButtonDown: leftMouseDown,
        rightButtonDown: rightMouseDown,
        pointerGain: pointerGain,
        scrollGain: scrollGain,
        responseExponent: stickResponseExponent,
        responseTime: stickSmoothingMilliseconds / 1_000,
        accelerationDuration: stickAccelerationDuration,
        maximumBoost: stickMaximumBoost,
        brakeMinimumSpeed: brakeMinimumSpeed,
        acceleratorMaximumSpeed: acceleratorMaximumSpeed
      )
    )
  }

  private func applyMotionTelemetry(_ telemetry: MotionSamplingTelemetry) {
    if telemetry.emergencyStopRequested, controlsEnabled {
      emergencyStop(reason: "检测到系统睡眠/独立采样超长间隔")
      return
    }

    let roundedInputRate = Double(Int(telemetry.inputRate.rounded()))
    let roundedOutputRate = Double(Int(telemetry.outputRate.rounded()))
    if measuredInputRate != roundedInputRate { measuredInputRate = roundedInputRate }
    if measuredDisplayRate != roundedOutputRate { measuredDisplayRate = roundedOutputRate }
    if telemetry.jitterMaximumMilliseconds > 0 {
      let label = String(
        format: "p95 %.1f ms · 最大 %.1f ms · 延迟 %.1f%%",
        telemetry.jitterP95Milliseconds,
        telemetry.jitterMaximumMilliseconds,
        telemetry.lateTickPercentage
      )
      if inputJitterLabel != label { inputJitterLabel = label }
    }
    let now = ProcessInfo.processInfo.systemUptime
    if roundedInputRate > 0, now >= nextMotionCadenceLog {
      motionCadenceLogger.info(
        "cadence input=\(roundedInputRate, privacy: .public) output=\(roundedOutputRate, privacy: .public) enabled=\(self.controlsEnabled, privacy: .public)"
      )
      nextMotionCadenceLog = now + 5
    }

    analogState = telemetry.analogState
    if hypot(analogState.leftX, analogState.leftY) > ControlMath.stickDeadZone {
      pendingMotionDiagnostic = .leftStick(x: analogState.leftX, y: analogState.leftY)
    } else if abs(analogState.rightY) > ControlMath.scrollStickDeadZone {
      pendingMotionDiagnostic = .rightStickY(analogState.rightY)
    } else if analogState.leftTrigger > 0.01 || analogState.rightTrigger > 0.01 {
      pendingMotionDiagnostic = .triggers(
        left: analogState.leftTrigger,
        right: analogState.rightTrigger,
        multiplier: currentRacingSpeedMultiplier
      )
    }
  }

  private func handle(_ sourceEvent: HelmSDLEvent, now: TimeInterval) {
    var event = sourceEvent
    switch event.kind {
    case Int32(HELM_SDL_EVENT_CONNECTED):
      handleControllerConnected(event: &event)

    case Int32(HELM_SDL_EVENT_DISCONNECTED):
      handleControllerDisconnected(event: event)

    case Int32(HELM_SDL_EVENT_BUTTON):
      handleButton(event.button, pressed: event.pressed != 0, now: now)

    case Int32(HELM_SDL_EVENT_RIGHT_Y):
      analogState.rightY = Double(event.value)
      if abs(analogState.rightY) > ControlMath.scrollStickDeadZone {
        pendingMotionDiagnostic = .rightStickY(analogState.rightY)
      }

    case Int32(HELM_SDL_EVENT_LEFT_STICK):
      analogState.leftX = Double(event.x)
      analogState.leftY = Double(event.y)
      pendingMotionDiagnostic = .leftStick(x: analogState.leftX, y: analogState.leftY)

    case Int32(HELM_SDL_EVENT_TRIGGERS):
      analogState.leftTrigger = min(max(Double(event.x), 0), 1)
      analogState.rightTrigger = min(max(Double(event.y), 0), 1)
      pendingMotionDiagnostic = .triggers(
        left: analogState.leftTrigger,
        right: analogState.rightTrigger,
        multiplier: currentRacingSpeedMultiplier
      )

    case Int32(HELM_SDL_EVENT_TOUCH_DOWN):
      if event.finger == 0 {
        lastTouch = CGPoint(x: Double(event.x), y: Double(event.y))
        lastTouchTime = now
        queueLatestInput("触控板按下")
      }

    case Int32(HELM_SDL_EVENT_TOUCH_MOVE):
      handleTouchMove(event, now: now)

    case Int32(HELM_SDL_EVENT_TOUCH_UP):
      if event.finger == 0 {
        lastTouch = nil
        lastTouchTime = nil
        queueLatestInput("触控板抬起")
      }

    case Int32(HELM_SDL_EVENT_ERROR):
      setStatus("SDL3：\(bridgeString(&event))", log: true)

    default:
      break
    }
  }

  private func handleButton(_ button: Int32, pressed: Bool, now: TimeInterval) {
    guard let controllerButton = ControllerButton(rawValue: button) else { return }
    let buttonLabel = ControllerPresentation.label(for: controllerButton, family: controllerFamily)
    queueLatestInput("\(buttonLabel) \(pressed ? "按下" : "抬起")")

    if isRecordingMapping {
      mappingCapturePrompt = pressed ? "已按下 \(buttonLabel)，松开全部按键完成" : "正在等待全部按键松开"
      if let chord = chordRecorder.process(button: controllerButton, pressed: pressed) {
        completeMappingCapture(with: chord)
      }
      return
    }

    if safetyChordTracker.process(
      button: controllerButton,
      pressed: pressed,
      family: controllerFamily,
      now: now
    ) {
      if controlsEnabled || isListening || voiceFinalizing || leftMouseDown || rightMouseDown
        || !pushToTalkSources.isEmpty
      {
        emergencyStop(reason: "固定安全组合键")
      } else {
        setStatus("控制已经处于安全停用状态。", log: true)
      }
      return
    }

    let transitions = bindingResolver.process(
      button: controllerButton,
      pressed: pressed,
      mapping: mapping
    )
    for transition in transitions {
      handleMappedButton(
        transition.chord.sourceID,
        label: transition.chord.label(family: controllerFamily),
        action: transition.action,
        pressed: transition.pressed
      )
    }
  }

  private func handleMappedButton(
    _ source: UInt64,
    label: String,
    action: ControllerAction,
    pressed: Bool
  ) {
    queueLatestInput("\(label) \(pressed ? "按下" : "抬起") → \(action.title)")
    if action.requiresDesktopControls {
      guard controlsEnabled else { return }
    }

    switch action {
    case .none:
      break
    case .primaryClick:
      guard accessibilityGranted else { return }
      if pressed { leftMouseSources.insert(source) } else { leftMouseSources.remove(source) }
      let nextState = !leftMouseSources.isEmpty
      if nextState != leftMouseDown {
        leftMouseDown = nextState
        InputInjector.mouseButton(.left, pressed: nextState)
        syncMotionConfiguration()
        if nextState { playHaptic(.primaryAction) }
      }
    case .secondaryClick:
      guard accessibilityGranted else { return }
      if pressed { rightMouseSources.insert(source) } else { rightMouseSources.remove(source) }
      let nextState = !rightMouseSources.isEmpty
      if nextState != rightMouseDown {
        rightMouseDown = nextState
        InputInjector.mouseButton(.right, pressed: nextState)
        syncMotionConfiguration()
        if nextState { playHaptic(.secondaryAction) }
      }
    case .pageUp:
      if pressed, accessibilityGranted {
        InputInjector.page(direction: 1)
        playHaptic(.navigation)
      }
    case .pageDown:
      if pressed, accessibilityGranted {
        InputInjector.page(direction: -1)
        playHaptic(.navigation)
      }
    case .pushToTalk:
      guard controllerConnected else { return }
      updatePushToTalkSource(
        source,
        pressed: pressed,
        commitOnRelease: true,
        label: label
      )
    case .shortcut1:
      performShortcut(
        .shortcut1,
        shortcut: shortcutSettings.slot1,
        sourceID: source,
        sourceLabel: label,
        pressed: pressed
      )
    case .shortcut2:
      performShortcut(
        .shortcut2,
        shortcut: shortcutSettings.slot2,
        sourceID: source,
        sourceLabel: label,
        pressed: pressed
      )
    case .shortcut3:
      performShortcut(
        .shortcut3,
        shortcut: shortcutSettings.slot3,
        sourceID: source,
        sourceLabel: label,
        pressed: pressed
      )
    }
  }

  private func performShortcut(
    _ action: ControllerAction,
    shortcut: KeyboardShortcutDefinition,
    sourceID: UInt64,
    sourceLabel: String,
    pressed: Bool
  ) {
    if shortcut.isModifierOnly {
      let slot: Int
      switch action {
      case .shortcut1: slot = 1
      case .shortcut2: slot = 2
      case .shortcut3: slot = 3
      default: return
      }
      var nextCoordinator = modifierHoldCoordinator
      let transitions = nextCoordinator.update(
        slot: slot,
        source: sourceID,
        modifierCodes: shortcut.modifierVirtualKeyCodes,
        pressed: pressed
      )
      if transitions.isEmpty {
        modifierHoldCoordinator = nextCoordinator
        return
      }
      if InputInjector.applyModifierKeyTransitions(transitions) {
        modifierHoldCoordinator = nextCoordinator
        if pressed {
          setStatus("正在按住 \(shortcut.label)（\(sourceLabel)）。", log: true)
          playHaptic(.shortcut)
        }
      } else {
        setStatus("修饰键被安全输入阻止或发送失败。", log: true)
      }
      return
    }

    guard pressed else { return }
    guard shortcut.key != nil else {
      setStatus("快捷键未设置：请选择一个按键或至少一个修饰键。", log: true)
      return
    }
    guard accessibilityGranted else {
      setStatus("快捷键需要辅助功能权限。", log: true)
      return
    }
    if InputInjector.sendShortcut(shortcut) {
      setStatus("已发送快捷键 \(shortcut.label)（\(sourceLabel)）。", log: true)
      playHaptic(.shortcut)
    } else {
      setStatus("快捷键被安全输入阻止或发送失败。", log: true)
    }
  }

  private func applyVoiceInputModeTransition(from previousMode: VoiceInputMode) {
    let action = VoiceInputModePolicy.transition(
      from: previousMode,
      to: voiceInputMode,
      isListening: isListening,
      isFinalizing: voiceFinalizing,
      deliveryInProgress: activeVoiceDeliveryToken != nil
    )
    cancelAlwaysOnAutomation()
    pushToTalkSources.removeAll()
    invalidateVoiceTestSession()

    switch action {
    case .none:
      let message = voiceInputMode == .alwaysOff
        ? "麦克风已常闭；不会响应语音按键。"
        : "麦克风已切换为按键模式。"
      setStatus(message, log: true)
    case .start:
      beginVoice(source: "常开模式")
    case .keepListening:
      scheduleAlwaysOnSegmentCompletion()
      setStatus("麦克风已切换为常开；当前语音会话保持运行。", log: true)
    case .stopAndCommit:
      endVoice(commit: true, source: "切换到按键模式")
    case .stopWithoutCommit:
      voice.cancelCurrent()
      isListening = false
      voiceFinalizing = false
      activeVoiceAudioDevice = nil
      invalidateVoiceTextDelivery()
      suppressAutoInsertForCurrentVoice = false
      updateLatencyActivity()
      setStatus("麦克风已常闭；当前采集和待投递文本已取消。", log: true)
    case .restartAfterCompletion:
      alwaysOnRestartPending = true
      restartAlwaysOnIfReady()
      setStatus("当前语音正在收尾；完成后会进入常开模式。", log: true)
    }
  }

  private func cancelAlwaysOnAutomation() {
    alwaysOnSegmentWorkItem?.cancel()
    alwaysOnSegmentWorkItem = nil
    alwaysOnRestartWorkItem?.cancel()
    alwaysOnRestartWorkItem = nil
    alwaysOnRestartPending = false
  }

  private func scheduleAlwaysOnSegmentCompletion() {
    alwaysOnSegmentWorkItem?.cancel()
    guard voiceInputMode == .alwaysOn, isListening else {
      alwaysOnSegmentWorkItem = nil
      return
    }
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.voiceInputMode == .alwaysOn, self.isListening else { return }
        self.setStatus("常开语音正在提交当前分段…", log: true)
        self.endVoice(commit: true, source: "常开分段")
      }
    }
    alwaysOnSegmentWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + VoiceInputModePolicy.maximumSegmentDuration,
      execute: workItem
    )
  }

  private func completeVoiceDelivery(outcome: VoiceCompletionOutcome) {
    invalidateVoiceTextDelivery()
    guard VoiceInputModePolicy.shouldRestartAlwaysOn(
      mode: voiceInputMode,
      outcome: outcome
    ) else {
      alwaysOnRestartPending = false
      return
    }
    alwaysOnRestartPending = true
    restartAlwaysOnIfReady()
  }

  private func restartAlwaysOnIfReady() {
    alwaysOnRestartWorkItem?.cancel()
    alwaysOnRestartWorkItem = nil
    guard alwaysOnRestartPending,
      voiceInputMode == .alwaysOn,
      !isRecordingMapping,
      !isListening,
      !voiceFinalizing,
      activeVoiceDeliveryToken == nil
    else { return }

    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self,
          self.alwaysOnRestartPending,
          self.voiceInputMode == .alwaysOn,
          !self.isRecordingMapping,
          !self.isListening,
          !self.voiceFinalizing,
          self.activeVoiceDeliveryToken == nil
        else { return }
        self.alwaysOnRestartPending = false
        self.alwaysOnRestartWorkItem = nil
        self.beginVoice(source: "常开续段")
      }
    }
    alwaysOnRestartWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
  }

  private func updatePushToTalkSource(
    _ source: UInt64,
    pressed: Bool,
    commitOnRelease: Bool,
    label: String
  ) {
    guard voiceInputMode == .pushToTalk else {
      if pressed {
        let message = voiceInputMode == .alwaysOn
          ? "麦克风已处于常开模式，无需按住语音键。"
          : "麦克风处于常闭模式；切换到按键或常开后才能采集。"
        setStatus(message, log: true)
      }
      return
    }
    if pressed {
      let shouldStart = pushToTalkSources.isEmpty
      pushToTalkSources.insert(source)
      if shouldStart { beginVoice(source: label) }
      return
    }

    pushToTalkSources.remove(source)
    if pushToTalkSources.isEmpty {
      endVoice(commit: commitOnRelease, source: label)
    }
  }

  private func handleTouchMove(_ event: HelmSDLEvent, now: TimeInterval) {
    guard event.finger == 0 else { return }
    let current = CGPoint(x: Double(event.x), y: Double(event.y))
    defer {
      lastTouch = current
      lastTouchTime = now
    }
    guard controlsEnabled,
      accessibilityGranted,
      let previous = lastTouch,
      let previousTime = lastTouchTime
    else { return }

    let delta = ControlMath.pointerDelta(
      from: previous,
      to: current,
      elapsed: now - previousTime,
      surfaceSize: CGSize(width: 1_920, height: 1_070),
      gain: pointerGain * 0.65 * currentRacingSpeedMultiplier,
      acceleration: 0.18,
      maximum: 90
    )
    InputInjector.movePointer(
      dx: delta.x,
      dy: delta.y,
      leftButtonDown: leftMouseDown,
      rightButtonDown: rightMouseDown
    )
    pendingMotionDiagnostic = .touchDelta(x: delta.x, y: delta.y)
  }

  private func beginVoice(source: String) {
    guard !isListening else { return }
    refreshPermissionState()
    guard
      VoiceInputModePolicy.canBegin(
        mode: voiceInputMode,
        hasPressOwner: !pushToTalkSources.isEmpty
      )
    else { return }
    guard voicePermissionsGranted else {
      setStatus("请先授予麦克风和语音识别权限。", log: true)
      return
    }
    guard selectedAudioDeviceID != 0,
      let selectedDevice = selectedAudioDevice
    else {
      setStatus("请选择一个当前可用的麦克风。", log: true)
      return
    }
    guard !protectPlaybackAudio || !selectedDevice.mayInterruptPlayback else {
      setStatus("已阻止蓝牙麦克风：它会切换通话链路并打断音乐，请选内置或 USB 麦克风。", log: true)
      return
    }

    suppressAutoInsertForCurrentVoice = false
    voiceFinalizing = false
    if voiceInputMode != .alwaysOn { lastCompletedTranscript = nil }
    manualDeliveryActivationBaseline = nil
    voiceInsertionProcessIdentity = nil
    voiceInsertionFocusSnapshot = nil
    let helmProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    let currentProcessIdentifier =
      NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    voiceInsertionTarget = focusHistory.insertionTarget(
      currentProcessIdentifier: currentProcessIdentifier,
      helmProcessIdentifier: helmProcessIdentifier
    )
    if let target = voiceInsertionTarget {
      voiceInsertionFocusSnapshot = InputInjector.captureExternalTextFocus(
        processIdentifier: target
      )
      if let application = NSRunningApplication(processIdentifier: target),
        !application.isTerminated,
        let launchTime = application.launchDate?.timeIntervalSinceReferenceDate
      {
        voiceInsertionProcessIdentity = ExternalProcessIdentity(
          processIdentifier: target,
          launchTime: launchTime
        )
      }
    }
    let targetForLog = voiceInsertionTarget ?? 0
    let focusRoleForLog = voiceInsertionFocusSnapshot?.role ?? "none"
    let focusSubroleForLog = voiceInsertionFocusSnapshot?.subrole ?? "none"
    voiceDeliveryLogger.info(
      "capture targetPID=\(targetForLog, privacy: .public) focusSnapshot=\(self.voiceInsertionFocusSnapshot != nil, privacy: .public) role=\(focusRoleForLog, privacy: .public) subrole=\(focusSubroleForLog, privacy: .public) autoInsert=\(self.autoInsert, privacy: .public)"
    )
    activeVoiceDeliveryToken = voiceDeliveryGeneration.begin()
    defer {
      resetMotionIntegrationState()
    }
    do {
      let sampleRate = try voice.start(
        deviceID: selectedAudioDeviceID,
        localeIdentifier: localeIdentifier,
        automaticallyFinishOnFinalResult:
          voiceInputMode.automaticallyCommitsFinalRecognition,
        onPartial: { [weak self] text in
          self?.transcript = text
        },
        onComplete: { [weak self] text, error in
          self?.voiceCompleted(text: text, error: error)
        }
      )
      lastAudioSampleRate = sampleRate
      activeVoiceAudioDevice = selectedDevice
      transcript = voiceInputMode == .alwaysOn ? "常开监听中…" : "正在聆听…"
      isListening = true
      if voiceInputMode == .alwaysOn { scheduleAlwaysOnSegmentCompletion() }
      updateLatencyActivity()
      let prefix = voiceInputMode == .alwaysOn ? "麦克风常开" : "PTT 已开始"
      setStatus("\(prefix)（\(source) · \(selectedAudioDeviceName) · \(Int(sampleRate)) Hz）", log: true)
      playHaptic(.voiceStart)
    } catch {
      activeVoiceAudioDevice = nil
      isListening = false
      voiceFinalizing = false
      invalidateVoiceTextDelivery()
      updateLatencyActivity()
      setStatus("无法开始语音输入：\(error.localizedDescription)", log: true)
    }
  }

  private func endVoice(commit: Bool, source: String) {
    alwaysOnSegmentWorkItem?.cancel()
    alwaysOnSegmentWorkItem = nil
    guard isListening else { return }
    if !commit { invalidateVoiceTextDelivery() }
    isListening = false
    voiceFinalizing = commit
    updateLatencyActivity()
    setStatus(
      commit ? "语音采集已结束，正在完成识别…" : "麦克风已停止（\(source)）",
      log: true
    )
    playHaptic(.voiceStop)
    voice.stop(commit: commit)
  }

  private func voiceCompleted(text: String?, error: String?) {
    alwaysOnSegmentWorkItem?.cancel()
    alwaysOnSegmentWorkItem = nil
    isListening = false
    voiceFinalizing = false
    activeVoiceAudioDevice = nil
    updateLatencyActivity()
    let deliveryToken = activeVoiceDeliveryToken
    let insertionSuppressed = suppressAutoInsertForCurrentVoice
    suppressAutoInsertForCurrentVoice = false
    if let text, !text.isEmpty {
      transcript = text
      lastCompletedTranscript = text
      manualDeliveryActivationBaseline = focusHistory.activationGeneration
      if insertionSuppressed {
        completeVoiceDelivery(outcome: .failure)
        setStatus("未能确认外部文本焦点；识别文本只保留在 GripPilot 中。", log: true)
      } else if autoInsert {
        if let deliveryToken {
          deliverRecognizedText(text, token: deliveryToken, attemptsRemaining: 12)
        } else {
          completeVoiceDelivery(outcome: .failure)
          setStatus("语音目标会话已失效；文本保留在 GripPilot 中。", log: true)
        }
      } else {
        completeVoiceDelivery(outcome: .failure)
        let suffix = voiceInputMode == .alwaysOn ? "；常开监听已暂停" : ""
        setStatus("语音识别完成，自动写入已关闭\(suffix)。", log: true)
      }
    } else if let error, !error.isEmpty {
      completeVoiceDelivery(outcome: .failure)
      setStatus("语音识别结束：\(error)", log: true)
    } else {
      completeVoiceDelivery(outcome: .emptySegment)
      let suffix = voiceInputMode == .alwaysOn ? "，继续常开监听。" : "。"
      setStatus("没有识别到可用文本\(suffix)", log: true)
    }
    nextAudioRefresh = 0
  }

  private func deliverRecognizedText(
    _ text: String,
    token: UInt64,
    attemptsRemaining: Int
  ) {
    guard activeVoiceDeliveryToken == token, voiceDeliveryGeneration.accepts(token) else { return }
    guard !HelmSecureInputEnabled() else {
      completeVoiceDelivery(outcome: .failure)
      setStatus("检测到系统安全输入；识别文本只保留在 GripPilot 中。", log: true)
      return
    }
    let helmProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    let currentProcessIdentifier =
      NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let target = VoiceInsertionTargetPolicy.deliveryTarget(
      capturedProcessIdentifier: voiceInsertionTarget,
      currentProcessIdentifier: currentProcessIdentifier,
      helmProcessIdentifier: helmProcessIdentifier
    )

    guard let target, target > 0, target != helmProcessIdentifier else {
      completeVoiceDelivery(outcome: .failure)
      setStatus("未找到外部文本目标；识别文本只保留在 GripPilot 中。", log: true)
      return
    }

    let identityMatches = voiceInsertionProcessIdentity.map(runningApplicationMatches) ?? false
    let focusResolution = TextInsertionPolicy.voiceFocusSnapshotResolution(
      hasCapturedSnapshot: voiceInsertionFocusSnapshot != nil,
      targetIsFrontmost: currentProcessIdentifier == target,
      processIdentityMatches: identityMatches
    )

    guard focusResolution != .refuse else {
      completeVoiceDelivery(outcome: .failure)
      setStatus("无法确认外部目标进程身份；为避免误写，文本保留在 GripPilot 中。", log: true)
      return
    }

    if focusResolution == .retryAfterActivation {
      guard let nextAttemptCount = VoiceTextDeliveryRetryPolicy.nextAttemptCount(
        from: attemptsRemaining
      ),
        let application = NSRunningApplication(processIdentifier: target),
        !application.isTerminated
      else {
        completeVoiceDelivery(outcome: .failure)
        setStatus("外部目标应用未能恢复焦点；识别文本只保留在 GripPilot 中。", log: true)
        return
      }
      _ = application.activate(options: [.activateAllWindows])
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
        self?.deliverRecognizedText(
          text,
          token: token,
          attemptsRemaining: nextAttemptCount
        )
      }
      return
    }

    let snapshot: ExternalTextFocusSnapshot
    switch focusResolution {
    case .useCapturedFocus:
      guard let captured = voiceInsertionFocusSnapshot,
        captured.processIdentifier == target
      else {
        completeVoiceDelivery(outcome: .failure)
        setStatus("已捕获的外部文本目标无效；识别文本只保留在 GripPilot 中。", log: true)
        return
      }
      snapshot = captured
    case .recaptureCurrentExternalFocus:
      guard
        let recaptured = InputInjector.captureExternalTextFocus(
          processIdentifier: target
        )
      else {
        retryRecognizedTextDelivery(
          text,
          token: token,
          attemptsRemaining: attemptsRemaining,
          reason: "外部文本框焦点尚未就绪"
        )
        return
      }
      voiceInsertionFocusSnapshot = recaptured
      snapshot = recaptured
      voiceDeliveryLogger.info(
        "focus recapture targetPID=\(target, privacy: .public) role=\(recaptured.role, privacy: .public) subrole=\(recaptured.subrole, privacy: .public)"
      )
    case .retryAfterActivation, .refuse:
      return
    }
    let restored = InputInjector.restoreExternalTextFocus(snapshot)
    voiceDeliveryLogger.info(
      "focus restore targetPID=\(target, privacy: .public) restored=\(restored, privacy: .public)"
    )
    guard restored else {
      retryRecognizedTextDelivery(
        text,
        token: token,
        attemptsRemaining: attemptsRemaining,
        reason: "捕获的外部文本框未能恢复焦点"
      )
      return
    }

    switch InputInjector.prepareTextInsertion(text, focusSnapshot: snapshot) {
    case .unicodeChunks(let chunks):
      setStatus("已锁定原外部文本框，正在逐字投递…", log: true)
      deliverUnicodeChunks(
        chunks,
        index: 0,
        focusSnapshot: snapshot,
        target: target,
        token: token,
        attemptsRemaining: 3
      )
    case .result(let result):
      handleTextInsertionResult(
        result,
        text: text,
        target: target,
        token: token,
        attemptsRemaining: attemptsRemaining
      )
    }
  }

  private func handleTextInsertionResult(
    _ result: TextInsertionResult,
    text: String,
    target: Int32,
    token: UInt64,
    attemptsRemaining: Int
  ) {
    switch result {
    case .inserted(let method):
      voiceDeliveryLogger.info(
        "delivery result=inserted targetPID=\(target, privacy: .public) method=\(method, privacy: .public)"
      )
      lastCompletedTranscript = TextInsertionPolicy.retryText(
        after: .confirmedInsertion,
        originalText: text
      )
      completeVoiceDelivery(outcome: .confirmedDelivery)
      setStatus("识别文本已写入原外部文本框（\(method)）。", log: true)
    case .dispatched(let method):
      voiceDeliveryLogger.info(
        "delivery result=dispatched targetPID=\(target, privacy: .public) method=\(method, privacy: .public)"
      )
      lastCompletedTranscript = TextInsertionPolicy.retryText(
        after: .unconfirmedDispatch,
        originalText: text
      )
      completeVoiceDelivery(outcome: .unconfirmedDelivery)
      setStatus("已向原外部文本框发送\(method)；请确认文本是否出现。", log: true)
    case .retryable(let reason):
      retryRecognizedTextDelivery(
        text,
        token: token,
        attemptsRemaining: attemptsRemaining,
        reason: reason
      )
    case .refused(let reason):
      voiceDeliveryLogger.info(
        "delivery result=refused targetPID=\(target, privacy: .public) reason=\(reason, privacy: .public)"
      )
      completeVoiceDelivery(outcome: .failure)
      setStatus("\(reason)；文本保留在 GripPilot 中。", log: true)
    }
  }

  private func retryRecognizedTextDelivery(
    _ text: String,
    token: UInt64,
    attemptsRemaining: Int,
    reason: String
  ) {
    voiceDeliveryLogger.info(
      "delivery result=retry attempts=\(attemptsRemaining, privacy: .public) reason=\(reason, privacy: .public)"
    )
    guard let nextAttemptCount = VoiceTextDeliveryRetryPolicy.nextAttemptCount(
      from: attemptsRemaining
    ) else {
      completeVoiceDelivery(outcome: .failure)
      setStatus("\(reason)；重试已用尽，文本保留在 GripPilot 中。", log: true)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
      self?.deliverRecognizedText(
        text,
        token: token,
        attemptsRemaining: nextAttemptCount
      )
    }
  }

  private func deliverUnicodeChunks(
    _ chunks: [String],
    index: Int,
    focusSnapshot: ExternalTextFocusSnapshot,
    target: Int32,
    token: UInt64,
    attemptsRemaining: Int
  ) {
    guard activeVoiceDeliveryToken == token, voiceDeliveryGeneration.accepts(token) else { return }
    guard index < chunks.count else {
      lastCompletedTranscript = UnicodeDeliveryProgress.completedUnconfirmedText(chunks: chunks)
      completeVoiceDelivery(outcome: .unconfirmedDelivery)
      let suffix = voiceInputMode == .alwaysOn ? "，常开监听已暂停" : ""
      setStatus("已向原外部文本框逐字发送（\(chunks.count) 个字素）；请确认文本是否出现\(suffix)。", log: true)
      return
    }
    guard let expectedIdentity = voiceInsertionProcessIdentity,
      runningApplicationMatches(expectedIdentity)
    else {
      finishInterruptedUnicodeDelivery(
        chunks: chunks,
        sentCount: index,
        reason: "外部目标进程身份无法确认"
      )
      return
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else {
      finishInterruptedUnicodeDelivery(
        chunks: chunks,
        sentCount: index,
        reason: "外部应用失去前台焦点"
      )
      return
    }

    switch InputInjector.postUnicodeChunk(
      chunks[index],
      focusSnapshot: focusSnapshot
    ) {
    case .posted:
      let nextIndex = index + 1
      let remaining = UnicodeDeliveryProgress.remainingText(
        chunks: chunks,
        sentCount: nextIndex
      )
      if nextIndex == chunks.count {
        lastCompletedTranscript = UnicodeDeliveryProgress.completedUnconfirmedText(chunks: chunks)
        voiceDeliveryLogger.info(
          "delivery result=unicode-complete targetPID=\(target, privacy: .public) graphemes=\(chunks.count, privacy: .public)"
        )
        completeVoiceDelivery(outcome: .unconfirmedDelivery)
        let suffix = voiceInputMode == .alwaysOn ? "，常开监听已暂停" : ""
        setStatus("已向原外部文本框逐字发送（\(chunks.count) 个字素）；请确认文本是否出现\(suffix)。", log: true)
        return
      }
      lastCompletedTranscript = remaining
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self] in
        self?.deliverUnicodeChunks(
          chunks,
          index: nextIndex,
          focusSnapshot: focusSnapshot,
          target: target,
          token: token,
          attemptsRemaining: 3
        )
      }
    case .retryable(let reason):
      guard index == 0,
        let nextAttemptCount = VoiceTextDeliveryRetryPolicy.nextAttemptCount(
          from: attemptsRemaining
        )
      else {
        finishInterruptedUnicodeDelivery(
          chunks: chunks,
          sentCount: index,
          reason: reason
        )
        return
      }
      _ = InputInjector.restoreExternalTextFocus(focusSnapshot)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
        self?.deliverUnicodeChunks(
          chunks,
          index: index,
          focusSnapshot: focusSnapshot,
          target: target,
          token: token,
          attemptsRemaining: nextAttemptCount
        )
      }
    case .refused(let reason):
      finishInterruptedUnicodeDelivery(
        chunks: chunks,
        sentCount: index,
        reason: reason
      )
    }
  }

  private func finishInterruptedUnicodeDelivery(
    chunks: [String],
    sentCount: Int,
    reason: String
  ) {
    let safeSentCount = min(max(sentCount, 0), chunks.count)
    let remaining = UnicodeDeliveryProgress.remainingText(
      chunks: chunks,
      sentCount: safeSentCount
    )
    lastCompletedTranscript = remaining.isEmpty ? nil : remaining
    voiceDeliveryLogger.info(
      "delivery result=partial sent=\(safeSentCount, privacy: .public) total=\(chunks.count, privacy: .public) reason=\(reason, privacy: .public)"
    )
    completeVoiceDelivery(outcome: .failure)
    if safeSentCount > 0 {
      setStatus(
        "逐字投递已中止：已发送 \(safeSentCount)/\(chunks.count) 个字素（\(reason)）；重发只会发送剩余部分。",
        log: true
      )
    } else {
      setStatus("逐字投递未开始（\(reason)）；文本保留在 GripPilot 中。", log: true)
    }
  }

  private func invalidateVoiceTextDelivery() {
    voiceDeliveryGeneration.invalidate()
    activeVoiceDeliveryToken = nil
    voiceInsertionTarget = nil
    voiceInsertionProcessIdentity = nil
    voiceInsertionFocusSnapshot = nil
    if lastCompletedTranscript != nil {
      manualDeliveryActivationBaseline = focusHistory.activationGeneration
    }
  }

  private func emergencyStop(reason: String, announce: Bool = true) {
    motionSamplingDriver.disableOutputAndWait()
    pendingReconnectWorkItem?.cancel()
    pendingReconnectWorkItem = nil
    pendingReconnectIdentity = nil
    if leftMouseDown {
      InputInjector.mouseButton(.left, pressed: false)
      leftMouseDown = false
    }
    if rightMouseDown {
      InputInjector.mouseButton(.right, pressed: false)
      rightMouseDown = false
    }
    leftMouseSources.removeAll()
    rightMouseSources.removeAll()
    releaseHeldShortcutModifiers()
    pushToTalkSources.removeAll()
    cancelAlwaysOnAutomation()
    _ = bindingResolver.reset()
    cancelMappingCaptureState(resumeControls: false)
    voice.cancelCurrent()
    activeVoiceAudioDevice = nil
    hapticCoordinator.stop(backend: hapticBackend)
    isListening = false
    voiceFinalizing = false
    invalidateVoiceTestSession()
    invalidateVoiceTextDelivery()
    suppressAutoInsertForCurrentVoice = false
    controlsEnabled = false
    syncMotionConfiguration()
    safetyChordTracker.reset()
    InputInjector.endPointerSession()
    resetMotionState()
    updateLatencyActivity()
    if announce { setStatus("控制已安全停用：\(reason)", log: true) }
  }

  private func resetMotionState() {
    analogState.reset()
    leftTriggerValue = 0
    rightTriggerValue = 0
    resetMotionIntegrationState()
  }

  private func resetMotionIntegrationState() {
    motionSamplingDriver.requestMotionReset()
    lastTouch = nil
    lastTouchTime = nil
  }

  private func handleControllerConnected(event: inout HelmSDLEvent) {
    let identity = ControllerIdentity(
      family: controllerFamily(from: event.controller_family),
      vendorID: UInt16(truncatingIfNeeded: event.vendor_id),
      productID: UInt16(truncatingIfNeeded: event.product_id)
    )
    let connection = ControllerConnection(rawValue: event.connection) ?? .unknown
    let name = bridgeString(&event)

    if let expected = pendingReconnectIdentity,
      ControllerReconnectPolicy.canResume(expected: expected, candidate: identity)
    {
      pendingReconnectWorkItem?.cancel()
      pendingReconnectWorkItem = nil
      pendingReconnectIdentity = nil
      configureConnectedController(name: name, identity: identity, connection: connection)
      reconcileButtonsAfterReconnect()
      if controlsEnabled { InputInjector.beginPointerSession() }
      queueLatestInput("已恢复 \(name)")
      setStatus(
        isListening
          ? "有线手柄已从音频重枚举中恢复；语音识别保持运行。"
          : "有线手柄已从音频重枚举中恢复。",
        log: true
      )
      updateLatencyActivity()
      return
    }

    if pendingReconnectIdentity != nil {
      emergencyStop(reason: "重连的不是原手柄", announce: false)
    } else {
      emergencyStop(reason: "手柄已连接，等待显式启用", announce: false)
    }
    configureConnectedController(name: name, identity: identity, connection: connection)
    queueLatestInput("已连接 \(name)")
    if launchAutoEnableGate.consumeForConnection() {
      toggleControls(promptForAccessibility: false)
      if controlsEnabled {
        setStatus("启动时检测到 \(name)，已按配置自动启用控制。", log: true)
      }
    } else {
      setStatus("检测到 \(name)，请检查权限后启用控制。", log: true)
    }
  }

  private func handleControllerDisconnected(event: HelmSDLEvent) {
    guard pendingReconnectIdentity == nil else { return }
    let eventIdentity = ControllerIdentity(
      family: controllerFamily(from: event.controller_family),
      vendorID: UInt16(truncatingIfNeeded: event.vendor_id),
      productID: UInt16(truncatingIfNeeded: event.product_id)
    )
    let identity = controllerIdentity ?? eventIdentity
    if ControllerReconnectPolicy.shouldWait(
      hasActiveVoiceSession: VoiceSessionPolicy.isActiveForReconnect(
        isListening: isListening,
        isFinalizing: voiceFinalizing
      ),
      selectedAudioDevice: activeVoiceAudioDevice ?? selectedAudioDevice,
      connection: controllerConnection,
      controller: identity
    ) {
      beginControllerReconnectGrace(identity: identity)
      return
    }

    emergencyStop(reason: "手柄已断开")
    clearControllerPresentation()
    queueLatestInput("手柄已断开")
  }

  private func configureConnectedController(
    name: String,
    identity: ControllerIdentity,
    connection: ControllerConnection
  ) {
    controllerIdentity = identity
    controllerFamily = identity.family
    controllerConnection = connection
    controllerConnected = true
    controllerName = name
    connectionLabel = connectionName(connection.rawValue)
    microphoneButtonAvailable = HelmSDLHasMicrophoneButton()
    touchpadCount = HelmSDLTouchpadCount()
    hapticsAvailable = hapticBackend.isAvailable()
  }

  private func clearControllerPresentation() {
    controllerConnected = false
    controllerName = "未连接手柄"
    controllerFamily = .generic
    controllerIdentity = nil
    controllerConnection = .unknown
    connectionLabel = "—"
    microphoneButtonAvailable = false
    touchpadCount = 0
    hapticsAvailable = false
  }

  private func beginControllerReconnectGrace(identity: ControllerIdentity) {
    motionSamplingDriver.disableOutputAndWait()
    if leftMouseDown {
      InputInjector.mouseButton(.left, pressed: false)
      leftMouseDown = false
    }
    if rightMouseDown {
      InputInjector.mouseButton(.right, pressed: false)
      rightMouseDown = false
    }
    leftMouseSources.removeAll()
    rightMouseSources.removeAll()
    releaseHeldShortcutModifiers()
    hapticCoordinator.stop(backend: hapticBackend)
    InputInjector.endPointerSession()
    resetMotionState()

    controllerConnected = false
    controllerName = "有线手柄音频重连中…"
    connectionLabel = "USB 重枚举"
    microphoneButtonAvailable = false
    touchpadCount = 0
    hapticsAvailable = false
    pendingReconnectIdentity = identity
    let workItem = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.controllerReconnectTimedOut(expected: identity)
      }
    }
    pendingReconnectWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + ControllerReconnectPolicy.graceInterval,
      execute: workItem
    )
    queueLatestInput("USB 音频启动，等待同一手柄恢复")
    setStatus("检测到有线手柄音频重枚举；保留语音采集，等待 1.2 秒内自动恢复。", log: true)
    updateLatencyActivity()
  }

  private func controllerReconnectTimedOut(expected: ControllerIdentity) {
    guard pendingReconnectIdentity == expected else { return }
    pendingReconnectWorkItem = nil
    pendingReconnectIdentity = nil
    emergencyStop(reason: "有线手柄重连超时")
    clearControllerPresentation()
    queueLatestInput("手柄重连超时")
    nextAudioRefresh = 0
  }

  private func reconcileButtonsAfterReconnect() {
    for button in ControllerButton.allCases where !HelmSDLButtonPressed(button.rawValue) {
      let transitions = bindingResolver.process(
        button: button,
        pressed: false,
        mapping: mapping
      )
      for transition in transitions {
        handleMappedButton(
          transition.chord.sourceID,
          label: transition.chord.label(family: controllerFamily),
          action: transition.action,
          pressed: transition.pressed
        )
      }
    }
  }

  private func completeMappingCapture(with chord: ControllerChord) {
    guard !SafetyChordPolicy.isReserved(chord, family: controllerFamily) else {
      cancelMappingCaptureState()
      setStatus("固定安全急停组合 \(safetyChordLabel) 不能用于普通映射。", log: true)
      return
    }

    let action = mappingCaptureOriginalChord.flatMap { mapping.action(for: $0) }
      ?? pendingMappingAction
    guard action != .none else {
      cancelMappingCaptureState()
      setStatus("请选择一个具体动作后再录入映射。", log: true)
      return
    }

    var updated = mapping
    if let original = mappingCaptureOriginalChord { updated.remove(chord: original) }
    let removed = updated.upsert(ControllerBinding(chord: chord, action: action))
    cancelMappingCaptureState(resumeControls: false)
    mapping = updated
    let conflictNote = removed.isEmpty ? "" : "；已替换 \(removed.count) 个前缀冲突映射"
    setStatus(
      "已录入 \(chord.label(family: controllerFamily)) → \(action.title)\(conflictNote)。",
      log: true
    )
  }

  private func cancelMappingCaptureState(resumeControls: Bool = true) {
    chordRecorder.cancel()
    mappingCaptureOriginalChord = nil
    isRecordingMapping = false
    mappingCapturePrompt = ""
    if resumeControls { resumeControlSessionAfterMappingCapture() }
  }

  private func stopVoiceForMappingCapture() {
    let shouldResumeAlwaysOn = voiceInputMode == .alwaysOn
    cancelAlwaysOnAutomation()
    voice.cancelCurrent()
    isListening = false
    voiceFinalizing = false
    activeVoiceAudioDevice = nil
    pushToTalkSources.removeAll()
    invalidateVoiceTestSession()
    invalidateVoiceTextDelivery()
    suppressAutoInsertForCurrentVoice = false
    alwaysOnRestartPending = shouldResumeAlwaysOn
    updateLatencyActivity()
  }

  private func releaseInjectedInputsPreservingControlSession() {
    motionSamplingDriver.disableOutputAndWait()
    if leftMouseDown { InputInjector.mouseButton(.left, pressed: false) }
    if rightMouseDown { InputInjector.mouseButton(.right, pressed: false) }
    leftMouseDown = false
    rightMouseDown = false
    leftMouseSources.removeAll()
    rightMouseSources.removeAll()
    releaseHeldShortcutModifiers()
    _ = bindingResolver.reset()
    hapticCoordinator.stop(backend: hapticBackend)
    safetyChordTracker.reset()
    InputInjector.endPointerSession()
    resetMotionState()
  }

  private func resumeControlSessionAfterMappingCapture() {
    resetMotionState()
    if controlsEnabled, controllerConnected, accessibilityGranted {
      InputInjector.beginPointerSession()
    }
    syncMotionConfiguration()
    restartAlwaysOnIfReady()
  }

  private func queueLatestInput(_ message: String) {
    pendingLatestInput = message
  }

  private func updateLatencyActivity() {
    let shouldRun = started
      && (controllerConnected || controlsEnabled || isListening || voiceFinalizing
        || pendingReconnectIdentity != nil)
    if shouldRun, latencyActivity == nil {
      latencyActivity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
        reason: "GripPilot controller and voice input"
      )
    } else if !shouldRun, let latencyActivity {
      ProcessInfo.processInfo.endActivity(latencyActivity)
      self.latencyActivity = nil
    }
  }

  private func controllerFamily(from bridgeValue: Int32) -> ControllerFamily {
    switch bridgeValue {
    case Int32(HELM_CONTROLLER_FAMILY_PLAYSTATION): return .playStation
    case Int32(HELM_CONTROLLER_FAMILY_XBOX): return .xbox
    case Int32(HELM_CONTROLLER_FAMILY_NINTENDO): return .nintendo
    default: return .generic
    }
  }

  @discardableResult
  private func playHaptic(
    _ kind: HapticFeedbackKind,
    allowsDisabledControls: Bool = false
  ) -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    let sent = hapticCoordinator.play(
      kind,
      intensity: hapticIntensity,
      enabled: hapticsEnabled,
      connected: controllerConnected,
      controlsEnabled: controlsEnabled,
      allowsDisabledControls: allowsDisabledControls,
      now: now,
      backend: hapticBackend
    )
    if !sent {
      hapticsAvailable = hapticBackend.isAvailable()
    }
    return sent
  }

  private func mappingDidChange() {
    if let data = try? JSONEncoder().encode(mapping) {
      UserDefaults.standard.set(data, forKey: "controllerMapping")
    }
    guard started else { return }
    if isListening || voiceFinalizing || !pushToTalkSources.isEmpty {
      stopVoiceForMappingCapture()
    }
    releaseInjectedInputsPreservingControlSession()
    resumeControlSessionAfterMappingCapture()
    setStatus(
      controlsEnabled ? "按键映射已保存；控制连接保持启用。" : "按键映射已保存。",
      log: true
    )
  }

  private func shortcutSettingsDidChange() {
    releaseHeldShortcutModifiers()
    if let data = try? JSONEncoder().encode(shortcutSettings) {
      UserDefaults.standard.set(data, forKey: "controllerShortcutSettings")
    }
    if started { setStatus("外部快捷键已保存。", log: true) }
  }

  private func releaseHeldShortcutModifiers() {
    let transitions = modifierHoldCoordinator.reset()
    _ = InputInjector.applyModifierKeyTransitions(transitions)
  }

  private func refreshPermissionState() {
    let access = InputInjector.accessibilityTrusted()
    let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    let speech = SFSpeechRecognizer.authorizationStatus()
    let permissionSnapshot = PermissionDiagnosticSnapshot(
      accessibilityGranted: access,
      microphoneRawValue: microphone.rawValue,
      speechRawValue: speech.rawValue
    )
    if let changedSnapshot = permissionDiagnosticTracker.recordIfChanged(permissionSnapshot) {
      permissionLogger.notice("\(changedSnapshot.logMessage, privacy: .public)")
    }
    if accessibilityGranted != access { accessibilityGranted = access }
    if microphoneAuthorization != microphone { microphoneAuthorization = microphone }
    if speechAuthorization != speech { speechAuthorization = speech }

    if controlsEnabled, !access {
      emergencyStop(reason: "辅助功能权限已失效")
    } else if VoiceSessionPolicy.isActiveForReconnect(
      isListening: isListening,
      isFinalizing: voiceFinalizing
    ), microphone != .authorized || speech != .authorized {
      cancelAlwaysOnAutomation()
      voice.cancelCurrent()
      isListening = false
      voiceFinalizing = false
      activeVoiceAudioDevice = nil
      pushToTalkSources.removeAll()
      invalidateVoiceTestSession()
      invalidateVoiceTextDelivery()
      suppressAutoInsertForCurrentVoice = false
      updateLatencyActivity()
      setStatus("语音权限已失效，语音采集已安全停止。", log: true)
    }
  }

  private func refreshAudioDevices() {
    guard pendingReconnectIdentity == nil, audioRefreshGate.begin() else { return }
    DispatchQueue.global(qos: .utility).async {
      let refreshed = AudioInputCatalog.devices()
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.audioRefreshGate.end()
          self.applyAudioDevices(refreshed)
        }
      }
    }
  }

  private func applyAudioDevices(_ fetchedDevices: [AudioInputDevice]) {
    guard pendingReconnectIdentity == nil else { return }
    let initializedSelectionNow = !audioSelectionInitialized
    var refreshed = fetchedDevices
    let previousSelection = selectedAudioDeviceID
    let previousDevice = audioDevices.first(where: { $0.id == previousSelection })

    if previousSelection != 0,
      !refreshed.contains(where: { $0.id == previousSelection }),
      let controllerAudio = activeVoiceAudioDevice ?? previousDevice,
      controllerAudio.isControllerRoutedUSB
    {
      let replacement = refreshed.first(where: {
        $0.isControllerRoutedUSB
          && $0.name.localizedCaseInsensitiveCompare(controllerAudio.name) == .orderedSame
      })
      if let replacement,
        controllerConnected,
        ControllerReconnectPolicy.canMigrateAudioRoute(connection: controllerConnection)
      {
        selectedAudioDeviceID = replacement.id
      } else if VoiceSessionPolicy.isActiveForReconnect(
        isListening: isListening,
        isFinalizing: voiceFinalizing
      ) {
        refreshed.append(controllerAudio)
      }
    }
    if audioDevices != refreshed { audioDevices = refreshed }
    if !audioSelectionInitialized {
      audioSelectionInitialized = true
      selectedAudioDeviceID =
        AudioInputCatalog.preferredInput(
          from: refreshed,
          protectPlayback: protectPlaybackAudio
        )?.id ?? 0
    } else if selectedAudioDeviceID != 0,
      !refreshed.contains(where: { $0.id == selectedAudioDeviceID })
    {
      if VoiceSessionPolicy.isActiveForReconnect(
        isListening: isListening,
        isFinalizing: voiceFinalizing
      ) {
        cancelAlwaysOnAutomation()
        voice.cancelCurrent()
        isListening = false
        voiceFinalizing = false
        activeVoiceAudioDevice = nil
        pushToTalkSources.removeAll()
        invalidateVoiceTestSession()
        invalidateVoiceTextDelivery()
        suppressAutoInsertForCurrentVoice = false
        updateLatencyActivity()
        setStatus("选择的麦克风已拔出，语音采集已停止；未自动切换。", log: true)
      }
      selectedAudioDeviceID = 0
    }
    if protectPlaybackAudio { enforcePlaybackProtection(announce: false) }
    if initializedSelectionNow,
      voiceInputMode == .alwaysOn,
      !isListening,
      !voiceFinalizing,
      activeVoiceDeliveryToken == nil
    {
      beginVoice(source: "启动常开模式")
    }
  }

  private func enforcePlaybackProtection(announce: Bool) {
    guard protectPlaybackAudio, let selectedAudioDevice, selectedAudioDevice.mayInterruptPlayback
    else { return }
    guard
      let plan = AudioInputCatalog.playbackProtectionPlan(
        selected: selectedAudioDevice,
        from: audioDevices,
        captureActive: isListening
      )
    else { return }
    if plan.shouldStopCapture {
      cancelAlwaysOnAutomation()
      voice.cancelCurrent()
      isListening = false
      voiceFinalizing = false
      activeVoiceAudioDevice = nil
      pushToTalkSources.removeAll()
      invalidateVoiceTestSession()
      invalidateVoiceTextDelivery()
      suppressAutoInsertForCurrentVoice = false
      updateLatencyActivity()
    }
    selectedAudioDeviceID = plan.replacement?.id ?? 0
    guard announce else { return }
    if let replacement = plan.replacement {
      let prefix = plan.shouldStopCapture ? "已立即停止蓝牙采集，并" : "已"
      setStatus("\(prefix)切换到 \(replacement.name)，避免启用蓝牙通话链路。", log: true)
    } else if plan.shouldStopCapture {
      setStatus("已立即停止蓝牙采集；没有安全麦克风，请连接 USB 麦克风。", log: true)
    } else {
      setStatus("没有安全麦克风；请连接 USB 麦克风或关闭播放保护。", log: true)
    }
  }

  private func finishVoiceTestAfterFocusRestoration(
    target: Int32,
    token: UInt64,
    attemptsRemaining: Int
  ) {
    guard voiceTestFinishing,
      activeVoiceTestToken == token,
      voiceTestGeneration.accepts(token),
      pushToTalkSources.contains(Self.interfaceVoiceSource)
    else { return }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == target {
      invalidateVoiceTestSession()
      updatePushToTalkSource(
        Self.interfaceVoiceSource,
        pressed: false,
        commitOnRelease: true,
        label: "界面测试"
      )
      return
    }
    guard attemptsRemaining > 0 else {
      invalidateVoiceTestSession()
      suppressAutoInsertForCurrentVoice = true
      updatePushToTalkSource(
        Self.interfaceVoiceSource,
        pressed: false,
        commitOnRelease: true,
        label: "界面测试"
      )
      setStatus("外部应用未在 0.5 秒内恢复焦点；识别结果只会保留在 GripPilot 中。", log: true)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
      self?.finishVoiceTestAfterFocusRestoration(
        target: target,
        token: token,
        attemptsRemaining: attemptsRemaining - 1
      )
    }
  }

  private func invalidateVoiceTestSession() {
    voiceTestGeneration.invalidate()
    activeVoiceTestToken = nil
    voiceTestFinishing = false
  }

  private func externalWindowOwnerProcessIdentifiers() -> [Int32] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard
      let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]]
    else { return [] }
    let helmIdentifier = ProcessInfo.processInfo.processIdentifier
    return windows.compactMap { window in
      guard
        let layer = window[kCGWindowLayer as String] as? NSNumber,
        layer.intValue == 0,
        let owner = window[kCGWindowOwnerPID as String] as? NSNumber
      else { return nil }
      let identifier = owner.int32Value
      guard identifier > 0, identifier != helmIdentifier,
        let application = NSRunningApplication(processIdentifier: identifier),
        application.activationPolicy == .regular, !application.isTerminated
      else { return nil }
      return identifier
    }
  }

  private func setStatus(_ message: String, log: Bool) {
    statusMessage = message
    if log { appendActivity(message) }
  }

  private func appendActivity(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    activity.insert("\(formatter.string(from: Date()))  \(message)", at: 0)
    if activity.count > 12 { activity.removeLast(activity.count - 12) }
  }

  private func recordApplicationActivation(_ application: NSRunningApplication) {
    focusHistory.recordActivation(
      processIdentifier: application.processIdentifier,
      processLaunchTime: application.launchDate?.timeIntervalSinceReferenceDate,
      helmProcessIdentifier: ProcessInfo.processInfo.processIdentifier
    )
  }

  private func runningApplicationMatches(_ identity: ExternalProcessIdentity) -> Bool {
    guard
      let application = NSRunningApplication(
        processIdentifier: identity.processIdentifier
      ), !application.isTerminated
    else { return false }
    return ExternalProcessIdentityPolicy.matches(
      expected: identity,
      candidateProcessIdentifier: application.processIdentifier,
      candidateLaunchTime: application.launchDate?.timeIntervalSinceReferenceDate
    )
  }

  private func restoreExternalFocusForVoiceTest() -> Int32? {
    let current = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let targets = focusHistory.restorationTargets(
      currentProcessIdentifier: current,
      helmProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
      fallbackProcessIdentifiers: externalWindowOwnerProcessIdentifiers()
    )
    for target in targets {
      guard let application = NSRunningApplication(processIdentifier: target),
        !application.isTerminated
      else { continue }
      if application.activate(options: [.activateAllWindows]) { return target }
    }
    return nil
  }

  private func connectionName(_ state: Int32) -> String {
    switch state {
    case 1: return "USB / 有线"
    case 2: return "Bluetooth / 无线"
    case 0: return "未知传输"
    default: return "—"
    }
  }

  private func bridgeString(_ event: inout HelmSDLEvent) -> String {
    withUnsafePointer(to: &event.text) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: 160) {
        String(cString: $0)
      }
    }
  }
}
