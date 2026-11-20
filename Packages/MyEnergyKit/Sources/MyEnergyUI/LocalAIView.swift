#if !os(watchOS)
import Combine
import Foundation
import SwiftUI
import MyEnergyCore
import MyEnergyPlatform

struct LocalAIView: View {
  @Environment(\.energyTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var model: AppModel
  @StateObject private var controller: LocalAIController

  init(model: AppModel) {
    self.model = model
    _controller = StateObject(wrappedValue: LocalAIController(model: model))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          introduction
          factsCard
          devicesCard
          if controller.hasModelAssets { modelDownloadCard }
          permissionsCard
          generationCard
          if let result = controller.result { resultCard(result) }
        }
        .padding(20)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
      }
      .background(theme.canvas)
      .navigationTitle("每日复盘")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            controller.disappear()
            dismiss()
          }
        }
      }
    }
    .tint(theme.accent)
    .foregroundStyle(theme.ink)
    .onAppear { controller.appear(sceneActive: canRunInScene) }
    .onDisappear { controller.disappear() }
    .onChange(of: scenePhase) { _, _ in controller.setSceneActive(canRunInScene) }
    .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
      controller.refreshContext()
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
      controller.refreshContext()
    }
    #if os(macOS)
    .frame(minWidth: 420, idealWidth: 720, minHeight: 480, idealHeight: 780)
    #endif
  }

  private var canRunInScene: Bool {
    #if os(iOS)
    scenePhase == .active
    #else
    true
    #endif
  }

  private var introduction: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("从今天的事实，想一个小行动", systemImage: "sparkles")
        .font(.title2.weight(.semibold))
      Text("按你的选择生成简短复盘与可选习惯建议。只做日常回顾，不判断疾病、不提供用药建议，也不会自动添加或修改习惯。")
        .font(.callout).foregroundStyle(theme.secondary)
      if model.isDemo {
        StatusPill(text: "独立示例 · 仅本机", symbol: "sparkles")
      }
    }.fixedSize(horizontal: false, vertical: true)
  }

  private var factsCard: some View {
    EnergyCard {
      VStack(alignment: .leading, spacing: 16) {
        SectionHeading(title: "本次使用的事实", subtitle: "由记录直接整理，不由模型推测")
        if let input = controller.input {
          Text("\(input.dayKey) · \(input.timeZoneIdentifier)")
            .font(.caption).foregroundStyle(theme.secondary)
          if input.facts.isEmpty {
            Text("今天还没有可复盘的事实。先记一次精力、完成小习惯或补记已结束的睡眠，再回来生成。")
              .font(.callout).foregroundStyle(theme.secondary)
          } else {
            ForEach(input.facts, id: \.id) { fact in
              VStack(alignment: .leading, spacing: 4) {
                Text(fact.statement).font(.callout)
              }.accessibilityElement(children: .combine)
            }
          }
          if !input.missingData.isEmpty {
            Divider()
            Text("缺失与使用范围").font(.subheadline.weight(.semibold))
            ForEach(input.missingData, id: \.self) { missing in
              Label(missing, systemImage: "minus.circle")
                .font(.footnote).foregroundStyle(theme.secondary)
            }
          }
        } else if let error = controller.inputError {
          Text(error).font(.callout).foregroundStyle(theme.secondary)
        }
      }.fixedSize(horizontal: false, vertical: true)
    }
  }

  private var devicesCard: some View {
    EnergyCard {
      VStack(alignment: .leading, spacing: 16) {
        SectionHeading(title: "模型与执行设备", subtitle: "生成前重新核实可用状态")
        Text(controller.allowsSending
          ? "先选择已授权且就绪的 iPhone，再选择 Mac；同类设备先用系统模型。"
          : "当前只在本机执行。开启下方发送授权后，才会查找局域网内的 iPhone 和 Mac。")
          .font(.callout).foregroundStyle(theme.secondary)
        if controller.runnerStatuses.isEmpty {
          Text("此设备没有注册可在本机执行的模型。iPad 需连接已授权的 iPhone 或 Mac，才能发起复盘。")
            .font(.callout).foregroundStyle(theme.secondary)
        }
        ForEach(controller.runnerStatuses) { status in
          VStack(alignment: .leading, spacing: 7) {
            Label("\(deviceName(status.executor.role)) · \(status.executor.isRemote ? "同账号设备" : "本机")",
              systemImage: deviceSymbol(status.executor.role))
              .font(.subheadline.weight(.semibold))
            Text(status.executor.modelName).font(.callout)
            switch status.availability {
            case .ready:
              Label("已就绪", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(theme.accent)
            case .unavailable(let reason):
              Label(reason, systemImage: "info.circle").font(.footnote).foregroundStyle(theme.secondary)
            case nil:
              HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查…").font(.footnote).foregroundStyle(theme.secondary)
              }
            }
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(theme.accentSoft.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
          .accessibilityElement(children: .combine)
        }
        if controller.runnerStatuses.contains(where: { $0.executor.isRemote }) {
          Text("远端状态来自本次查找，下次生成前会重新检查。")
            .font(.caption).foregroundStyle(theme.secondary)
        }
        Button { controller.refreshAvailability() } label: {
          Label("刷新本机模型状态", systemImage: "arrow.clockwise")
            .frame(minHeight: 36, alignment: .leading)
        }.buttonStyle(.bordered)
      }.fixedSize(horizontal: false, vertical: true)
    }
  }

  private var modelDownloadCard: some View {
    EnergyCard {
      VStack(alignment: .leading, spacing: 16) {
        SectionHeading(title: "可选离线模型", subtitle: "Qwen3 1.7B · 4-bit")
        Text("从 Hugging Face 下载约 984 MB 模型文件。完成校验后供本机离线使用；生成入口不会自动下载。设备能否执行仍以实际模型状态为准。")
          .font(.callout).foregroundStyle(theme.secondary)
        switch controller.assetState {
        case .notDownloaded:
          Label("尚未下载", systemImage: "arrow.down.circle").font(.callout)
          downloadButton
        case .downloading(let progress):
          let value = progress.isFinite ? min(1, max(0, progress)) : 0
          ProgressView(value: value) {
            Text("正在下载与准备 · \(Int(value * 100))%")
          }.accessibilityValue("\(Int(value * 100))%")
          if controller.isDownloading {
            Button("取消下载") { controller.cancelDownload() }.buttonStyle(.bordered)
          } else {
            Text("模型准备完成后，可刷新本机状态。")
              .font(.footnote).foregroundStyle(theme.secondary)
          }
        case .ready(let bytes):
          Label("已校验的本机资产 · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))",
            systemImage: "checkmark.seal")
            .font(.callout).foregroundStyle(theme.accent)
          Text("模型文件已经就绪。点击下方生成按钮后，才会处理本次事实。")
            .font(.footnote).foregroundStyle(theme.secondary)
        case .failed(let reason):
          InlineError(message: reason)
          downloadButton
        }
        if controller.isCancellingDownload {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在停止下载…").font(.footnote).foregroundStyle(theme.secondary)
          }
        }
        if let url = URL(string: "https://huggingface.co/mlx-community/Qwen3-1.7B-4bit/tree/3b1b1768f8f8cf8351c712464f906e86c2b8269e") {
          Link("查看固定版本与模型许可", destination: url).font(.footnote)
        }
      }.fixedSize(horizontal: false, vertical: true)
    }
  }

  private var downloadButton: some View {
    Button { controller.downloadModel() } label: {
      Label("下载离线模型（约 984 MB）", systemImage: "arrow.down.to.line")
        .frame(maxWidth: .infinity, minHeight: 44)
    }.buttonStyle(.bordered)
      .disabled(controller.isDownloading || controller.isCancellingDownload)
  }

  private var permissionsCard: some View {
    EnergyCard {
      VStack(alignment: .leading, spacing: 16) {
        SectionHeading(title: "跨设备处理", subtitle: "默认关闭，按当前页面单独授权")
        Text(controller.crossDeviceExplanation).font(.callout).foregroundStyle(theme.secondary)
        Toggle(isOn: Binding(get: { controller.allowsSending }, set: { controller.setAllowsSending($0) })) {
          Text("允许发送本次摘要给已授权设备")
        }.disabled(!controller.canUseCrossDevice)
        Text("只发送上方有限事实和缺失说明，不含备注、习惯原名或健康样本。生成前仍按 iPhone、Mac 的顺序检查。")
          .font(.footnote).foregroundStyle(theme.secondary)
        Toggle(isOn: Binding(get: { controller.allowsReceiving }, set: { controller.setAllowsReceiving($0) })) {
          Text("允许本页承接同账号设备的复盘")
        }.disabled(!controller.canUseCrossDevice || !controller.canReceiveOnThisDevice)
        if !controller.canReceiveOnThisDevice {
          Text("当前设备只可发起复盘，由已授权的 iPhone 或 Mac 执行。")
            .font(.footnote).foregroundStyle(theme.secondary)
        }
        Text("两端需保持本页打开；iPhone 需在前台，Mac 需运行应用。离开本页或 iPhone 进入后台后停止承接。首次连接时系统可能请求本地网络权限。")
          .font(.footnote).foregroundStyle(theme.secondary)
        LocalAINetworkStatusView(hub: controller.networkHub)
      }.fixedSize(horizontal: false, vertical: true)
    }
  }

  private var generationCard: some View {
    EnergyCard {
      VStack(alignment: .leading, spacing: 16) {
        SectionHeading(title: "生成今天的复盘")
        if controller.isGenerating {
          HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            Text(controller.generationStatus).font(.callout).foregroundStyle(theme.secondary)
          }
          Button("取消本次复盘") { controller.cancelGeneration() }
            .buttonStyle(.bordered).frame(minHeight: 44)
        } else {
          Button { controller.generate() } label: {
            Label(controller.result == nil ? "生成每日复盘" : "重新生成复盘", systemImage: "sparkles")
          }.buttonStyle(PrimaryButtonStyle()).disabled(!controller.canGenerate)
          Text(controller.generationStatus).font(.footnote).foregroundStyle(theme.secondary)
        }
        if let message = controller.message {
          Text(message).font(.callout).foregroundStyle(theme.secondary).textSelection(.enabled)
        }
        Text("结果仅保留在当前页面。记录变化、切换账号或示例、离开页面后会清除。执行开始后失败或设备断连，不会自动另派设备继续生成。")
          .font(.footnote).foregroundStyle(theme.secondary)
      }.fixedSize(horizontal: false, vertical: true)
    }
  }

  private func resultCard(_ result: DailyReflectionResult) -> some View {
    EnergyCard {
      VStack(alignment: .leading, spacing: 18) {
        SectionHeading(title: "这次的复盘", subtitle: "由实际执行模型生成")
        VStack(alignment: .leading, spacing: 6) {
          Label("\(deviceName(result.executor.role)) · \(result.executor.isRemote ? "已授权的局域网设备" : "当前设备")",
            systemImage: deviceSymbol(result.executor.role))
            .font(.subheadline.weight(.semibold))
          Text(result.executor.modelName).font(.callout)
          Text("模型：\(result.executor.modelID)").font(.caption).foregroundStyle(theme.secondary)
          if let input = controller.input {
            Text("输入日期：\(input.dayKey) · \(input.timeZoneIdentifier)").font(.caption).foregroundStyle(theme.secondary)
          }
          Text("生成于 \(result.generatedAt.formatted(date: .abbreviated, time: .standard))")
            .font(.caption).foregroundStyle(theme.secondary)
        }.accessibilityElement(children: .combine)
        Divider()
        Text(result.draft.overview).font(.body).textSelection(.enabled)
        if !result.draft.observations.isEmpty {
          Text("基于事实的观察").font(.headline)
          ForEach(Array(result.draft.observations.enumerated()), id: \.offset) { _, observation in
            VStack(alignment: .leading, spacing: 6) {
              Text(observation.text).font(.callout).textSelection(.enabled)
              evidence(observation.factIDs)
            }
          }
        }
        if !result.draft.suggestions.isEmpty {
          Divider()
          Text("可以选择的小行动").font(.headline)
          Text("选择适合自己的一项即可，建议不会自动加入习惯。")
            .font(.footnote).foregroundStyle(theme.secondary)
          ForEach(Array(result.draft.suggestions.enumerated()), id: \.offset) { _, suggestion in
            VStack(alignment: .leading, spacing: 7) {
              Label(suggestion.title, systemImage: "leaf").font(.subheadline.weight(.semibold))
              Text(suggestion.detail).font(.callout).textSelection(.enabled)
              evidence(suggestion.factIDs)
            }
          }
        }
        Text("这是根据有限记录生成的日常建议，不能补足未记录的情况。")
          .font(.footnote).foregroundStyle(theme.secondary)
      }.fixedSize(horizontal: false, vertical: true)
    }
  }

  private func evidence(_ ids: [String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(ids, id: \.self) { id in
        if let fact = controller.input?.facts.first(where: { $0.id == id }) {
          Text("依据：\(fact.statement)").font(.caption).foregroundStyle(theme.secondary)
        }
      }
    }
  }

  private func deviceName(_ role: LocalAIDeviceRole) -> String {
    switch role {
    case .iPhone: "iPhone"
    case .mac: "Mac"
    case .iPad: "iPad"
    case .watch: "Apple Watch"
    }
  }

  private func deviceSymbol(_ role: LocalAIDeviceRole) -> String {
    switch role {
    case .iPhone: "iphone"
    case .mac: "desktopcomputer"
    case .iPad: "ipad"
    case .watch: "applewatch"
    }
  }
}

private struct LocalAINetworkStatusView: View {
  @Environment(\.energyTheme) private var theme
  @ObservedObject var hub: LocalAINetworkHub

  var body: some View {
    Label(hub.status, systemImage: hub.isReceiving ? "antenna.radiowaves.left.and.right" : "network.slash")
      .font(.footnote).foregroundStyle(theme.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
#endif
