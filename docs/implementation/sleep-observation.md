# 睡眠观测增量

状态：用户于 2026-11-18 明确要求将睡眠纳入观测。本增量沿用已批准的原生、本地开发和独立加密同步架构，不改变真实账号／真机后续验收安排。

## 产品范围

新增独立“睡眠”导航、今日睡眠入口和 7／30 天观测。观察实际睡眠时长、记录开始与结束时间、来源和数据时间；不生成疾病、睡眠质量或恢复效果评分。阶段细分暂不纳入本次增量，避免将未分期的样本猜测为深睡或 REM。

本地可手动补记睡眠时段、备注并编辑／删除；清楚标明这是自述时段估算，不是传感器测得的实际睡眠。自动来源继续按需读取 Apple 健康。原始健康睡眠历史不进入账号同步；明确共享后只传最新的选定睡眠摘要。手动记录作为用户自己填写的应用记录随账号加密同步。

## 数据与汇总规则

先将有效 asleep 区间求并集，不计 inBed、awake，不重复计算重叠来源。相邻真实睡眠区间间隔不超过 3 小时时，归为同一睡眠片段；3 小时仅是展示分组规则，不是医学判断。片段实际睡眠时长是并集之和，开始和结束表示观测边界；不能称为已知真实入睡潜伏期或起床时间。

片段保留来源时区；趋势日期范围和结束日期分组统一采用查看设备的时区，避免跨设备／旅行时把已结束的记录误排到范围外。起止时间显示原来源时区。同一天多段取实际睡眠时长最长的一段作为每日主要观测，不将不同来源和手工补记相加。列表可展示更多片段。某日期优先本机 Apple 健康，其次已授权共享摘要，再次手动补记；缺失日留白，平均值仅计算有观测的日子。标注“每日主要睡眠”，不将它描述为全天总睡眠。

## 并行接口

Core／Platform agent 拥有 Core 的新增模型及兼容扩展、HealthSleepAnalyzer 和 HealthDataClient；UI agent 拥有 SleepView／SleepEditor、导航和 Today／Watch 入口。root 拥有 AppModel、应用层聚合与集成测试、文档及统一构建。不要并行修改对方文件。

```swift
public struct SleepRecord: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var bedtime: Date
  public var wakeTime: Date
  public var timeZoneIdentifier: String
  public var note: String
  public var modifiedAt: Date
  public init(id: UUID = UUID(), bedtime: Date, wakeTime: Date,
    timeZoneIdentifier: String = TimeZone.current.identifier,
    note: String = "", modifiedAt: Date = Date()) throws
  public var durationHours: Double { get }
}

public struct SleepNight: Identifiable, Codable, Equatable, Sendable {
  public var id: String { get } // deterministic start/end/time-zone
  public let bedtime: Date
  public let wakeTime: Date
  public let asleepSeconds: Double
  public let timeZoneIdentifier: String
  public let sourceDescription: String
  public init(bedtime: Date, wakeTime: Date, asleepSeconds: Double,
    timeZoneIdentifier: String = TimeZone.current.identifier,
    sourceDescription: String) throws
  public var durationHours: Double { get }
  public var dayKey: String { get }
}
```

日期必须有限且结束晚于开始，单条时段不超过 24 小时；SleepNight 的实际睡眠秒数为正且不超过时段。备注最多 500 字符，时区有效。AppModel 保存手工记录时额外拒绝未来的结束时间。

`AppSnapshot` 追加默认空 `sleepRecords: [SleepRecord]`，旧 schema 1 缺字段兼容；`EntityKind.sleep`、UUID tombstone、三方合并、删除防复活覆盖该类型。`SharedHealthSummary` 追加可选 `sleepNight: SleepNight? = nil`；旧数据兼容，已有 sleepHours 保留。

`HealthReport` 追加 `sleepHistory: [SleepNight] = []`（参数放初始化末尾，保持调用兼容）。`HealthSleepAnalyzer.nights(intervals:now:timeZone:) -> [SleepNight]` 在查询所得 30 天内生成按时间排序的片段；未来、未结束、无效区间不参与。HealthDataClient 的 sleepHours 和最新共享 sleepNight 采用同一条最近的主要观测，不与旧 noon 标量算法相矛盾。旧 helper 可保留用于兼容测试，但新页面使用新结构。

root 提供 UI 接口：

```swift
extension AppModel {
  public func saveSleep(id: UUID? = nil, bedtime: Date, wakeTime: Date,
    note: String = "") async -> Bool
  public func deleteSleep(_ record: SleepRecord) async -> Bool
  public func sleepObservations(days: Int, now: Date = Date()) -> [SleepObservation]
  public var latestSleepObservation: SleepObservation? { get }
}
public struct SleepObservation: Identifiable, Equatable {
  public let dayKey: String
  public let bedtime: Date
  public let wakeTime: Date
  public let durationHours: Double
  public let sourceTitle: String
  public let isEstimated: Bool
  public var id: String { dayKey }
}
```

AppModel 的本机健康历史优先，显式共享摘要其次，手工记录最后；同优先级同一天取最长片段，时长相同时按结束时间稳定选择。root 更新共享摘要创建、整空间删除、示例数据和 JSON 导出说明。手工记录取消或保存失败保留输入，删除后过期编辑器不能复活。

## 验收

- 模型校验及旧快照兼容；跨午夜／DST／重叠／awake／未来区间与缺失日。
- 手工记录增删改、重启、示例隔离、整空间删除、加密传输和 tombstone。
- 页面有独立来源和时间，7／30 天有观测日平均值，缺失不计 0；不自动请求权限。
- Mac 实际界面、受影响 Swift 测试和原生通用目标编译；真实健康样本仍单独待真机验收。
