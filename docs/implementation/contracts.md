# 首版共享契约

状态：执行基线。用户于 2026-11-18 明确回复“按推荐方案进入实现”。本文件固定并行任务接口；变更先通知使用方。

## 文件归属

- core agent：`Packages/MyEnergyKit/Sources/MyEnergyCore/`、`Tests/MyEnergyCoreTests/Core*`。
- UI agent：`Packages/MyEnergyKit/Sources/MyEnergyUI/`，其中 `AccountSettingsView.swift` 和 `AppModel+Sync.swift` 由 root 后续集成。
- platform agent：`Packages/MyEnergyKit/Sources/MyEnergyPlatform/Health*`、`Watch*`、`Keychain*`、`AppleSignIn*`；`Tests/MyEnergyCoreTests/Platform*`。
- root：Package.swift、应用入口、Xcode 工程及配置、脚本、服务端、`MyEnergyPlatform/Sync*`、`Vault*`、`Account*`、UI 中上述两个预留文件、集成修复及文档。
- 构建和测试由 root 串行调度；agent 提交源码、测试与建议命令，不并发运行构建。

## 核心公共 API

所有公开值类型为 `Codable, Equatable, Sendable`，需要列表身份的类型为 `Identifiable`。日期与 UUID 由调用方可注入，不用全局共享可变状态。

```swift
public enum Mood: String, CaseIterable, Codable, Sendable {
  case veryLow, low, neutral, good, veryGood
  public var title: String { get }
  public var symbol: String { get }
}

public struct EnergyEntry: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var energy: Int
  public var mood: Mood?
  public var note: String
  public var occurredAt: Date
  public var modifiedAt: Date
  public var timeZoneIdentifier: String
  public init(id: UUID = UUID(), energy: Int, mood: Mood? = nil,
    note: String = "", occurredAt: Date = Date(), modifiedAt: Date? = nil,
    timeZoneIdentifier: String = TimeZone.current.identifier) throws
}

public struct HabitDefinition: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var symbol: String
  public var isArchived: Bool
  public var createdAt: Date
  public var modifiedAt: Date
  public init(id: UUID = UUID(), title: String, symbol: String = "leaf",
    isArchived: Bool = false, createdAt: Date = Date(), modifiedAt: Date? = nil) throws
}

public struct HabitCheckIn: Identifiable, Codable, Equatable, Sendable {
  public var id: String { get } // stable habit UUID + YYYY-MM-DD
  public let habitID: UUID
  public let dayKey: String
  public var isComplete: Bool
  public var modifiedAt: Date
  public init(habitID: UUID, dayKey: String, isComplete: Bool,
    modifiedAt: Date = Date()) throws
}

public enum EntityKind: String, Codable, Sendable { case entry, habit, checkIn }
public struct DeletionRecord: Identifiable, Codable, Equatable, Sendable {
  public var id: String { get }
  public let entity: EntityKind
  public let entityID: String
  public let deletedAt: Date
  public init(entity: EntityKind, entityID: String, deletedAt: Date = Date())
}

public struct AppSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var entries: [EnergyEntry]
  public var habits: [HabitDefinition]
  public var checkIns: [HabitCheckIn]
  public var deletions: [DeletionRecord]
  public init(schemaVersion: Int = 1, entries: [EnergyEntry] = [],
    habits: [HabitDefinition] = [], checkIns: [HabitCheckIn] = [],
    deletions: [DeletionRecord] = [])
  public func validated() throws -> AppSnapshot
}

public enum DateRules {
  public static func dayKey(for date: Date, timeZone: TimeZone = .current) -> String
  public static func recentDays(count: Int, endingAt: Date = Date(),
    timeZone: TimeZone = .current) -> [Date]
}

public actor SnapshotFileStore {
  public init(url: URL)
  public func load() throws -> AppSnapshot // missing file => empty; corrupt => throw, preserve bytes
  public func save(_ snapshot: AppSnapshot) throws // validate, atomic, protect and mark backup exclusion
  public func delete() throws
}
```

精力必须为 0～100，备注最多 500 个字符；习惯标题 trim 后 1～40 字符。解码也检查这些约束，未知 schemaVersion 必须报错而非覆盖。日期键使用 Gregorian＋`en_US_POSIX`＋明确时区；打卡日期在首次创建时固定，旅行后不重写历史归属。

## 三方合并

```swift
public enum ConflictSide: Sendable { case local, remote }
public struct MergeConflict: Identifiable, Equatable, Sendable {
  public let id: String
  public let entity: EntityKind
  public let entityID: String
}
public struct SnapshotMergeResult: Sendable {
  public let snapshot: AppSnapshot
  public let conflicts: [MergeConflict]
}
public enum SnapshotMerger {
  public static func merge(base: AppSnapshot, local: AppSnapshot,
    remote: AppSnapshot) -> SnapshotMergeResult
  public static func resolve(base: AppSnapshot, local: AppSnapshot,
    remote: AppSnapshot, favoring: ConflictSide) -> AppSnapshot
}
```

按实体 ID 做三方合并，不按墙上时钟选赢家。不同记录的新增／修改自动合并，同实体两端相对 base 均改且内容不同时返回冲突。`merge.snapshot` 暂保留冲突本机版本，其余非冲突变化仍合并；`resolve` 只选择冲突实体的版本。显式 tombstone 优先删除，合并删除标记集合，防止离线复活；删除习惯清除相应打卡。输出按稳定 ID 排序。

## 恢复参考

```swift
public struct HRVSample: Codable, Equatable, Sendable {
  public let valueMS: Double
  public let date: Date
  public init(valueMS: Double, date: Date)
}
public enum RecoveryStatus: String, Codable, Sendable {
  case unavailable, insufficientHistory, stale, ready
}
public struct RecoverySummary: Codable, Equatable, Sendable {
  public let status: RecoveryStatus
  public let latestMS: Double?
  public let baselineMS: Double?
  public let changePercent: Double?
  public let sampledAt: Date?
  public let historyDays: Int
}
public enum RecoveryAnalyzer {
  public static func analyze(samples: [HRVSample], now: Date = Date()) -> RecoverySummary
}
```

首版只做历史对照：过滤非正、非有限、未来样本；最新样本超过 24 小时则标记过期；此前 30 天且不包含最近 24 小时的历史按 UTC 日汇总中位数，至少 7 个有效日后给出日中位数的中位数基线与百分比变化。该规则是产品对照算法，不是临床阈值，不给“焦虑／健康／异常”分类。

## 平台公共 API

```swift
public struct HealthReport: Sendable {
  public var recovery: RecoverySummary
  public var restingHeartRate: Double?
  public var sleepHours: Double?
  public var updatedAt: Date
  public var sourceDescription: String
  public init(recovery: RecoverySummary, restingHeartRate: Double? = nil,
    sleepHours: Double? = nil, updatedAt: Date = Date(), sourceDescription: String)
}
@MainActor public final class HealthDataClient {
  public init()
  public var isAvailable: Bool { get }
  public func requestReadAccess() async throws
  public func fetchReport(now: Date = Date()) async throws -> HealthReport
}
public enum KeychainStore {
  public static func read(key: String) throws -> Data?
  public static func write(_ data: Data, key: String) throws
  public static func delete(key: String) throws
}
```

HealthDataClient 必须可在 macOS 编译并返回不支持状态，不请求写入权限。iPhone／iPad 获取 HRV／静息心率／最近完整夜间睡眠；睡眠区间去重且避免 inBed 和 asleep 同时累加。空样本不能断言已知拒绝。HealthReport 不进入 AppSnapshot 默认同步。后续需要显式健康摘要授权与独立记录类型。

Watch 平台 agent 在 `WatchBridge.swift` 自行提供清晰 API（通过完成消息通知 root 与 UI），持久队列、消息版本、幂等、显式 ACK，不用 applicationContext 承载每条记录。root 负责将收到的 snapshot 交给 AppModel，双方约定不自动启动 HealthKit 查询。

## UI 对外入口

```swift
@MainActor public final class AppModel: ObservableObject {
  @Published public var snapshot: AppSnapshot
  @Published public var errorMessage: String?
  public init(storageURL: URL? = nil)
  public func load() async
  public func persist() async
}
public struct MyEnergyRootView: View {
  public init(model: AppModel)
}
public struct MyEnergyWatchView: View {
  public init(model: AppModel)
}
```

AppModel 的 snapshot 真实数据空间使用磁盘，演示数据空间单独内存且持续标识，不写入真实空间、不同步。入口 `.task` 调用 `load`，操作保存失败时保留输入，不把内存状态伪装持久化成功。root 集成账户面板时通过公开 `snapshot` 和 `persist` 操作，不让界面依赖服务端内部结构。

## 服务端协议（root）

独立 Node.js 服务，SQLite 持久化。`POST /v1/auth/challenge`，`POST /v1/auth/apple` 验证 Apple 公钥／签名、issuer、audience、exp 与一次性 nonce；开发身份仅在显式开启且绑定 loopback 时存在。响应为应用 session，不把 Apple identityToken 用作加密密钥。

`GET /v1/vault` 返回 `{revision, ciphertext, mutationID}`；`PUT /v1/vault` 使用 `{expectedRevision, mutationID, ciphertext}` CAS，冲突返回 409；账户从 session 导出，不接受客户端用户 ID 来越权。`DELETE /v1/account` 删除 vault 并撤销账户会话，旧 token 不能复活数据。AES-GCM 密文在 Swift 客户端生成，AAD 绑定应用账户；服务端不持有恢复密钥。操作规模与正文大小有限制，错误响应不含令牌／用户正文。

## 已集成的兼容补充

AppSnapshot 追加默认空的 sharedHealthSummaries，旧 schema 1 解码兼容。SharedHealthSummary 只保存当前恢复参考、静息心率、睡眠汇总、来源和时间，不含原始历史。EntityKind 追加 healthSummary；关闭分享通过该类型 tombstone 删除，重新同意使用新 UUID。UI 默认关闭，账号切换清除临时授权，不自动移除上一空间已共享内容。

Watch wire v2 追加因果 baseSnapshot；sendSnapshot(_:base:) 对 FIFO 待发送消息按前驱快照链接，ACK 回调成功持久化后才出队。完整快照加基线共用 60 KiB 上限。storageURL 的发布同步驱动账号 namespace，接收方再次核对空间。
