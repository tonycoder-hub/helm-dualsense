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
        Image(systemName: model.controllerSystemImage)
          .font(.system(size: 26, weight: .semibold))
          .foregroundStyle(.white)
      }
      .frame(width: 54, height: 54)

      VStack(alignment: .leading, spacing: 3) {
        Text("GripPilot")
          .font(.system(size: 27, weight: .bold, design: .rounded))
        Text("PlayStation / Xbox / Nintendo · 鼠标 · 滚动 · 语音输入")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("检查更新") { model.checkForUpdates() }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!model.canCheckForUpdates)
        .help(model.updateChannelLabel)
      Text("0.11.1")
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
        title: model.controllerConnected ? model.controllerFamily.title : "手柄",
        value: model.controllerConnected ? "已连接" : "未连接",
        systemImage: model.controllerSystemImage,
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
        value: model.isListening ? "正在聆听" : model.voiceInputMode.title,
        systemImage: model.isListening
          ? "waveform" : (model.voiceInputMode == .alwaysOff ? "mic.slash" : "mic"),
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
          Text("启动自动启用只在启动时消费一次；手动停止后不会被普通重连重新打开。\(model.safetyChordLabel) 是紧急停止手势。")
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

      Toggle(
        "启动时已连接手柄则自动启用",
        isOn: $model.autoEnableControlsOnLaunch
      )
      .toggleStyle(.switch)
      .controlSize(.small)

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
          Text("固定控制频率")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack(spacing: 7) {
            Text("240 Hz")
              .font(.headline.monospacedDigit())
            Text("已锁定")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(helmAccent.opacity(0.14), in: Capsule())
          }
          Text(
            model.measuredInputRate > 0
              ? "采样 \(Int(model.measuredInputRate.rounded())) Hz · \(model.outputCadenceLabel) \(Int(model.measuredDisplayRate.rounded())) Hz"
              : model.inputCadenceLabel
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(helmAccent)
          Text(model.inputJitterLabel)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
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
        MappingRow(source: model.safetyChordLabel, target: "急停", icon: "stop.fill")
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

      VStack(spacing: 9) {
        ForEach(model.mapping.bindings, id: \.chord) { binding in
          RecordedMappingRow(
            label: binding.chord.label(family: model.controllerFamily),
            action: Binding(
              get: { binding.action },
              set: { model.setMappingAction($0, for: binding.chord) }
            ),
            onRecord: { model.beginMappingCapture(replacing: binding.chord) },
            onDelete: { model.removeMapping(binding.chord) }
          )
        }

        HStack(spacing: 10) {
          Picker("新映射动作", selection: $model.pendingMappingAction) {
            ForEach(ControllerAction.allCases.filter { $0 != .none }) { action in
              Label(action.title, systemImage: action.systemImage).tag(action)
            }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity)
          Button("录入新按键 / 组合键") { model.beginMappingCapture() }
            .buttonStyle(.borderedProminent)
            .tint(helmBlue)
        }

        if model.isRecordingMapping {
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text(model.mappingCapturePrompt)
              .font(.callout)
              .foregroundStyle(helmAccent)
            Spacer()
            Button("取消录入") { model.cancelMappingCapture() }
              .buttonStyle(.bordered)
          }
          .padding(10)
          .background(helmAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
      }

      Text("可直接录入最多 4 键组合；Xbox Elite、DualSense Edge 等由 SDL 暴露的 4 个背键也可录入。前缀冲突会由新映射替换，避免单键和组合键同时误触发。")
        .font(.caption)
        .foregroundStyle(.tertiary)

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
        LazyVGrid(
          columns: [
            GridItem(
              .adaptive(
                minimum: CGFloat(MappingLayoutPolicy.minimumShortcutEditorWidth)
              ),
              spacing: CGFloat(MappingLayoutPolicy.shortcutSpacing),
              alignment: .top
            )
          ],
          alignment: .leading,
          spacing: CGFloat(MappingLayoutPolicy.shortcutSpacing)
        ) {
          ShortcutSlotEditor(title: "快捷键 1", shortcut: $model.shortcutSettings.slot1)
          ShortcutSlotEditor(title: "快捷键 2", shortcut: $model.shortcutSettings.slot2)
          ShortcutSlotEditor(title: "快捷键 3", shortcut: $model.shortcutSettings.slot3)
        }
      }

      Divider().opacity(0.35)

      HStack(alignment: .top, spacing: 22) {
        VStack(spacing: 12) {
          LabeledSlider(
            label: "摇杆响应曲线",
            value: $model.stickResponseExponent,
            range: 0.7...2.4,
            display: String(format: "%.2f", model.stickResponseExponent)
          )
          LabeledSlider(
            label: "平滑时间",
            value: $model.stickSmoothingMilliseconds,
            range: 0...60,
            display: String(format: "%.0f ms", model.stickSmoothingMilliseconds)
          )
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
          Text("启用、点击、翻页、快捷键与语音开始/停止才触发；连续移动不震动")
            .foregroundStyle(.tertiary)
        }
        .font(.caption)
      }

      Text("\(model.safetyChordLabel) 为固定安全急停手势，不允许重映射。录入或修改映射时只暂挂桌面注入，不会断开手柄或关闭控制会话。")
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
        Button("辅助功能设置") { model.requestAccessibility() }
          .buttonStyle(.bordered)
        Button("语音权限设置") { model.requestVoicePermissions() }
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

      VStack(alignment: .leading, spacing: 7) {
        Text("麦克风模式")
          .font(.caption)
          .foregroundStyle(.secondary)
        Picker("麦克风模式", selection: $model.voiceInputMode) {
          ForEach(VoiceInputMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        Text(model.voiceInputMode.detail)
          .font(.caption)
          .foregroundStyle(
            model.voiceInputMode == .alwaysOff ? Color.orange : Color.secondary
          )
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
          Button("重新发送到外部焦点") { model.retryExternalTextDelivery() }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(model.canRetryExternalTextDelivery ? helmAccent : .secondary)
            .disabled(!model.canRetryExternalTextDelivery)
            .help("识别完成后重新聚焦外部文本框，再返回 GripPilot 点击；会复用自动写入的目标校验")
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
        if model.selectedAudioDevice?.isControllerRoutedUSB == true {
          Text("已选中手柄的 USB 音频输入。启动采集时若 HID 短暂重枚举，GripPilot 会保留语音并在同一手柄恢复后继续控制。")
        } else {
          Text("有线 DualSense 在这台 Mac 上可枚举为 48 kHz USB 输入；蓝牙手柄音频仍不会作为安全的音乐共存路径。实际音源以顶部选择为准。")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      Text("按键模式独立于“桌面控制”开关；常开会安全分段并在确认写入后继续监听，常闭会立即取消采集和待投递文本。")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Text("若自动写入未出现：识别完成后重新在目标文本框点一下，返回 GripPilot 点击“重新发送到外部焦点”；这不会重新录音。")
        .font(.caption)
        .foregroundStyle(.tertiary)
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
              label: "功能键 / 麦克风键",
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
        Image(systemName: model.controllerSystemImage)
          .foregroundStyle(helmAccent)
        Text("GripPilot")
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

      Picker("麦克风", selection: $model.voiceInputMode) {
        ForEach(VoiceInputMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

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
      Button("检查更新") { model.checkForUpdates() }
        .disabled(!model.canCheckForUpdates)
      Button("打开控制中心") {
        openWindow(id: "control-center")
        NSApp.activate(ignoringOtherApps: true)
      }
      Button("退出 GripPilot") {
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

private struct RecordedMappingRow: View {
  let label: String
  @Binding var action: ControllerAction
  let onRecord: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Text(label)
        .font(.callout.weight(.medium))
        .frame(minWidth: 150, alignment: .leading)
      Picker(label, selection: $action) {
        ForEach(ControllerAction.allCases.filter { $0 != .none }) { candidate in
          Label(candidate.title, systemImage: candidate.systemImage)
            .tag(candidate)
        }
      }
      .labelsHidden()
      .frame(maxWidth: .infinity)
      Button("重新录入", action: onRecord)
        .buttonStyle(.bordered)
        .controlSize(.small)
      Button(action: onDelete) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
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
        Text("仅修饰键（按住）").tag(nil as ShortcutKey?)
        ForEach(ShortcutKey.allCases) { key in
          Text(key.title).tag(Optional(key))
        }
      }
      .labelsHidden()

      LazyVGrid(
        columns: [GridItem(.flexible()), GridItem(.flexible())],
        spacing: 6
      ) {
        ModifierSidePicker(title: "Control", symbol: "⌃", side: $shortcut.controlSide)
        ModifierSidePicker(title: "Option", symbol: "⌥", side: $shortcut.optionSide)
        ModifierSidePicker(title: "Shift", symbol: "⇧", side: $shortcut.shiftSide)
        ModifierSidePicker(title: "Command", symbol: "⌘", side: $shortcut.commandSide)
      }
    }
    .padding(10)
    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    .frame(maxWidth: .infinity)
  }
}

private struct ModifierSidePicker: View {
  let title: String
  let symbol: String
  @Binding var side: ModifierSide

  var body: some View {
    Picker(selection: $side) {
      Text("关闭").tag(ModifierSide.none)
      Text("左侧 \(symbol)").tag(ModifierSide.left)
      Text("右侧 \(symbol)").tag(ModifierSide.right)
    } label: {
      HStack(spacing: 4) {
        Text(title)
          .foregroundStyle(.secondary)
        Spacer(minLength: 2)
        Text(displayLabel)
          .monospaced()
      }
      .font(.caption2)
      .frame(maxWidth: .infinity)
    }
    .pickerStyle(.menu)
    .controlSize(.mini)
    .frame(maxWidth: .infinity)
    .help("\(title)：关闭、左侧或右侧")
  }

  private var displayLabel: String {
    switch side {
    case .none: return symbol
    case .left: return "左\(symbol)"
    case .right: return "右\(symbol)"
    }
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
    let enabled = model.voiceInputMode == .pushToTalk
    Label(
      enabled ? (model.isListening ? "松开完成" : "按住测试") : model.voiceInputMode.title,
      systemImage: enabled ? "mic.fill" : "mic.slash.fill"
    )
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .frame(height: 34)
      .background(
        enabled ? (model.isListening ? Color.red : helmBlue) : Color.secondary,
        in: RoundedRectangle(cornerRadius: 9)
      )
      .scaleEffect(pressed ? 0.97 : 1)
      .opacity(enabled ? 1 : 0.65)
      .contentShape(Rectangle())
      .allowsHitTesting(enabled)
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
      .onChange(of: model.voiceInputMode) { _, _ in
        pressed = false
      }
      .onDisappear { cancelIfPressed() }
      .help(
        enabled
          ? "无需手柄即可测试当前麦克风与语音识别"
          : "切换到按键模式后可使用按住测试"
      )
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
