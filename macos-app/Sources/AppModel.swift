import AVFoundation
import AppKit
import Combine
import CoreAudio
import CoreGraphics
import Foundation
import Speech

@MainActor
final class AppModel: ObservableObject {
  private static let interfaceVoiceSource: Int32 = -1

  @Published var controllerConnected = false
  @Published var controllerName = "未连接 DualSense"
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
  @Published var pointerGain = 1.0 {
    didSet { UserDefaults.standard.set(pointerGain, forKey: "pointerGain") }
  }
  @Published var scrollGain = 8.0 {
    didSet { UserDefaults.standard.set(scrollGain, forKey: "scrollGain") }
  }
  @Published var inputPollingRate = 120.0 {
    didSet {
      UserDefaults.standard.set(inputPollingRate, forKey: "inputPollingRate")
      if started { installTimer() }
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
  @Published var mapping = ControllerMapping.standard {
    didSet {
      if mapping != oldValue { mappingDidChange() }
    }
  }
  @Published var latestInput = "等待手柄连接"
  @Published var statusMessage = "Helm 已就绪；启动时不会注入输入或录音。"
  @Published var activity: [String] = []
  @Published var audioDevices: [AudioInputDevice] = []
  @Published var selectedAudioDeviceID = AudioDeviceID(0)

  private let voice = VoiceService()
  private var timer: Timer?
  private var terminationObserver: NSObjectProtocol?
  private var started = false
  private var lastTick = ProcessInfo.processInfo.systemUptime
  private var nextPermissionRefresh = 0.0
  private var nextAudioRefresh = 0.0
  private var leftStickX = 0.0
  private var leftStickY = 0.0
  private var leftStickActiveSince: TimeInterval?
  private var rightYAxis = 0.0
  private var scrollRemainder = 0.0
  private var lastTouch: CGPoint?
  private var lastTouchTime: TimeInterval?
  private var optionsPressedAt: TimeInterval?
  private var leftMouseDown = false
  private var rightMouseDown = false
  private var leftMouseSources = Set<Int32>()
  private var rightMouseSources = Set<Int32>()
  private var pushToTalkSources = Set<Int32>()
  private var audioSelectionInitialized = false

  init() {
    let defaults = UserDefaults.standard
    if let value = defaults.object(forKey: "pointerGain") as? Double {
      pointerGain = min(max(value, 0.45), 2.2)
    }
    if let value = defaults.object(forKey: "scrollGain") as? Double {
      scrollGain = min(max(value, 2), 18)
    }
    if let value = defaults.object(forKey: "inputPollingRate") as? Double {
      inputPollingRate = min(max(value, 60), 240)
    }
    if let value = defaults.object(forKey: "stickAccelerationDuration") as? Double {
      stickAccelerationDuration = min(max(value, 0.4), 3.5)
    }
    if let value = defaults.object(forKey: "stickMaximumBoost") as? Double {
      stickMaximumBoost = min(max(value, 1), 3)
    }
    if let data = defaults.data(forKey: "controllerMapping"),
      let decoded = try? JSONDecoder().decode(ControllerMapping.self, from: data)
    {
      mapping = decoded
    }
  }

  var selectedAudioDeviceName: String {
    audioDevices.first(where: { $0.id == selectedAudioDeviceID })?.name ?? "未选择麦克风"
  }

  var canEnable: Bool {
    controllerConnected && accessibilityGranted
  }

  var voicePermissionsGranted: Bool {
    microphoneAuthorization == .authorized && speechAuthorization == .authorized
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

    installTimer()

    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.shutdown()
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
    setStatus("控制已启用。Options + 触控板可随时紧急停止。", log: true)
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
    updatePushToTalkSource(
      Self.interfaceVoiceSource,
      pressed: true,
      commitOnRelease: true,
      label: "界面测试"
    )
  }

  func endVoiceTest() {
    updatePushToTalkSource(
      Self.interfaceVoiceSource,
      pressed: false,
      commitOnRelease: true,
      label: "界面测试"
    )
  }

  func cancelVoiceTest() {
    updatePushToTalkSource(
      Self.interfaceVoiceSource,
      pressed: false,
      commitOnRelease: false,
      label: "界面测试中断"
    )
  }

  func clearTranscript() {
    transcript = ""
  }

  func restoreDefaultMappings() {
    mapping = .standard
    setStatus("已恢复默认按键映射。", log: true)
  }

  func openAccessibilitySettings() {
    InputInjector.openAccessibilitySettings()
  }

  func openSoundSettings() {
    InputInjector.openSoundSettings()
  }

  func shutdown() {
    timer?.invalidate()
    timer = nil
    emergencyStop(reason: "应用退出")
    HelmSDLStop()
    if let terminationObserver {
      NotificationCenter.default.removeObserver(terminationObserver)
      self.terminationObserver = nil
    }
  }

  private func installTimer() {
    timer?.invalidate()
    let rate = min(max(inputPollingRate, 60), 240)
    let interval = 1.0 / rate
    lastTick = ProcessInfo.processInfo.systemUptime
    nextPermissionRefresh = lastTick + 1
    nextAudioRefresh = lastTick + 3
    let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.tick()
      }
    }
    newTimer.tolerance = min(interval * 0.05, 0.001)
    timer = newTimer
    RunLoop.main.add(newTimer, forMode: .common)
    appendActivity("输入轮询率：" + String(Int(rate)) + " Hz")
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

    if let optionsPressedAt, now - optionsPressedAt > ControlMath.safetyChordWindow {
      self.optionsPressedAt = nil
    }

    if elapsed > ControlMath.maximumTimerGap {
      if controlsEnabled || isListening || leftMouseDown || rightMouseDown {
        emergencyStop(reason: "检测到睡眠/长定时器间隔")
      } else {
        resetMotionState()
      }
    }

    var processed = 0
    var event = HelmSDLEvent()
    while processed < 512, HelmSDLPoll(&event) {
      handle(event, now: now)
      processed += 1
      event = HelmSDLEvent()
    }

    if controlsEnabled, accessibilityGranted {
      let stickMagnitude = hypot(leftStickX, leftStickY)
      if stickMagnitude > ControlMath.stickDeadZone {
        if leftStickActiveSince == nil { leftStickActiveSince = now }
      } else {
        leftStickActiveSince = nil
      }
      let holdDuration = leftStickActiveSince.map { max(now - $0, 0) } ?? 0
      let pointer = ControlMath.stickPointerDelta(
        x: leftStickX,
        y: leftStickY,
        deadZone: ControlMath.stickDeadZone,
        gain: pointerGain,
        maximumSpeed: ControlMath.stickPointerMaximumSpeed,
        holdDuration: holdDuration,
        accelerationDuration: stickAccelerationDuration,
        maximumBoost: stickMaximumBoost,
        deltaTime: min(elapsed, ControlMath.maximumTimerGap)
      )
      if pointer != .zero {
        InputInjector.movePointer(
          dx: pointer.x,
          dy: pointer.y,
          leftButtonDown: leftMouseDown,
          rightButtonDown: rightMouseDown
        )
      }

      let scroll = ControlMath.scrollDelta(
        axis: rightYAxis,
        deadZone: 0.18,
        gain: scrollGain,
        deltaTime: min(elapsed, ControlMath.maximumTimerGap),
        remainder: &scrollRemainder
      )
      if scroll != 0 { InputInjector.scroll(pixels: scroll) }
    }

    if now >= nextPermissionRefresh {
      refreshPermissionState()
      microphoneButtonAvailable = controllerConnected && HelmSDLHasMicrophoneButton()
      touchpadCount = controllerConnected ? HelmSDLTouchpadCount() : 0
      nextPermissionRefresh = now + 1
    }
    if now >= nextAudioRefresh {
      refreshAudioDevices()
      nextAudioRefresh = now + 3
    }
  }

  private func handle(_ sourceEvent: HelmSDLEvent, now: TimeInterval) {
    var event = sourceEvent
    switch event.kind {
    case Int32(HELM_SDL_EVENT_CONNECTED):
      controllerConnected = true
      controllerName = bridgeString(&event)
      connectionLabel = connectionName(HelmSDLConnectionState())
      microphoneButtonAvailable = HelmSDLHasMicrophoneButton()
      touchpadCount = HelmSDLTouchpadCount()
      emergencyStop(reason: "手柄已连接，等待显式启用", announce: false)
      latestInput = "已连接 \(controllerName)"
      setStatus("检测到 \(controllerName)，请检查权限后启用控制。", log: true)

    case Int32(HELM_SDL_EVENT_DISCONNECTED):
      emergencyStop(reason: "手柄已断开")
      controllerConnected = false
      controllerName = "未连接 DualSense"
      connectionLabel = "—"
      microphoneButtonAvailable = false
      touchpadCount = 0
      latestInput = "手柄已断开"

    case Int32(HELM_SDL_EVENT_BUTTON):
      handleButton(event.button, pressed: event.pressed != 0, now: now)

    case Int32(HELM_SDL_EVENT_RIGHT_Y):
      rightYAxis = Double(event.value)
      if abs(rightYAxis) > 0.18 {
        latestInput = String(format: "右摇杆 Y  %.2f", rightYAxis)
      }

    case Int32(HELM_SDL_EVENT_LEFT_STICK):
      leftStickX = Double(event.x)
      leftStickY = Double(event.y)
      if hypot(leftStickX, leftStickY) > ControlMath.stickDeadZone {
        latestInput = String(format: "左摇杆  %.2f, %.2f", leftStickX, leftStickY)
      } else {
        latestInput = "左摇杆居中"
      }

    case Int32(HELM_SDL_EVENT_TOUCH_DOWN):
      if event.finger == 0 {
        lastTouch = CGPoint(x: Double(event.x), y: Double(event.y))
        lastTouchTime = now
        latestInput = "触控板按下"
      }

    case Int32(HELM_SDL_EVENT_TOUCH_MOVE):
      handleTouchMove(event, now: now)

    case Int32(HELM_SDL_EVENT_TOUCH_UP):
      if event.finger == 0 {
        lastTouch = nil
        lastTouchTime = nil
        latestInput = "触控板抬起"
      }

    case Int32(HELM_SDL_EVENT_ERROR):
      setStatus("SDL3：\(bridgeString(&event))", log: true)

    default:
      break
    }
  }

  private func handleButton(_ button: Int32, pressed: Bool, now: TimeInterval) {
    let state = pressed ? "按下" : "抬起"
    switch button {
    case Int32(HELM_BUTTON_OPTIONS):
      optionsPressedAt = pressed ? now : nil
      latestInput = "Options \(state)"

    case Int32(HELM_BUTTON_TOUCHPAD):
      latestInput = "触控板键 \(state)"
      if pressed,
        ControlMath.safetyChordIsValid(
          modifierPressedAt: optionsPressedAt,
          buttonPressedAt: now
        )
      {
        toggleControls(promptForAccessibility: false)
        optionsPressedAt = nil
      }

    case Int32(HELM_BUTTON_CROSS):
      handleMappedButton(button, label: "Cross", action: mapping.cross, pressed: pressed)

    case Int32(HELM_BUTTON_CIRCLE):
      handleMappedButton(button, label: "Circle", action: mapping.circle, pressed: pressed)

    case Int32(HELM_BUTTON_CREATE):
      handleMappedButton(button, label: "Create", action: mapping.create, pressed: pressed)

    case Int32(HELM_BUTTON_MICROPHONE):
      handleMappedButton(button, label: "麦克风键", action: mapping.microphone, pressed: pressed)

    case Int32(HELM_BUTTON_DPAD_UP):
      handleMappedButton(button, label: "D-pad 上", action: mapping.dpadUp, pressed: pressed)

    case Int32(HELM_BUTTON_DPAD_DOWN):
      handleMappedButton(button, label: "D-pad 下", action: mapping.dpadDown, pressed: pressed)

    default:
      break
    }
  }

  private func handleMappedButton(
    _ source: Int32,
    label: String,
    action: ControllerAction,
    pressed: Bool
  ) {
    latestInput = "\(label) \(pressed ? "按下" : "抬起") → \(action.title)"
    guard controlsEnabled else { return }

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
      }
    case .secondaryClick:
      guard accessibilityGranted else { return }
      if pressed { rightMouseSources.insert(source) } else { rightMouseSources.remove(source) }
      let nextState = !rightMouseSources.isEmpty
      if nextState != rightMouseDown {
        rightMouseDown = nextState
        InputInjector.mouseButton(.right, pressed: nextState)
      }
    case .pageUp:
      if pressed, accessibilityGranted { InputInjector.page(direction: 1) }
    case .pageDown:
      if pressed, accessibilityGranted { InputInjector.page(direction: -1) }
    case .pushToTalk:
      updatePushToTalkSource(
        source,
        pressed: pressed,
        commitOnRelease: true,
        label: label
      )
    }
  }

  private func updatePushToTalkSource(
    _ source: Int32,
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
      gain: pointerGain * 0.65,
      acceleration: 0.18,
      maximum: 90
    )
    InputInjector.movePointer(
      dx: delta.x,
      dy: delta.y,
      leftButtonDown: leftMouseDown,
      rightButtonDown: rightMouseDown
    )
    latestInput = String(format: "触控板  Δ %.0f, %.0f", delta.x, delta.y)
  }

  private func beginVoice(source: String) {
    guard !isListening else { return }
    refreshPermissionState()
    guard voicePermissionsGranted else {
      setStatus("请先授予麦克风和语音识别权限。", log: true)
      return
    }
    guard selectedAudioDeviceID != 0,
      audioDevices.contains(where: { $0.id == selectedAudioDeviceID })
    else {
      setStatus("请选择一个当前可用的麦克风。", log: true)
      return
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
      transcript = "正在聆听…"
      isListening = true
      setStatus(
        "PTT 已开始（\(source) · \(selectedAudioDeviceName) · \(Int(sampleRate)) Hz）",
        log: true
      )
    } catch {
      isListening = false
      setStatus("无法开始语音输入：\(error.localizedDescription)", log: true)
    }
  }

  private func endVoice(commit: Bool, source: String) {
    guard isListening else { return }
    isListening = false
    voice.stop(commit: commit)
    setStatus(commit ? "PTT 已释放，正在完成识别…" : "PTT 已停止（\(source)）", log: true)
  }

  private func voiceCompleted(text: String?, error: String?) {
    isListening = false
    if let text, !text.isEmpty {
      transcript = text
      if autoInsert {
        switch InputInjector.insertAtFocusedTextElement(text) {
        case .inserted:
          setStatus("识别文本已写入当前文本框。", log: true)
        case .refused(let reason):
          setStatus("\(reason)；文本保留在 Helm 中。", log: true)
        }
      } else {
        setStatus("语音识别完成，自动写入已关闭。", log: true)
      }
    } else if let error, !error.isEmpty {
      setStatus("语音识别结束：\(error)", log: true)
    } else {
      setStatus("没有识别到可用文本。", log: true)
    }
  }

  private func emergencyStop(reason: String, announce: Bool = true) {
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
    pushToTalkSources.removeAll()
    voice.cancelCurrent()
    isListening = false
    controlsEnabled = false
    optionsPressedAt = nil
    resetMotionState()
    if announce { setStatus("控制已安全停用：\(reason)", log: true) }
  }

  private func resetMotionState() {
    leftStickX = 0
    leftStickY = 0
    leftStickActiveSince = nil
    rightYAxis = 0
    scrollRemainder = 0
    lastTouch = nil
    lastTouchTime = nil
  }

  private func mappingDidChange() {
    if let data = try? JSONEncoder().encode(mapping) {
      UserDefaults.standard.set(data, forKey: "controllerMapping")
    }
    if controlsEnabled || leftMouseDown || rightMouseDown || !pushToTalkSources.isEmpty {
      emergencyStop(reason: "按键映射已更新")
    } else if started {
      setStatus("按键映射已保存。", log: true)
    }
  }

  private func refreshPermissionState() {
    let access = InputInjector.accessibilityTrusted()
    let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    let speech = SFSpeechRecognizer.authorizationStatus()
    accessibilityGranted = access
    microphoneAuthorization = microphone
    speechAuthorization = speech

    if controlsEnabled, !access {
      emergencyStop(reason: "辅助功能权限已失效")
    } else if isListening, microphone != .authorized || speech != .authorized {
      voice.stop(commit: false)
      isListening = false
      setStatus("语音权限已失效，PTT 已安全停止。", log: true)
    }
  }

  private func refreshAudioDevices() {
    let refreshed = AudioInputCatalog.devices()
    let previousSelection = selectedAudioDeviceID
    audioDevices = refreshed
    if !audioSelectionInitialized {
      audioSelectionInitialized = true
      selectedAudioDeviceID = refreshed.first(where: { $0.isDefault })?.id ?? 0
    } else if previousSelection != 0,
      !refreshed.contains(where: { $0.id == previousSelection })
    {
      if isListening {
        voice.stop(commit: false)
        isListening = false
        setStatus("选择的麦克风已拔出，PTT 已停止；未自动切换。", log: true)
      }
      selectedAudioDeviceID = 0
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
