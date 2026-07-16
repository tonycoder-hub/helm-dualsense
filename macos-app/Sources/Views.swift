import AppKit
import Combine
import CoreAudio
import SwiftUI

private let helmAccent = Color(red: 0.27, green: 0.84, blue: 0.76)
private let helmBlue = Color(red: 0.31, green: 0.55, blue: 1.0)
private let helmBackground = Color(red: 0.055, green: 0.07, blue: 0.11)

struct ControlCenterView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [helmBackground, Color(red: 0.08, green: 0.10, blue: 0.17)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()

      ScrollView {
        VStack(spacing: 18) {
          header
          statusStrip
          controlCard
          HStack(alignment: .top, spacing: 18) {
            mappingCard
            permissionCard
          }
          customMappingCard
          voiceCard
          diagnosticsCard
        }
        .padding(24)
        .foregroundStyle(.white)
      }
    }
    .preferredColorScheme(.dark)
    .environment(\.colorScheme, .dark)
  }

  private var header: some View {
    HStack(spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 16)
          .fill(
            LinearGradient(
              colors: [helmAccent.opacity(0.9), helmBlue.opacity(0.9)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        Image(systemName: "playstation.logo")
          .font(.system(size: 26, weight: .semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 54, height: 54)

      VStack(alignment: .leading, spacing: 3) {
        Text("Helm")
          .font(.system(size: 27, weight: .bold, design: .rounded))
        Text("DualSense · 鼠标 · 滚动 · 语音输入")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("DEMO 0.6")
        .font(.caption.weight(.bold))
        .foregroundStyle(helmAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(helmAccent.opacity(0.12), in: Capsule())
    }
  }

  private var statusStrip: some View {
    HStack(spacing: 12) {
      StatusPill(
        title: "DualSense",
        value: model.controllerConnected ? "已连接" : "未连接",
        systemImage: "playstation.logo",
        color: model.controllerConnected ? helmAccent : .orange
      )
      StatusPill(
        title: "桌面控制",
        value: model.controlsEnabled ? "运行中" : "已停用",
        systemImage: "cursorarrow.motionlines",
        color: model.controlsEnabled ? helmBlue : .secondary
      )
      StatusPill(
        title: "语音",
        value: model.isListening ? "正在聆听" : "待机",
        systemImage: model.isListening ? "waveform" : "mic",
        color: model.isListening ? .red : .secondary
      )
    }
  }

  private var controlCard: some View {
    HelmCard {
      HStack(spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Label("主控制", systemImage: "power.circle.fill")
            .font(.headline)
          Text(model.statusMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Text("启动与重连后始终默认停用。Options + 触控板键是紧急停止手势。")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 16)
        Button(action: model.toggleControls) {
          Label(
            model.controlsEnabled ? "立即停止" : "启用控制",
            systemImage: model.controlsEnabled ? "stop.fill" : "play.fill"
          )
          .font(.headline)
          .frame(minWidth: 116)
          .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.controlsEnabled ? .red : helmAccent)
      }

      Divider().opacity(0.35)

      HStack(spacing: 22) {
        LabeledSlider(
          label: "指针速度",
          value: $model.pointerGain,
          range: 0.45...2.2,
          display: String(format: "%.2f×", model.pointerGain)
        )
        LabeledSlider(
          label: "滚动速度",
          value: $model.scrollGain,
          range: 2...18,
          display: String(format: "%.0f", model.scrollGain)
        )
        VStack(alignment: .leading, spacing: 6) {
          Text("输入轮询率")
            .font(.caption)
            .foregroundStyle(.secondary)
          Picker("输入轮询率", selection: $model.inputPollingRate) {
            ForEach([60.0, 90.0, 120.0, 144.0, 240.0], id: \.self) { rate in
              Text("\(Int(rate)) Hz").tag(rate)
            }
          }
          .labelsHidden()
          .frame(width: 110)
        }
      }
    }
  }

  private var mappingCard: some View {
    HelmCard {
      Label("当前映射", systemImage: "switch.2")
        .font(.headline)
      VStack(spacing: 9) {
        MappingRow(source: "左摇杆", target: "主光标", icon: "cursorarrow.motionlines")
        MappingRow(source: "触控板", target: "精细光标", icon: "cursorarrow")
        MappingRow(source: "右摇杆", target: "滚动", icon: "scroll")
        MappingRow(source: "L2 / R2", target: "刹车 / 加速", icon: "gauge.with.dots.needle.50percent")
        MappingRow(source: "Options + 触控板", target: "急停", icon: "stop.fill")
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var customMappingCard: some View {
    HelmCard {
      HStack {
        Label("自定义按键与摇杆曲线", systemImage: "slider.horizontal.3")
          .font(.headline)
        Spacer()
        Button("恢复默认") { model.restoreDefaultMappings() }
          .buttonStyle(.plain)
          .foregroundStyle(helmAccent)
      }

      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
        spacing: 10
      ) {
        ActionMappingPicker(label: "Cross", selection: $model.mapping.cross)
        ActionMappingPicker(label: "Circle", selection: $model.mapping.circle)
        ActionMappingPicker(label: "Create", selection: $model.mapping.create)
        ActionMappingPicker(label: "D-pad 上", selection: $model.mapping.dpadUp)
        ActionMappingPicker(label: "D-pad 下", selection: $model.mapping.dpadDown)
        ActionMappingPicker(label: "麦克风键", selection: $model.mapping.microphone)
      }

      Divider().opacity(0.35)

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("外部输入法快捷键", systemImage: "keyboard")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text("把任意手柄键映射到快捷键 1–3")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        HStack(alignment: .top, spacing: 12) {
          ShortcutSlotEditor(title: "快捷键 1", shortcut: $model.shortcutSettings.slot1)
          ShortcutSlotEditor(title: "快捷键 2", shortcut: $model.shortcutSettings.slot2)
          ShortcutSlotEditor(title: "快捷键 3", shortcut: $model.shortcutSettings.slot3)
        }
      }

      Divider().opacity(0.35)

      HStack(alignment: .top, spacing: 22) {
        VStack(spacing: 12) {
          LabeledSlider(
            label: "长按加速时间",
            value: $model.stickAccelerationDuration,
            range: 0.4...3.5,
            display: String(format: "%.1f 秒", model.stickAccelerationDuration)
          )
          LabeledSlider(
            label: "最高速度倍率",
            value: $model.stickMaximumBoost,
            range: 1...3,
            display: String(format: "%.1f×", model.stickMaximumBoost)
          )
        }
        .frame(maxWidth: .infinity)

        VStack(alignment: .leading, spacing: 6) {
          Text("长按速度曲线")
            .font(.caption)
            .foregroundStyle(.secondary)
          AccelerationCurvePreview(
            duration: model.stickAccelerationDuration,
            maximumBoost: model.stickMaximumBoost
          )
          .frame(height: 70)
        }
        .frame(maxWidth: .infinity)
      }

      Divider().opacity(0.35)

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("赛车式扳机调速", systemImage: "gauge.with.dots.needle.67percent")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text(String(format: "当前 %.2f×", model.currentRacingSpeedMultiplier))
            .font(.caption.monospacedDigit())
            .foregroundStyle(helmAccent)
        }
        HStack(spacing: 22) {
          LabeledSlider(
            label: "L2 全刹最低速度",
            value: $model.brakeMinimumSpeed,
            range: 0.1...1,
            display: String(format: "%.2f×", model.brakeMinimumSpeed)
          )
          LabeledSlider(
            label: "R2 全油最高速度",
            value: $model.acceleratorMaximumSpeed,
            range: 1...4,
            display: String(format: "%.1f×", model.acceleratorMaximumSpeed)
          )
        }
        HStack(spacing: 18) {
          TriggerMeter(label: "L2 刹车", value: model.leftTriggerValue, color: .orange)
          TriggerMeter(label: "R2 加速", value: model.rightTriggerValue, color: helmAccent)
        }
      }

      Divider().opacity(0.35)

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("语义震动", systemImage: "waveform.path")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Toggle("操作震动", isOn: $model.hapticsEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
          Button("试震") { model.testHaptics() }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.controllerConnected || !model.hapticsEnabled)
        }
        LabeledSlider(
          label: "震动强度",
          value: $model.hapticIntensity,
          range: 0.2...1,
          display: String(format: "%.0f%%", model.hapticIntensity * 100)
        )
        HStack {
          Label(
            model.hapticCapabilityLabel,
            systemImage: model.hapticsAvailable ? "checkmark.circle.fill" : "questionmark.circle"
          )
          .foregroundStyle(model.hapticsAvailable ? helmAccent : .secondary)
          Spacer()
          Text("启用、点击、翻页、快捷键与 PTT 才触发；连续移动不震动")
            .foregroundStyle(.tertiary)
        }
        .font(.caption)
      }

      Text("Options + 触控板为固定安全急停手势，不允许重映射。修改映射时会自动停用控制。")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  private var permissionCard: some View {
    HelmCard {
      HStack {
        Label("权限", systemImage: "lock.shield")
          .font(.headline)
        Spacer()
        Button("刷新") { model.refreshEnvironment() }
          .buttonStyle(.plain)
          .foregroundStyle(helmAccent)
      }
      PermissionRow(
        title: "辅助功能",
        granted: model.accessibilityGranted,
        detail: model.accessibilityGranted ? "可控制鼠标" : "等待授权"
      )
      PermissionRow(
        title: "麦克风",
        granted: model.microphoneAuthorization == .authorized,
        detail: model.microphonePermissionLabel
      )
      PermissionRow(
        title: "语音识别",
        granted: model.speechAuthorization == .authorized,
        detail: model.speechPermissionLabel
      )
      HStack {
        Button("辅助功能") { model.requestAccessibility() }
          .buttonStyle(.bordered)
        Button("语音权限") { model.requestVoicePermissions() }
          .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var voiceCard: some View {
    HelmCard {
      HStack {
        Label("语音输入", systemImage: "waveform.and.mic")
          .font(.headline)
        Spacer()
        Toggle("释放后写入当前文本框", isOn: $model.autoInsert)
          .toggleStyle(.switch)
          .controlSize(.small)
      }

      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("麦克风")
            .font(.caption)
            .foregroundStyle(.secondary)
          Picker("麦克风", selection: $model.selectedAudioDeviceID) {
            Text(model.audioDevices.isEmpty ? "未发现输入设备" : "请选择麦克风")
              .tag(AudioDeviceID(0))
            ForEach(model.audioDevices) { device in
              Text(
                device.isDefault
                  ? "\(device.name) · \(device.transport.label) · 系统默认"
                  : "\(device.name) · \(device.transport.label)"
              )
              .tag(device.id)
              .disabled(model.protectPlaybackAudio && device.mayInterruptPlayback)
            }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity)
          .disabled(model.isListening)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("识别语言")
            .font(.caption)
            .foregroundStyle(.secondary)
          Picker("识别语言", selection: $model.localeIdentifier) {
            Text("普通话").tag("zh-CN")
            Text("English").tag("en-US")
          }
          .labelsHidden()
          .frame(width: 130)
          .disabled(model.isListening)
        }

        HoldToTalkButton()
          .environmentObject(model)
      }

      HStack {
        Toggle("保护音乐播放（自动避开蓝牙麦克风）", isOn: $model.protectPlaybackAudio)
          .toggleStyle(.switch)
          .controlSize(.small)
        Spacer()
        if let selectedDevice = model.selectedAudioDevice {
          if selectedDevice.mayInterruptPlayback {
            Label("蓝牙麦克风会切换通话链路", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          } else {
            Label("当前麦克风不会启用蓝牙通话链路", systemImage: "speaker.wave.2.fill")
              .foregroundStyle(helmAccent)
          }
        } else {
          Label("尚未选择麦克风", systemImage: "mic.slash")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("实时转写")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("清空") { model.clearTranscript() }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(helmAccent)
        }
        Text(model.transcript.isEmpty ? "等待语音输入…" : model.transcript)
          .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
          .textSelection(.enabled)
          .padding(12)
          .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
      }

      HStack {
        Image(systemName: "info.circle")
        Text("Sony 不支持 DualSense 内置麦克风作为 Mac 输入；手柄麦克风键只负责 PTT，实际音源显示在上方。")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var diagnosticsCard: some View {
    HelmCard {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 18) {
            DiagnosticItem(label: "控制器", value: model.controllerName)
            DiagnosticItem(label: "连接", value: model.connectionLabel)
            DiagnosticItem(
              label: "麦克风键",
              value: model.microphoneButtonAvailable ? "可用" : "未验证"
            )
            DiagnosticItem(label: "触控板", value: "\(model.touchpadCount) 个")
            DiagnosticItem(
              label: "语音采样",
              value: model.lastAudioSampleRate > 0
                ? "\(Int(model.lastAudioSampleRate)) Hz" : "未运行"
            )
          }
          Text("最近输入：\(model.latestInput)")
            .font(.callout.monospaced())
            .foregroundStyle(helmAccent)
          ForEach(Array(model.activity.prefix(6).enumerated()), id: \.offset) { _, item in
            Text(item)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
          HStack {
            Button("打开辅助功能设置") { model.openAccessibilitySettings() }
            Button("打开声音设置") { model.openSoundSettings() }
            Spacer()
            Label(model.updateChannelLabel, systemImage: "arrow.triangle.2.circlepath")
              .font(.caption)
              .foregroundStyle(.secondary)
            Button("检查更新") { model.checkForUpdates() }
              .disabled(!model.canCheckForUpdates)
          }
          .buttonStyle(.link)
        }
        .padding(.top, 10)
      } label: {
        Label("诊断与最近活动", systemImage: "stethoscope")
          .font(.headline)
      }
    }
  }
}

struct MenuBarPanel: View {
  @Environment(\.openWindow) private var openWindow
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Image(systemName: "playstation.logo")
          .foregroundStyle(helmAccent)
        Text("Helm")
          .font(.headline)
        Spacer()
        Circle()
          .fill(model.controllerConnected ? helmAccent : .orange)
          .frame(width: 8, height: 8)
      }

      VStack(alignment: .leading, spacing: 5) {
        Text(model.controllerName)
          .font(.subheadline.weight(.medium))
        Text(model.isListening ? "正在聆听…" : model.statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Button(action: model.toggleControls) {
        Label(
          model.controlsEnabled ? "立即停止" : "启用控制",
          systemImage: model.controlsEnabled ? "stop.fill" : "play.fill"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(model.controlsEnabled ? .red : helmAccent)

      Divider()
      Button("打开控制中心") {
        openWindow(id: "control-center")
        NSApp.activate(ignoringOtherApps: true)
      }
      Button("退出 Helm") {
        model.shutdown()
        NSApp.terminate(nil)
      }
    }
    .padding(16)
    .frame(width: 300)
  }
}

private struct HelmCard<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) { content }
      .padding(18)
      .background(
        RoundedRectangle(cornerRadius: 17, style: .continuous)
          .fill(Color.white.opacity(0.055))
          .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
              .stroke(Color.white.opacity(0.08), lineWidth: 1)
          )
      )
  }
}

private struct StatusPill: View {
  let title: String
  let value: String
  let systemImage: String
  let color: Color

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(color)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.subheadline.weight(.semibold))
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity)
    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))
  }
}

private struct MappingRow: View {
  let source: String
  let target: String
  let icon: String

  var body: some View {
    HStack {
      Text(source)
        .font(.callout.weight(.medium))
      Spacer()
      Image(systemName: "arrow.right")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Image(systemName: icon)
        .foregroundStyle(helmAccent)
        .frame(width: 20)
      Text(target)
        .font(.callout)
        .frame(width: 66, alignment: .leading)
    }
  }
}

private struct ActionMappingPicker: View {
  let label: String
  @Binding var selection: ControllerAction

  var body: some View {
    HStack(spacing: 10) {
      Text(label)
        .font(.callout.weight(.medium))
        .frame(width: 82, alignment: .leading)
      Picker(label, selection: $selection) {
        ForEach(ControllerAction.allCases) { action in
          Label(action.title, systemImage: action.systemImage)
            .tag(action)
        }
      }
      .labelsHidden()
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct ShortcutSlotEditor: View {
  let title: String
  @Binding var shortcut: KeyboardShortcutDefinition

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.caption.weight(.semibold))
        Spacer()
        Text(shortcut.label)
          .font(.caption.monospaced())
          .foregroundStyle(helmAccent)
      }
      Picker("按键", selection: $shortcut.key) {
        ForEach(ShortcutKey.allCases) { key in
          Text(key.title).tag(key)
        }
      }
      .labelsHidden()

      HStack(spacing: 5) {
        Toggle("⌃", isOn: $shortcut.control)
        Toggle("⌥", isOn: $shortcut.option)
        Toggle("⇧", isOn: $shortcut.shift)
        Toggle("⌘", isOn: $shortcut.command)
      }
      .toggleStyle(.button)
      .buttonStyle(.bordered)
      .controlSize(.mini)
    }
    .padding(10)
    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    .frame(maxWidth: .infinity)
  }
}

private struct TriggerMeter: View {
  let label: String
  let value: Double
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label)
        Spacer()
        Text("\(Int(value * 100))%")
          .monospacedDigit()
      }
      .font(.caption)
      ProgressView(value: value)
        .tint(color)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct AccelerationCurvePreview: View {
  let duration: Double
  let maximumBoost: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        RoundedRectangle(cornerRadius: 9)
          .fill(Color.white.opacity(0.035))
        Path { path in
          let width = max(geometry.size.width - 16, 1)
          let height = max(geometry.size.height - 16, 1)
          for index in 0...60 {
            let progress = Double(index) / 60
            let hold = ControlMath.stickAccelerationDelay + duration * progress
            let boost = ControlMath.stickHoldBoost(
              holdDuration: hold,
              delay: ControlMath.stickAccelerationDelay,
              accelerationDuration: duration,
              maximumBoost: maximumBoost
            )
            let normalized = maximumBoost > 1 ? (boost - 1) / (maximumBoost - 1) : progress
            let xProgress = CGFloat(progress)
            let yProgress = CGFloat(normalized)
            let point = CGPoint(
              x: 8 + width * xProgress,
              y: 8 + height * (1 - yProgress)
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
          }
        }
        .stroke(helmAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
      }
    }
    .accessibilityLabel("左摇杆长按速度曲线")
  }
}

private struct PermissionRow: View {
  let title: String
  let granted: Bool
  let detail: String

  var body: some View {
    HStack {
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(granted ? helmAccent : .orange)
      Text(title)
      Spacer()
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct LabeledSlider: View {
  let label: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let display: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(label).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text(display).font(.caption.monospacedDigit()).foregroundStyle(helmAccent)
      }
      Slider(value: $value, in: range)
        .tint(helmAccent)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct HoldToTalkButton: View {
  @EnvironmentObject private var model: AppModel
  @State private var pressed = false

  var body: some View {
    Label(model.isListening ? "松开完成" : "按住测试", systemImage: "mic.fill")
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .frame(height: 34)
      .background(model.isListening ? Color.red : helmBlue, in: RoundedRectangle(cornerRadius: 9))
      .scaleEffect(pressed ? 0.97 : 1)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            guard !pressed else { return }
            pressed = true
            model.beginVoiceTest()
          }
          .onEnded { _ in
            guard pressed else { return }
            pressed = false
            model.endVoiceTest()
          }
      )
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
      ) { _ in
        cancelIfPressed()
      }
      .onDisappear { cancelIfPressed() }
      .help("无需手柄即可测试当前麦克风与语音识别")
  }

  private func cancelIfPressed() {
    guard pressed else { return }
    pressed = false
    model.cancelVoiceTest()
  }
}

private struct DiagnosticItem: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption2).foregroundStyle(.tertiary)
      Text(value).font(.caption.weight(.medium)).lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
