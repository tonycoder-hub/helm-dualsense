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
  @Published var accessibilityGranted = false
  @Published var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
  @Published var speechAuthorization = SFSpeechRecognizer.authorizationStatus()
  @Published var isListening = false
  @Published var lastAudioSampleRate = 0.0
  @Published var transcript = "按住手柄麦克风键说话，识别结果会显示在这里。"
  @Published var autoInsert = true
  @Published var localeIdentifier = "zh-CN"
  @Published var protectPlaybackAudio = true {
    didSet {
      UserDefaults.standard.set(protectPlaybackAudio, forKey: "protectPlaybackAudio")
      if started, protectPlaybackAudio { enforcePlaybackProtection(announce: true) }
    }
  }
  @Published var pointerGain = 1.0 {
    didSet { UserDefaults.standard.set(pointerGain, forKey: "pointerGain") }
  }
  @Published var scrollGain = 8.0 {
    didSet { UserDefaults.standard.set(scrollGain, forKey: "scrollGain") }
  }
  @Published var inputPollingRate = InputCadencePolicy.defaultRate {
    didSet {
      UserDefaults.standard.set(inputPollingRate, forKey: "inputPollingRate")
      if started { startCadence() }
    }
  }
  @Published var measuredInputRate = 0.0
  @Published var inputCadenceLabel = "240 Hz 主动采样"
  @Published var stickResponseExponent = ControlMath.defaultStickResponseExponent {
    didSet { UserDefaults.standard.set(stickResponseExponent, forKey: "stickResponseExponent") }
  }
  @Published var stickSmoothingMilliseconds = ControlMath.defaultStickSmoothingTime * 1_000 {
    didSet {
      UserDefaults.standard.set(stickSmoothingMilliseconds, forKey: "stickSmoothingMilliseconds")
    }
  }
  @Published var stickAccelerationDuration = 1.6 {
    didSet {
      UserDefaults.standard.set(stickAccelerationDuration, forKey: "stickAccelerationDuration")
    }
  }
  @Published var stickMaximumBoost = 2.2 {
    didSet { UserDefaults.standard.set(stickMaximumBoost, forKey: "stickMaximumBoost") }
  }
  @Published var brakeMinimumSpeed = 0.28 {
    didSet { UserDefaults.standard.set(brakeMinimumSpeed, forKey: "brakeMinimumSpeed") }
  }
  @Published var acceleratorMaximumSpeed = 2.6 {
    didSet {
      UserDefaults.standard.set(acceleratorMaximumSpeed, forKey: "acceleratorMaximumSpeed")
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
  @Published var statusMessage = "Helm 已就绪；启动时不会注入输入或录音。"
  @Published var activity: [String] = []
  @Published var audioDevices: [AudioInputDevice] = []
  @Published var selectedAudioDeviceID = AudioDeviceID(0)
  @Published var isRecordingMapping = false
  @Published var mappingCapturePrompt = ""
  @Published var pendingMappingAction = ControllerAction.primaryClick

  private let voice = VoiceService()
  private let updateController = HelmUpdateController()
  private let cadenceDriver = InputCadenceDriver()
  private let permissionLogger = Logger(
    subsystem: "io.github.tonycoder-hub.helm",
    category: "permissions"
  )
  private var terminationObserver: NSObjectProtocol?
  private var workspaceActivationObserver: NSObjectProtocol?
  private var started = false
  private var lastTick = ProcessInfo.processInfo.systemUptime
  private var nextPermissionRefresh = 0.0
  private var nextAudioRefresh = 0.0
  private var nextDiagnosticsRefresh = 0.0
  private var cadenceMeasurementStartedAt = 0.0
  private var cadenceTickCount = 0
  private var analogState = ControllerAnalogState()
  private var leftStickActiveSince: TimeInterval?
  private var scrollAccumulator = ContinuousScrollAccumulator()
  private var pointerFilter = StickMotionFilter()
  private var scrollFilter = StickMotionFilter()
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
  private var focusHistory = ExternalFocusHistory()
  private var voiceTestFinishing = false
  private var suppressAutoInsertForCurrentVoice = false
  private var voiceTestGeneration = VoiceTestSessionGeneration()
  private var activeVoiceTestToken: UInt64?
  private var voiceDeliveryGeneration = VoiceTestSessionGeneration()
  private var activeVoiceDeliveryToken: UInt64?
  private var voiceInsertionTarget: Int32?
  private var voiceInsertionProcessIdentity: ExternalProcessIdentity?
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
        setStatus("请在系统设置中允许 Helm Demo 使用辅助功能，然后再次启用。", log: true)
      } else {
        setStatus("请先从 Helm 界面请求辅助功能权限，再使用手柄启用控制。", log: true)
      }
      return
    }
    controlsEnabled = true
    resetMotionState()
    InputInjector.beginPointerSession()
    updateLatencyActivity()
    setStatus("控制已启用。固定安全组合键可随时紧急停止。", log: true)
    playHaptic(.controlEnabled)
  }

  func requestAccessibility() {
    _ = InputInjector.accessibilityTrusted(prompt: true)
    setStatus("已打开辅助功能授权流程。授权后返回 Helm 并点“刷新”。", log: true)
  }

  func requestVoicePermissions() {
    if microphoneAuthorization == .notDetermined {
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
        Task { @MainActor in
          self?.refreshPermissionState()
          self?.requestSpeechPermissionIfNeeded()
        }
      }
    } else {
      requestSpeechPermissionIfNeeded()
    }
    setStatus("正在按顺序请求麦克风与语音识别权限。", log: true)
  }

  func refreshEnvironment(forceAudio: Bool = true) {
    refreshPermissionState()
    if forceAudio { refreshAudioDevices() }
  }

  func beginVoiceTest() {
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
      setStatus("未找到可恢复的外部文本焦点；识别结果只会保留在 Helm 中。", log: true)
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
      setStatus("请在识别完成后重新聚焦外部文本框，再返回 Helm 发送。", log: true)
      return
    }

    invalidateVoiceTextDelivery()
    manualDeliveryActivationBaseline = focusHistory.activationGeneration
    voiceInsertionTarget = targetIdentity.processIdentifier
    voiceInsertionProcessIdentity = targetIdentity
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
    let voiceActive = isListening || voiceFinalizing || !pushToTalkSources.isEmpty
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
    cadenceDriver.stop()
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
    lastTick = ProcessInfo.processInfo.systemUptime
    nextPermissionRefresh = lastTick + 1
    nextAudioRefresh = lastTick + 3
    nextDiagnosticsRefresh = lastTick
    cadenceMeasurementStartedAt = lastTick
    cadenceTickCount = 0
    inputCadenceLabel = cadenceDriver.start(rate: inputPollingRate) { [weak self] in
      self?.tick()
    }
    appendActivity("输入节拍：\(inputCadenceLabel)")
  }

  private func requestSpeechPermissionIfNeeded() {
    guard speechAuthorization == .notDetermined else {
      refreshPermissionState()
      return
    }
    SFSpeechRecognizer.requestAuthorization { [weak self] _ in
      Task { @MainActor in self?.refreshPermissionState() }
    }
  }

  private func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = now - lastTick
    lastTick = now
    cadenceTickCount += 1
    let cadenceElapsed = now - cadenceMeasurementStartedAt
    if cadenceElapsed >= 1 {
      let roundedRate = Double(Int((Double(cadenceTickCount) / cadenceElapsed).rounded()))
      if measuredInputRate != roundedRate { measuredInputRate = roundedRate }
      cadenceMeasurementStartedAt = now
      cadenceTickCount = 0
    }

    let hasActiveInput = controlsEnabled || isListening || voiceFinalizing
      || leftMouseDown || rightMouseDown || !pushToTalkSources.isEmpty
    if TimerGapPolicy.shouldEmergencyStop(
      elapsed: elapsed,
      hasActiveInput: hasActiveInput
    ) {
      emergencyStop(reason: "检测到系统睡眠/超长定时器间隔")
    } else if elapsed > ControlMath.maximumTimerGap {
      resetMotionIntegrationState()
    }

    var processed = 0
    var event = HelmSDLEvent()
    while processed < 512, HelmSDLPoll(&event) {
      handle(event, now: now)
      processed += 1
      event = HelmSDLEvent()
    }

    var analog = HelmSDLAnalogState()
    if controllerConnected, HelmSDLReadAnalogState(&analog) {
      analogState.applyPolledSample(
        ControllerAnalogSample(
          leftX: Double(analog.left_x),
          leftY: Double(analog.left_y),
          rightY: Double(analog.right_y),
          leftTrigger: Double(analog.left_trigger),
          rightTrigger: Double(analog.right_trigger)
        )
      )
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

    if controllerConnected, controlsEnabled, accessibilityGranted, !isRecordingMapping {
      let safeElapsed = TimerGapPolicy.integrationDeltaTime(elapsed: elapsed)
      let pointerVector = pointerFilter.update(
        x: analogState.leftX,
        y: analogState.leftY,
        deadZone: ControlMath.stickDeadZone,
        responseExponent: stickResponseExponent,
        responseTime: stickSmoothingMilliseconds / 1_000,
        deltaTime: safeElapsed
      )
      let stickMagnitude = hypot(pointerVector.x, pointerVector.y)
      if stickMagnitude > 0 {
        if leftStickActiveSince == nil { leftStickActiveSince = now }
      } else {
        leftStickActiveSince = nil
      }
      let holdDuration = leftStickActiveSince.map { max(now - $0, 0) } ?? 0
      let pointer = ControlMath.integratedStickPointerDelta(
        x: pointerVector.x,
        y: pointerVector.y,
        gain: pointerGain * currentRacingSpeedMultiplier,
        maximumSpeed: ControlMath.stickPointerMaximumSpeed,
        holdDuration: holdDuration,
        accelerationDuration: stickAccelerationDuration,
        maximumBoost: stickMaximumBoost,
        deltaTime: safeElapsed
      )
      if pointer != .zero {
        InputInjector.movePointer(
          dx: pointer.x,
          dy: pointer.y,
          leftButtonDown: leftMouseDown,
          rightButtonDown: rightMouseDown
        )
      }

      let scrollVector = scrollFilter.update(
        x: 0,
        y: analogState.rightY,
        deadZone: ControlMath.scrollStickDeadZone,
        responseExponent: stickResponseExponent,
        responseTime: stickSmoothingMilliseconds / 1_000,
        deltaTime: safeElapsed
      )
      let scroll = ControlMath.continuousScrollDelta(
        axis: scrollVector.y,
        deadZone: 0,
        gain: scrollGain * currentRacingSpeedMultiplier,
        deltaTime: safeElapsed
      )
      let scrollSample = scrollAccumulator.update(precisePixels: scroll)
      if scrollSample != .zero { InputInjector.scroll(sample: scrollSample) }
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
    updateLatencyActivity()
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
        if nextState { playHaptic(.primaryAction) }
      }
    case .secondaryClick:
      guard accessibilityGranted else { return }
      if pressed { rightMouseSources.insert(source) } else { rightMouseSources.remove(source) }
      let nextState = !rightMouseSources.isEmpty
      if nextState != rightMouseDown {
        rightMouseDown = nextState
        InputInjector.mouseButton(.right, pressed: nextState)
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

  private func updatePushToTalkSource(
    _ source: UInt64,
    pressed: Bool,
    commitOnRelease: Bool,
    label: String
  ) {
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
      VoiceSessionPolicy.canBeginAfterEnvironmentRefresh(
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
    lastCompletedTranscript = nil
    manualDeliveryActivationBaseline = nil
    voiceInsertionProcessIdentity = nil
    let helmProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    let currentProcessIdentifier =
      NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    voiceInsertionTarget = focusHistory.insertionTarget(
      currentProcessIdentifier: currentProcessIdentifier,
      helmProcessIdentifier: helmProcessIdentifier
    )
    activeVoiceDeliveryToken = voiceDeliveryGeneration.begin()
    defer {
      lastTick = ProcessInfo.processInfo.systemUptime
      resetMotionIntegrationState()
    }
    do {
      let sampleRate = try voice.start(
        deviceID: selectedAudioDeviceID,
        localeIdentifier: localeIdentifier,
        onPartial: { [weak self] text in
          self?.transcript = text
        },
        onComplete: { [weak self] text, error in
          self?.voiceCompleted(text: text, error: error)
        }
      )
      lastAudioSampleRate = sampleRate
      activeVoiceAudioDevice = selectedDevice
      transcript = "正在聆听…"
      isListening = true
      updateLatencyActivity()
      setStatus(
        "PTT 已开始（\(source) · \(selectedAudioDeviceName) · \(Int(sampleRate)) Hz）",
        log: true
      )
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
    guard isListening else { return }
    isListening = false
    voiceFinalizing = commit
    updateLatencyActivity()
    setStatus(commit ? "PTT 已释放，正在完成识别…" : "PTT 已停止（\(source)）", log: true)
    playHaptic(.voiceStop)
    voice.stop(commit: commit)
  }

  private func voiceCompleted(text: String?, error: String?) {
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
        invalidateVoiceTextDelivery()
        setStatus("未能确认外部文本焦点；识别文本只保留在 Helm 中。", log: true)
      } else if autoInsert {
        if let deliveryToken {
          deliverRecognizedText(text, token: deliveryToken, attemptsRemaining: 12)
        } else {
          setStatus("语音目标会话已失效；文本保留在 Helm 中。", log: true)
        }
      } else {
        invalidateVoiceTextDelivery()
        setStatus("语音识别完成，自动写入已关闭。", log: true)
      }
    } else if let error, !error.isEmpty {
      invalidateVoiceTextDelivery()
      setStatus("语音识别结束：\(error)", log: true)
    } else {
      invalidateVoiceTextDelivery()
      setStatus("没有识别到可用文本。", log: true)
    }
    nextAudioRefresh = 0
  }

  private func deliverRecognizedText(
    _ text: String,
    token: UInt64,
    attemptsRemaining: Int
  ) {
    guard activeVoiceDeliveryToken == token, voiceDeliveryGeneration.accepts(token) else { return }
    let helmProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    let currentProcessIdentifier =
      NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let target = VoiceInsertionTargetPolicy.deliveryTarget(
      capturedProcessIdentifier: voiceInsertionTarget,
      currentProcessIdentifier: currentProcessIdentifier,
      helmProcessIdentifier: helmProcessIdentifier
    )

    guard let target, target > 0, target != helmProcessIdentifier else {
      invalidateVoiceTextDelivery()
      setStatus("未找到外部文本目标；识别文本只保留在 Helm 中。", log: true)
      return
    }

    if let expectedIdentity = voiceInsertionProcessIdentity,
      !runningApplicationMatches(expectedIdentity)
    {
      invalidateVoiceTextDelivery()
      setStatus("外部目标进程已经更换；为避免误写，文本保留在 Helm 中。", log: true)
      return
    }

    if currentProcessIdentifier != target {
      guard let nextAttemptCount = VoiceTextDeliveryRetryPolicy.nextAttemptCount(
        from: attemptsRemaining
      ),
        let application = NSRunningApplication(processIdentifier: target),
        !application.isTerminated
      else {
        invalidateVoiceTextDelivery()
        setStatus("外部目标应用未能恢复焦点；识别文本只保留在 Helm 中。", log: true)
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

    let result = InputInjector.insertAtFocusedTextElement(
      text,
      expectedProcessIdentifier: target
    )
    switch result {
    case .inserted(let method):
      invalidateVoiceTextDelivery()
      setStatus("识别文本已写入外部文本框（\(method)）。", log: true)
    case .dispatched(let method):
      invalidateVoiceTextDelivery()
      setStatus("已向外部焦点发送\(method)；请确认文本是否出现。", log: true)
    case .retryable(let reason):
      guard let nextAttemptCount = VoiceTextDeliveryRetryPolicy.nextAttemptCount(
        from: attemptsRemaining
      ) else {
        invalidateVoiceTextDelivery()
        setStatus("\(reason)；重试已用尽，文本保留在 Helm 中。", log: true)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
        self?.deliverRecognizedText(
          text,
          token: token,
          attemptsRemaining: nextAttemptCount
        )
      }
    case .refused(let reason):
      invalidateVoiceTextDelivery()
      setStatus("\(reason)；文本保留在 Helm 中。", log: true)
    }
  }

  private func invalidateVoiceTextDelivery() {
    voiceDeliveryGeneration.invalidate()
    activeVoiceDeliveryToken = nil
    voiceInsertionTarget = nil
    voiceInsertionProcessIdentity = nil
    if lastCompletedTranscript != nil {
      manualDeliveryActivationBaseline = focusHistory.activationGeneration
    }
  }

  private func emergencyStop(reason: String, announce: Bool = true) {
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
    leftStickActiveSince = nil
    pointerFilter.reset()
    scrollFilter.reset()
    scrollAccumulator.reset()
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
          ? "有线手柄已从音频重枚举中恢复；PTT 与识别保持运行。"
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
    setStatus("检测到 \(name)，请检查权限后启用控制。", log: true)
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
    setStatus("检测到有线手柄音频重枚举；保留 PTT，等待 1.2 秒内自动恢复。", log: true)
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

  private func releaseInjectedInputsPreservingControlSession() {
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
        reason: "Helm controller and push-to-talk input"
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
      voice.cancelCurrent()
      isListening = false
      voiceFinalizing = false
      activeVoiceAudioDevice = nil
      pushToTalkSources.removeAll()
      invalidateVoiceTestSession()
      invalidateVoiceTextDelivery()
      suppressAutoInsertForCurrentVoice = false
      updateLatencyActivity()
      setStatus("语音权限已失效，PTT 已安全停止。", log: true)
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
        voice.cancelCurrent()
        isListening = false
        voiceFinalizing = false
        activeVoiceAudioDevice = nil
        pushToTalkSources.removeAll()
        invalidateVoiceTestSession()
        invalidateVoiceTextDelivery()
        suppressAutoInsertForCurrentVoice = false
        updateLatencyActivity()
        setStatus("选择的麦克风已拔出，PTT 已停止；未自动切换。", log: true)
      }
      selectedAudioDeviceID = 0
    }
    if protectPlaybackAudio { enforcePlaybackProtection(announce: false) }
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
      setStatus("外部应用未在 0.5 秒内恢复焦点；识别结果只会保留在 Helm 中。", log: true)
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
