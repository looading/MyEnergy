import Darwin
import Foundation
import MyEnergyCore
import MyEnergyLocalAI

/// 只使用下方虚构事实，不访问应用记录、账号、钥匙串或同步服务。
@main
struct MyEnergyAIProbe {
  static func main() async {
    let operation = Task { try await run(Array(CommandLine.arguments.dropFirst())) }
    // 把终端中断映射到 Swift 取消，等待下载清理或 GPU 同步后再退出。
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { operation.cancel() }
    interrupt.resume()
    defer { interrupt.cancel(); signal(SIGINT, SIG_DFL) }
    do {
      try await operation.value
    } catch is CancellationError {
      FileHandle.standardError.write(Data("已取消。\n".utf8))
      exit(130)
    } catch let error as LocalAIError {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    } catch {
      FileHandle.standardError.write(Data("探针未完成，请检查命令和构建环境；未读取应用记录。\n".utf8))
      exit(1)
    }
  }

  private static func run(_ arguments: [String]) async throws {
    guard let command = arguments.first, ["status", "download", "generate"].contains(command) else {
      throw LocalAIError.invalidInput("用法：MyEnergyAIProbe status|download|generate [--assets 本地目录] [--system] [--scenario basic|full-day]")
    }
    var root: URL?
    var system = false
    var scenario = "basic"
    var index = 1
    while index < arguments.count {
      switch arguments[index] {
      case "--assets":
        guard index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
          throw LocalAIError.invalidInput("--assets 需要绝对目录。")
        }
        root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        index += 2
      case "--system": system = true; index += 1
      case "--scenario":
        guard index + 1 < arguments.count, ["basic", "full-day"].contains(arguments[index + 1]) else {
          throw LocalAIError.invalidInput("--scenario 只接受 basic 或 full-day。")
        }
        scenario = arguments[index + 1]
        index += 2
      default: throw LocalAIError.invalidInput("未知探针参数。")
      }
    }
    let assets = QwenModelAssetStore(rootDirectory: root)
    let apple = AppleSystemReflectionRunner(role: .mac, deviceID: "synthetic-probe")
    let mlx = MLXReflectionRunner(role: .mac, deviceID: "synthetic-probe", assets: assets)
    switch command {
    case "status":
      let state = await assets.status()
      try printJSON([
        "modelID": QwenAssetManifest.modelID,
        "revision": QwenAssetManifest.revision,
        "downloadBytes": QwenAssetManifest.totalBytes,
        "assets": assetDescription(state),
        "appleSystem": availabilityDescription(await apple.availability()),
        "mlx": availabilityDescription(await mlx.availability()),
        "readsApplicationRecords": false
      ])
    case "download":
      let reporter = DownloadProgressReporter()
      try await assets.download { reporter.report($0) }
      try printJSON(["assets": assetDescription(await assets.status()),
        "revision": QwenAssetManifest.revision, "downloadBytes": QwenAssetManifest.totalBytes])
    case "generate":
      let input = try syntheticInput(scenario: scenario)
      let request = try DailyReflectionRequest(input: input).validated()
      let started = Date()
      let result: DailyReflectionResult
      if system { result = try await apple.reflect(request) }
      else { result = try await mlx.reflect(request) }
      let resultData = try JSONEncoder().encode(result)
      let safeResult = try JSONSerialization.jsonObject(with: resultData)
      var report: [String: Any] = ["fixture": "synthetic-only", "result": safeResult,
        "scenario": scenario,
        "input": try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)),
        "totalElapsedSeconds": Date().timeIntervalSince(started), "readsApplicationRecords": false]
      if !system, let metrics = await mlx.lastMetrics() {
        report["metrics"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics))
        report["revision"] = QwenAssetManifest.revision
      }
      try printJSON(report)
    default: break
    }
  }

  private static func syntheticInput(scenario: String) throws -> DailyReflectionInput {
    if scenario == "basic" {
      return DailyReflectionInput(dayKey: "2026-11-20", timeZoneIdentifier: "Asia/Shanghai",
        facts: [
          DailyReflectionFact(id: "energy_summary", statement: "当天有两条主观精力记录，分别为五十分和七十分。"),
          DailyReflectionFact(id: "habit_summary", statement: "习惯一当天已完成，习惯内容未提供。")
        ], missingData: ["当天没有手动睡眠记录。", "当天没有心情记录。"],
        entryCount: 2, habitCount: 1, manualSleepCount: 0)
    }
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    let end = Date(timeIntervalSince1970: 1_795_165_200) // 固定合成日期，避免依赖真实记录。
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let start = calendar.startOfDay(for: end)
    let entries = try (0..<14).map { index in
      try EnergyEntry(energy: 40 + index * 3, mood: index.isMultiple(of: 2) ? .neutral : .good,
        note: "合成备注不应进入输入", occurredAt: start.addingTimeInterval(Double(index + 1) * 3_600),
        timeZoneIdentifier: zone.identifier)
    }
    let habits = try (0..<7).map { index in
      try HabitDefinition(title: "合成习惯原名\(index)", createdAt: start.addingTimeInterval(-86_400))
    }
    let checkIns = try habits.prefix(3).map {
      try HabitCheckIn(habitID: $0.id, dayKey: DateRules.dayKey(for: end, timeZone: zone), isComplete: true)
    }
    let sleep = try SleepRecord(bedtime: start.addingTimeInterval(-3_600),
      wakeTime: start.addingTimeInterval(6 * 3_600), timeZoneIdentifier: zone.identifier,
      note: "合成睡眠备注不应进入输入")
    return try DailyReflectionInputBuilder.build(snapshot: AppSnapshot(entries: entries, habits: habits,
      checkIns: checkIns, sleepRecords: [sleep]), day: end, timeZone: zone)
  }

  private static func printJSON(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
  }

  private static func availabilityDescription(_ value: LocalAIAvailability) -> String {
    switch value {
    case .ready: return "ready"
    case .unavailable(let reason): return reason
    }
  }

  private static func assetDescription(_ value: LocalAIModelAssetState) -> String {
    switch value {
    case .notDownloaded: return "notDownloaded"
    case .downloading: return "downloading"
    case .ready: return "ready"
    case .failed(let reason): return reason
    }
  }
}

private final class DownloadProgressReporter: @unchecked Sendable {
  private let lock = NSLock()
  private var lastBucket = -1

  func report(_ value: Double) {
    let bucket = Int(min(1, max(0, value)) * 10)
    let shouldPrint = lock.withLock {
      guard bucket > lastBucket else { return false }
      lastBucket = bucket
      return true
    }
    if shouldPrint { FileHandle.standardError.write(Data("模型下载 \(bucket * 10)%\n".utf8)) }
  }
}
