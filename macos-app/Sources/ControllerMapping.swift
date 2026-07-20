import Foundation

enum ShortcutKey: String, CaseIterable, Codable, Identifiable {
  case a
  case d
  case m
  case s
  case v
  case space
  case returnKey
  case f1
  case f2
  case f3
  case f4
  case f5
  case f6
  case f7
  case f8
  case f9
  case f10
  case f11
  case f12

  var id: String { rawValue }

  var title: String {
    switch self {
    case .space: return "Space"
    case .returnKey: return "Return"
    case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
      return rawValue.uppercased()
    default:
      return rawValue.uppercased()
    }
  }

  var virtualKeyCode: UInt16 {
    switch self {
    case .a: return 0
    case .d: return 2
    case .m: return 46
    case .s: return 1
    case .v: return 9
    case .space: return 49
    case .returnKey: return 36
    case .f1: return 122
    case .f2: return 120
    case .f3: return 99
    case .f4: return 118
    case .f5: return 96
    case .f6: return 97
    case .f7: return 98
    case .f8: return 100
    case .f9: return 101
    case .f10: return 109
    case .f11: return 103
    case .f12: return 111
    }
  }
}

enum ModifierSide: String, CaseIterable, Codable, Identifiable {
  case none
  case left
  case right

  var id: String { rawValue }

  func virtualKeyCode(left: UInt16, right: UInt16) -> UInt16? {
    switch self {
    case .none: return nil
    case .left: return left
    case .right: return right
    }
  }

  func label(symbol: String) -> String {
    switch self {
    case .none: return ""
    case .left: return symbol
    case .right: return "右\(symbol)"
    }
  }
}

struct KeyboardShortcutDefinition: Codable, Equatable {
  var key: ShortcutKey?
  var commandSide: ModifierSide
  var optionSide: ModifierSide
  var controlSide: ModifierSide
  var shiftSide: ModifierSide

  init(
    key: ShortcutKey?,
    command: Bool,
    option: Bool,
    control: Bool,
    shift: Bool
  ) {
    self.init(
      key: key,
      commandSide: command ? .left : .none,
      optionSide: option ? .left : .none,
      controlSide: control ? .left : .none,
      shiftSide: shift ? .left : .none
    )
  }

  init(
    key: ShortcutKey?,
    commandSide: ModifierSide,
    optionSide: ModifierSide,
    controlSide: ModifierSide,
    shiftSide: ModifierSide
  ) {
    self.key = key
    self.commandSide = commandSide
    self.optionSide = optionSide
    self.controlSide = controlSide
    self.shiftSide = shiftSide
  }

  var command: Bool {
    get { commandSide != .none }
    set { commandSide = newValue ? (commandSide == .none ? .left : commandSide) : .none }
  }

  var option: Bool {
    get { optionSide != .none }
    set { optionSide = newValue ? (optionSide == .none ? .left : optionSide) : .none }
  }

  var control: Bool {
    get { controlSide != .none }
    set { controlSide = newValue ? (controlSide == .none ? .left : controlSide) : .none }
  }

  var shift: Bool {
    get { shiftSide != .none }
    set { shiftSide = newValue ? (shiftSide == .none ? .left : shiftSide) : .none }
  }

  var hasModifier: Bool {
    command || option || control || shift
  }

  var isModifierOnly: Bool {
    key == nil && hasModifier
  }

  var modifierVirtualKeyCodes: [UInt16] {
    [
      controlSide.virtualKeyCode(left: 59, right: 62),
      optionSide.virtualKeyCode(left: 58, right: 61),
      shiftSide.virtualKeyCode(left: 56, right: 60),
      commandSide.virtualKeyCode(left: 55, right: 54),
    ].compactMap { $0 }
  }

  var label: String {
    let rendered = controlSide.label(symbol: "⌃")
      + optionSide.label(symbol: "⌥")
      + shiftSide.label(symbol: "⇧")
      + commandSide.label(symbol: "⌘")
      + (key?.title ?? "")
    return rendered.isEmpty ? "未设置" : rendered
  }

  private enum CodingKeys: String, CodingKey {
    case key
    case commandSide
    case optionSide
    case controlSide
    case shiftSide
    case command
    case option
    case control
    case shift
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decodeIfPresent(ShortcutKey.self, forKey: .key)
    if container.contains(.commandSide) || container.contains(.optionSide)
      || container.contains(.controlSide) || container.contains(.shiftSide)
    {
      commandSide = try container.decodeIfPresent(ModifierSide.self, forKey: .commandSide) ?? .none
      optionSide = try container.decodeIfPresent(ModifierSide.self, forKey: .optionSide) ?? .none
      controlSide = try container.decodeIfPresent(ModifierSide.self, forKey: .controlSide) ?? .none
      shiftSide = try container.decodeIfPresent(ModifierSide.self, forKey: .shiftSide) ?? .none
    } else {
      commandSide = try container.decodeIfPresent(Bool.self, forKey: .command) == true ? .left : .none
      optionSide = try container.decodeIfPresent(Bool.self, forKey: .option) == true ? .left : .none
      controlSide = try container.decodeIfPresent(Bool.self, forKey: .control) == true ? .left : .none
      shiftSide = try container.decodeIfPresent(Bool.self, forKey: .shift) == true ? .left : .none
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(key, forKey: .key)
    try container.encode(commandSide, forKey: .commandSide)
    try container.encode(optionSide, forKey: .optionSide)
    try container.encode(controlSide, forKey: .controlSide)
    try container.encode(shiftSide, forKey: .shiftSide)
  }
}

struct ModifierKeyTransition: Equatable {
  let virtualKeyCode: UInt16
  let pressed: Bool
  let activeModifierVirtualKeyCodes: [UInt16]
}

struct KeyboardEventStep: Equatable {
  let virtualKeyCode: UInt16
  let pressed: Bool
  let activeModifierVirtualKeyCodes: [UInt16]
}

enum KeyboardShortcutEventPlanner {
  static func plan(for shortcut: KeyboardShortcutDefinition) -> [KeyboardEventStep] {
    guard let key = shortcut.key else { return [] }
    let modifierCodes = shortcut.modifierVirtualKeyCodes
    var activeCodes: [UInt16] = []
    var steps: [KeyboardEventStep] = []

    for code in modifierCodes {
      activeCodes.append(code)
      steps.append(
        KeyboardEventStep(
          virtualKeyCode: code,
          pressed: true,
          activeModifierVirtualKeyCodes: activeCodes
        )
      )
    }
    steps.append(
      KeyboardEventStep(
        virtualKeyCode: key.virtualKeyCode,
        pressed: true,
        activeModifierVirtualKeyCodes: activeCodes
      )
    )
    steps.append(
      KeyboardEventStep(
        virtualKeyCode: key.virtualKeyCode,
        pressed: false,
        activeModifierVirtualKeyCodes: activeCodes
      )
    )
    for code in modifierCodes.reversed() {
      activeCodes.removeAll { $0 == code }
      steps.append(
        KeyboardEventStep(
          virtualKeyCode: code,
          pressed: false,
          activeModifierVirtualKeyCodes: activeCodes
        )
      )
    }
    return steps
  }
}

struct ModifierHoldCoordinator {
  private struct Source: Hashable {
    let slot: Int
    let source: UInt64
  }

  private static let canonicalCodes: [UInt16] = [59, 62, 58, 61, 56, 60, 55, 54]
  private var ownersByCode: [UInt16: Set<Source>] = [:]

  mutating func update(
    slot: Int,
    source: UInt64,
    modifierCodes: [UInt16],
    pressed: Bool
  ) -> [ModifierKeyTransition] {
    let owner = Source(slot: slot, source: source)
    let requestedCodes = Self.canonicalCodes.filter { modifierCodes.contains($0) }
    var transitions: [ModifierKeyTransition] = []

    if pressed {
      for code in requestedCodes {
        var owners = ownersByCode[code] ?? []
        let wasUnowned = owners.isEmpty
        let inserted = owners.insert(owner).inserted
        ownersByCode[code] = owners
        if inserted, wasUnowned {
          transitions.append(
            ModifierKeyTransition(
              virtualKeyCode: code,
              pressed: true,
              activeModifierVirtualKeyCodes: activeModifierCodes
            )
          )
        }
      }
      return transitions
    }

    for code in requestedCodes.reversed() {
      guard var owners = ownersByCode[code], owners.remove(owner) != nil else { continue }
      if owners.isEmpty {
        ownersByCode.removeValue(forKey: code)
        transitions.append(
          ModifierKeyTransition(
            virtualKeyCode: code,
            pressed: false,
            activeModifierVirtualKeyCodes: activeModifierCodes
          )
        )
      } else {
        ownersByCode[code] = owners
      }
    }
    return transitions
  }

  mutating func releaseAll(slot: Int) -> [ModifierKeyTransition] {
    let sources = Set(
      ownersByCode.values.flatMap { owners in
        owners.filter { $0.slot == slot }
      }
    ).sorted { $0.source < $1.source }
    var transitions: [ModifierKeyTransition] = []
    for source in sources {
      let codes = Self.canonicalCodes.filter { ownersByCode[$0]?.contains(source) == true }
      transitions.append(
        contentsOf: update(
          slot: source.slot,
          source: source.source,
          modifierCodes: codes,
          pressed: false
        )
      )
    }
    return transitions
  }

  mutating func reset() -> [ModifierKeyTransition] {
    let codes = activeModifierCodes
    ownersByCode.removeAll()
    var remaining = codes
    return codes.reversed().map { code in
      remaining.removeAll { $0 == code }
      return ModifierKeyTransition(
        virtualKeyCode: code,
        pressed: false,
        activeModifierVirtualKeyCodes: remaining
      )
    }
  }

  private var activeModifierCodes: [UInt16] {
    Self.canonicalCodes.filter { ownersByCode[$0]?.isEmpty == false }
  }
}

struct ControllerAnalogSample: Equatable {
  let leftX: Double
  let leftY: Double
  let rightY: Double
  let leftTrigger: Double
  let rightTrigger: Double
}

struct ControllerAnalogState: Equatable {
  var leftX = 0.0
  var leftY = 0.0
  var rightY = 0.0
  var leftTrigger = 0.0
  var rightTrigger = 0.0

  mutating func applyPolledSample(_ sample: ControllerAnalogSample) {
    leftX = min(max(sample.leftX, -1), 1)
    leftY = min(max(sample.leftY, -1), 1)
    rightY = min(max(sample.rightY, -1), 1)
    leftTrigger = min(max(sample.leftTrigger, 0), 1)
    rightTrigger = min(max(sample.rightTrigger, 0), 1)
  }

  mutating func reset() {
    self = ControllerAnalogState()
  }
}

struct ControllerShortcutSettings: Codable, Equatable {
  var slot1: KeyboardShortcutDefinition
  var slot2: KeyboardShortcutDefinition
  var slot3: KeyboardShortcutDefinition

  static let standard = ControllerShortcutSettings(
    slot1: KeyboardShortcutDefinition(
      key: .d,
      command: false,
      option: true,
      control: true,
      shift: false
    ),
    slot2: KeyboardShortcutDefinition(
      key: .space,
      command: false,
      option: false,
      control: true,
      shift: false
    ),
    slot3: KeyboardShortcutDefinition(
      key: .space,
      command: true,
      option: false,
      control: false,
      shift: true
    )
  )
}

enum ControllerFamily: String, Codable, CaseIterable {
  case playStation
  case xbox
  case nintendo
  case generic

  var title: String {
    switch self {
    case .playStation: return "PlayStation"
    case .xbox: return "Xbox"
    case .nintendo: return "Nintendo"
    case .generic: return "通用手柄"
    }
  }
}

enum ControllerConnection: Int32, Codable {
  case unknown = 0
  case wired = 1
  case wireless = 2
}

struct ControllerIdentity: Codable, Equatable {
  let family: ControllerFamily
  let vendorID: UInt16
  let productID: UInt16
}

enum VoiceSessionPolicy {
  static func canBeginAfterEnvironmentRefresh(hasPressOwner: Bool) -> Bool {
    hasPressOwner
  }

  static func isActiveForReconnect(isListening: Bool, isFinalizing: Bool) -> Bool {
    isListening || isFinalizing
  }

  static func isActiveForMappingCapture(
    isListening: Bool,
    isFinalizing: Bool,
    deliveryInProgress: Bool,
    restartPending: Bool,
    hasPressOwner: Bool
  ) -> Bool {
    isListening || isFinalizing || deliveryInProgress || restartPending || hasPressOwner
  }
}

enum VoiceInputMode: String, Codable, CaseIterable, Identifiable {
  case pushToTalk
  case alwaysOn
  case alwaysOff

  static let defaultMode = VoiceInputMode.pushToTalk

  var id: String { rawValue }

  var title: String {
    switch self {
    case .pushToTalk: return "按键模式"
    case .alwaysOn: return "常开"
    case .alwaysOff: return "常闭"
    }
  }

  var detail: String {
    switch self {
    case .pushToTalk: return "按住手柄键说话，松开后提交"
    case .alwaysOn: return "无需按键，自动分段提交并继续监听"
    case .alwaysOff: return "禁止麦克风采集"
    }
  }

  var automaticallyCommitsFinalRecognition: Bool {
    self == .alwaysOn
  }
}

enum VoiceModeTransitionAction: Equatable {
  case none
  case start
  case keepListening
  case stopAndCommit
  case stopWithoutCommit
  case restartAfterCompletion
}

enum VoiceCompletionOutcome: Equatable {
  case emptySegment
  case confirmedDelivery
  case unconfirmedDelivery
  case failure
}

enum VoiceInputModePolicy {
  static let maximumSegmentDuration: TimeInterval = 30

  static func canBegin(mode: VoiceInputMode, hasPressOwner: Bool) -> Bool {
    switch mode {
    case .pushToTalk: return hasPressOwner
    case .alwaysOn: return true
    case .alwaysOff: return false
    }
  }

  static func transition(
    from previousMode: VoiceInputMode,
    to mode: VoiceInputMode,
    isListening: Bool,
    isFinalizing: Bool,
    deliveryInProgress: Bool
  ) -> VoiceModeTransitionAction {
    guard mode != previousMode else { return .none }
    switch mode {
    case .alwaysOff:
      return isListening || isFinalizing || deliveryInProgress ? .stopWithoutCommit : .none
    case .pushToTalk:
      return previousMode == .alwaysOn && isListening ? .stopAndCommit : .none
    case .alwaysOn:
      if isListening { return .keepListening }
      if isFinalizing || deliveryInProgress { return .restartAfterCompletion }
      return .start
    }
  }

  static func shouldRestartAlwaysOn(
    mode: VoiceInputMode,
    outcome: VoiceCompletionOutcome
  ) -> Bool {
    guard mode == .alwaysOn else { return false }
    switch outcome {
    case .emptySegment, .confirmedDelivery: return true
    case .unconfirmedDelivery, .failure: return false
    }
  }
}

enum ControllerReconnectPolicy {
  static let graceInterval: TimeInterval = 1.2

  static func shouldWait(
    hasActiveVoiceSession: Bool,
    selectedAudioDevice: AudioInputDevice?,
    connection: ControllerConnection,
    controller: ControllerIdentity
  ) -> Bool {
    hasActiveVoiceSession
      && selectedAudioDevice?.isControllerRoutedUSB == true
      && canMigrateAudioRoute(connection: connection)
      && controller.family == .playStation
  }

  static func canMigrateAudioRoute(connection: ControllerConnection) -> Bool {
    connection != .wireless
  }

  static func canResume(
    expected: ControllerIdentity,
    candidate: ControllerIdentity
  ) -> Bool {
    expected == candidate
  }
}

enum LaunchControlAutoEnablePolicy {
  static let defaultEnabled = true
}

struct LaunchControlAutoEnableGate {
  private var pending: Bool

  init(settingEnabled: Bool, controllerAlreadyConnected: Bool) {
    pending = settingEnabled && controllerAlreadyConnected
  }

  mutating func consumeForConnection() -> Bool {
    let shouldEnable = pending
    pending = false
    return shouldEnable
  }
}

enum ControllerButton: Int32, CaseIterable, Codable, Identifiable {
  case south = 1
  case east
  case west
  case north
  case back
  case guide
  case start
  case leftStick
  case rightStick
  case leftShoulder
  case rightShoulder
  case dpadUp
  case dpadDown
  case dpadLeft
  case dpadRight
  case misc1
  case rightPaddle1
  case leftPaddle1
  case rightPaddle2
  case leftPaddle2
  case touchpad
  case misc2
  case misc3
  case misc4
  case misc5
  case misc6

  var id: Int32 { rawValue }

  static let professionalButtons: [ControllerButton] = [
    .rightPaddle1, .leftPaddle1, .rightPaddle2, .leftPaddle2,
  ]
}

enum SafetyChordPolicy {
  static func trigger(for family: ControllerFamily) -> ControllerButton {
    family == .playStation ? .touchpad : .back
  }

  static func isReserved(_ chord: ControllerChord, family _: ControllerFamily) -> Bool {
    let buttons = Set(chord.buttons)
    return buttons.contains(.start)
      && (buttons.contains(.touchpad) || buttons.contains(.back))
  }
}

struct SafetyChordTracker {
  private var pressedAt: [ControllerButton: TimeInterval] = [:]

  mutating func process(
    button: ControllerButton,
    pressed: Bool,
    family: ControllerFamily,
    now: TimeInterval
  ) -> Bool {
    let trigger = SafetyChordPolicy.trigger(for: family)
    guard button == .start || button == trigger else { return false }

    if !pressed {
      pressedAt.removeValue(forKey: button)
      return false
    }

    pressedAt = pressedAt.filter { now - $0.value <= ControlMath.safetyChordWindow }
    pressedAt[button] = now
    guard let start = pressedAt[.start], let action = pressedAt[trigger] else { return false }
    guard abs(start - action) <= ControlMath.safetyChordWindow else { return false }
    pressedAt.removeAll()
    return true
  }

  mutating func reset() {
    pressedAt.removeAll()
  }
}

enum ControllerPresentation {
  static func label(for button: ControllerButton, family: ControllerFamily) -> String {
    switch button {
    case .south:
      switch family {
      case .playStation: return "Cross"
      case .xbox: return "A"
      case .nintendo: return "B"
      case .generic: return "South"
      }
    case .east:
      switch family {
      case .playStation: return "Circle"
      case .xbox: return "B"
      case .nintendo: return "A"
      case .generic: return "East"
      }
    case .west:
      switch family {
      case .playStation: return "Square"
      case .xbox: return "X"
      case .nintendo: return "Y"
      case .generic: return "West"
      }
    case .north:
      switch family {
      case .playStation: return "Triangle"
      case .xbox: return "Y"
      case .nintendo: return "X"
      case .generic: return "North"
      }
    case .back:
      switch family {
      case .playStation: return "Create"
      case .xbox: return "View"
      case .nintendo: return "−"
      case .generic: return "Back"
      }
    case .guide: return "Guide"
    case .start:
      switch family {
      case .playStation: return "Options"
      case .xbox: return "Menu"
      case .nintendo: return "+"
      case .generic: return "Start"
      }
    case .leftStick: return "L3"
    case .rightStick: return "R3"
    case .leftShoulder: return family == .playStation ? "L1" : "LB"
    case .rightShoulder: return family == .playStation ? "R1" : "RB"
    case .dpadUp: return "D-pad ↑"
    case .dpadDown: return "D-pad ↓"
    case .dpadLeft: return "D-pad ←"
    case .dpadRight: return "D-pad →"
    case .misc1:
      switch family {
      case .playStation: return "麦克风键"
      case .xbox: return "Share"
      case .nintendo: return "Capture"
      case .generic: return "功能键 1"
      }
    case .rightPaddle1: return "右背键 1"
    case .leftPaddle1: return "左背键 1"
    case .rightPaddle2: return "右背键 2"
    case .leftPaddle2: return "左背键 2"
    case .touchpad: return "触控板键"
    case .misc2: return "功能键 2"
    case .misc3: return "功能键 3"
    case .misc4: return "功能键 4"
    case .misc5: return "功能键 5"
    case .misc6: return "功能键 6"
    }
  }
}

struct ControllerChord: Codable, Hashable {
  let buttons: [ControllerButton]

  init?(buttons: [ControllerButton]) {
    let canonical = Array(Set(buttons)).sorted { $0.rawValue < $1.rawValue }
    guard !canonical.isEmpty, canonical.count <= 4 else { return nil }
    self.buttons = canonical
  }

  var sourceID: UInt64 {
    buttons.reduce(0) { partial, button in
      partial | (UInt64(1) << UInt64(button.rawValue - 1))
    }
  }

  func isSatisfied(by pressed: Set<ControllerButton>) -> Bool {
    Set(buttons).isSubset(of: pressed)
  }

  func isAmbiguous(with other: ControllerChord) -> Bool {
    let own = Set(buttons)
    let candidate = Set(other.buttons)
    return own.isSubset(of: candidate) || candidate.isSubset(of: own)
  }

  func label(family: ControllerFamily) -> String {
    buttons.map { ControllerPresentation.label(for: $0, family: family) }.joined(separator: " + ")
  }
}

struct ControllerBinding: Codable, Equatable {
  var chord: ControllerChord
  var action: ControllerAction
}

struct ControllerActionTransition: Equatable {
  let chord: ControllerChord
  let action: ControllerAction
  let pressed: Bool
}

struct MappingCapturePlan: Equatable {
  let controlsEnabledAfterTransition: Bool
  let shouldStopVoice: Bool
  let shouldReleaseInjectedInputs: Bool
}

enum MappingCapturePolicy {
  static func begin(
    controlsEnabled: Bool,
    voiceActive: Bool,
    injectedInputActive: Bool
  ) -> MappingCapturePlan {
    MappingCapturePlan(
      controlsEnabledAfterTransition: controlsEnabled,
      shouldStopVoice: voiceActive,
      shouldReleaseInjectedInputs: controlsEnabled || voiceActive || injectedInputActive
    )
  }
}

struct ControllerChordRecorder {
  private var recording = false
  private var held = Set<ControllerButton>()
  private var collected = Set<ControllerButton>()

  mutating func begin() {
    recording = true
    held.removeAll()
    collected.removeAll()
  }

  mutating func cancel() {
    recording = false
    held.removeAll()
    collected.removeAll()
  }

  mutating func process(button: ControllerButton, pressed: Bool) -> ControllerChord? {
    guard recording else { return nil }
    if pressed {
      held.insert(button)
      if collected.count < 4 || collected.contains(button) {
        collected.insert(button)
      }
      return nil
    }
    held.remove(button)
    guard held.isEmpty, !collected.isEmpty else { return nil }
    recording = false
    return ControllerChord(buttons: Array(collected))
  }
}

enum ControllerAction: String, CaseIterable, Codable, Identifiable {
  case none
  case primaryClick
  case secondaryClick
  case pageUp
  case pageDown
  case pushToTalk
  case shortcut1
  case shortcut2
  case shortcut3

  var id: String { rawValue }

  var requiresDesktopControls: Bool {
    self != .none && self != .pushToTalk
  }

  var title: String {
    switch self {
    case .none: return "无操作"
    case .primaryClick: return "左键"
    case .secondaryClick: return "右键"
    case .pageUp: return "向上翻页"
    case .pageDown: return "向下翻页"
    case .pushToTalk: return "按住说话"
    case .shortcut1: return "快捷键 1"
    case .shortcut2: return "快捷键 2"
    case .shortcut3: return "快捷键 3"
    }
  }

  var systemImage: String {
    switch self {
    case .none: return "minus.circle"
    case .primaryClick: return "cursorarrow.click"
    case .secondaryClick: return "contextualmenu.and.cursorarrow"
    case .pageUp: return "arrow.up.to.line"
    case .pageDown: return "arrow.down.to.line"
    case .pushToTalk: return "mic.fill"
    case .shortcut1, .shortcut2, .shortcut3: return "keyboard"
    }
  }
}

struct ControllerMapping: Codable, Equatable {
  var bindings: [ControllerBinding]

  init(bindings: [ControllerBinding]) {
    self.bindings = []
    for binding in bindings where binding.action != .none {
      _ = upsert(binding)
    }
  }

  func action(for chord: ControllerChord) -> ControllerAction? {
    bindings.first(where: { $0.chord == chord })?.action
  }

  @discardableResult
  mutating func upsert(_ binding: ControllerBinding) -> [ControllerBinding] {
    let removed = bindings.filter { $0.chord.isAmbiguous(with: binding.chord) }
    bindings.removeAll { $0.chord.isAmbiguous(with: binding.chord) }
    if binding.action != .none { bindings.append(binding) }
    bindings.sort { $0.chord.sourceID < $1.chord.sourceID }
    return removed
  }

  mutating func remove(chord: ControllerChord) {
    bindings.removeAll { $0.chord == chord }
  }

  var cross: ControllerAction {
    get { singleAction(.south) }
    set { setSingle(.south, action: newValue) }
  }

  var circle: ControllerAction {
    get { singleAction(.east) }
    set { setSingle(.east, action: newValue) }
  }

  var create: ControllerAction {
    get { singleAction(.back) }
    set { setSingle(.back, action: newValue) }
  }

  var dpadUp: ControllerAction {
    get { singleAction(.dpadUp) }
    set { setSingle(.dpadUp, action: newValue) }
  }

  var dpadDown: ControllerAction {
    get { singleAction(.dpadDown) }
    set { setSingle(.dpadDown, action: newValue) }
  }

  var microphone: ControllerAction {
    get { singleAction(.misc1) }
    set { setSingle(.misc1, action: newValue) }
  }

  static let standard = ControllerMapping(bindings: [
    ControllerBinding(chord: ControllerChord(buttons: [.south])!, action: .primaryClick),
    ControllerBinding(chord: ControllerChord(buttons: [.east])!, action: .secondaryClick),
    ControllerBinding(chord: ControllerChord(buttons: [.dpadUp])!, action: .pageUp),
    ControllerBinding(chord: ControllerChord(buttons: [.dpadDown])!, action: .pageDown),
    ControllerBinding(chord: ControllerChord(buttons: [.misc1])!, action: .pushToTalk),
  ])

  private func singleAction(_ button: ControllerButton) -> ControllerAction {
    guard let chord = ControllerChord(buttons: [button]) else { return .none }
    return action(for: chord) ?? .none
  }

  private mutating func setSingle(_ button: ControllerButton, action: ControllerAction) {
    guard let chord = ControllerChord(buttons: [button]) else { return }
    _ = upsert(ControllerBinding(chord: chord, action: action))
  }

  private enum CodingKeys: String, CodingKey {
    case bindings
    case cross
    case circle
    case create
    case dpadUp
    case dpadDown
    case microphone
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let decoded = try container.decodeIfPresent([ControllerBinding].self, forKey: .bindings) {
      self.init(bindings: decoded)
      return
    }
    var legacy = ControllerMapping.standard
    legacy.cross = try container.decodeIfPresent(ControllerAction.self, forKey: .cross) ?? .primaryClick
    legacy.circle = try container.decodeIfPresent(ControllerAction.self, forKey: .circle) ?? .secondaryClick
    legacy.create = try container.decodeIfPresent(ControllerAction.self, forKey: .create) ?? .none
    legacy.dpadUp = try container.decodeIfPresent(ControllerAction.self, forKey: .dpadUp) ?? .pageUp
    legacy.dpadDown = try container.decodeIfPresent(ControllerAction.self, forKey: .dpadDown) ?? .pageDown
    legacy.microphone =
      try container.decodeIfPresent(ControllerAction.self, forKey: .microphone) ?? .pushToTalk
    self = legacy
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(bindings, forKey: .bindings)
  }
}

struct ControllerBindingResolver {
  private var pressedButtons = Set<ControllerButton>()
  private var active = [ControllerChord: ControllerAction]()

  mutating func process(
    button: ControllerButton,
    pressed: Bool,
    mapping: ControllerMapping
  ) -> [ControllerActionTransition] {
    if pressed {
      guard pressedButtons.insert(button).inserted else { return [] }
    } else {
      guard pressedButtons.remove(button) != nil else { return [] }
    }

    var transitions: [ControllerActionTransition] = []
    for chord in active.keys.sorted(by: { $0.sourceID < $1.sourceID })
    where !chord.isSatisfied(by: pressedButtons) {
      guard let action = active.removeValue(forKey: chord) else { continue }
      transitions.append(ControllerActionTransition(chord: chord, action: action, pressed: false))
    }
    for binding in mapping.bindings
    where active[binding.chord] == nil && binding.chord.isSatisfied(by: pressedButtons) {
      active[binding.chord] = binding.action
      transitions.append(
        ControllerActionTransition(chord: binding.chord, action: binding.action, pressed: true)
      )
    }
    return transitions
  }

  mutating func reset() -> [ControllerActionTransition] {
    let releases = active.map {
      ControllerActionTransition(chord: $0.key, action: $0.value, pressed: false)
    }
    .sorted { $0.chord.sourceID < $1.chord.sourceID }
    active.removeAll()
    pressedButtons.removeAll()
    return releases
  }
}
