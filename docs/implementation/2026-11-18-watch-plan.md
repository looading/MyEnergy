# Watch Completion Implementation Plan

> **For agentic workers:** 使用当前多 agent 分工执行；root 统一集成、串行构建与验证，按任务逐项更新证据。

**Goal:** 补齐手表自身健康授权、HRV／睡眠参考、前台生命周期和小屏操作。

**Architecture:** 复用 HealthDataClient 与 AppModel，Watch 专用页面只负责展示和用户动作。AppDeviceCoordinator 明确传递配对账号上下文；健康原始历史留本机，最新摘要经单独同意后进入既有配对与账号同步。

**Tech Stack:** Swift 6、SwiftUI、watchOS 10+、iOS 17+、HealthKit、WatchConnectivity。

## 共同约束

- 健康参考与自评独立，不推断情绪、疾病或压力分数。
- 不自动请求授权，不写 HealthKit 样本，不增加后台运行模式。
- 构建、测试由 root 串行执行；实现 agent 文件所有权互不重叠。
- 真机、模拟器和通用目标编译分别记录，不以测试夹具充当真实健康测量。

## 健康生命周期工作包 W1

负责人：Health model agent。修改 `Packages/MyEnergyKit/Sources/MyEnergyUI/AppModel.swift`，新增 `WatchHealthModelTests.swift`、必要的纯展示状态文件。

输入：现有 `AppHealthClient`、`HealthReport` 和 `RecoverySummary`。产出接口：

```swift
func updateCompanionHealthContext(namespace: String)
func refreshHealthIfNeeded(now: Date = Date()) async
```

`hasHealthSharingAccountContext` 在 companion 上只接受有效 account namespace；默认 Watch 为匿名配对。保留已有 connect/refresh/disconnect API。前台五分钟节流依据最近尝试，未连接、示例、进行中不请求。报告按当前时刻展现过期。为暂停的授权／查询、停止／空间切换、无样本、刷新失败、节流及共享上下文编写聚焦测试。

- [x] 连接与刷新状态、账号上下文、纯展示时效完成。
- [x] 注入客户端回归由 root 执行；完整 124 项 Swift 与 8 项 Node 通过。

## 手表界面工作包 W2

负责人：Watch UI agent。修改 `MyEnergyWatchView.swift`，新增 `WatchHealthView.swift`、`WatchSleepView.swift`，可新增 Watch 专属设置文件；不改 AppModel、AppModel+Sync 或平台客户端。

消耗 W1 及现有 AppModel API。身体页调用 `connectHealth()`、`refreshHealth()`、`disconnectHealth()`；共享调用 `setHealthSharing(_:)`，启用前确认字段与路径。首页分出身体、睡眠、设备设置入口。睡眠复用 `sleepObservations(days:now:)` 和 `SleepObservation`。预览继续 `stateThemeDraft`，保存状态与输入保留，示例禁止读取和共享。

- [x] 身体参考、睡眠详情、首页／设置分工与窄屏布局代码完成。
- [x] Watch 通用目标和配对模拟器 DeviceDebug 构建通过。
- [ ] App 界面验收：设备已启动并安装，Mac 锁屏后等待用户手动解锁；尚未记录为通过。

## 配对上下文与平台工作包 W3

负责人：root。修改 `AppModel+Sync.swift` 与 `Apps/MyEnergyWatch/MyEnergyWatchApp.swift`。在 Watch 成功采用 namespace 后调用 `updateCompanionHealthContext(namespace:)`，存储切换失败不启用新上下文；启动和账号切换均覆盖。Watch 进入 active 时同时重试传输及调用 `refreshHealthIfNeeded()`，不自动请求授权。正式 HealthKit entitlement 和用途说明沿用工程配置并核对。

新增 `scripts/run-watch.sh` 和 `scripts/helpers/watch-simulator.mjs`，创建／复用本项目专用 pair。支持 `--prepare-only`；模拟器使用 DeviceDebug 本地 ad-hoc 构建，Xcode 27 的 Device Hub 与旧 Simulator 前端均可启动。未删除或重置其他设备。

- [x] 配对上下文与前台生命周期完成。
- [x] Xcode 官方 iOS／watchOS 27.2 运行时可用，专用配对设备启动与两端安装成功。
- [x] 核对两端 arm64 主程序的模拟器权限段，HealthKit 为 true。

## 集成与收尾工作包 W4

负责人：root；独立 reviewer 检查 W1～W3 及直接调用方。统一执行：

```sh
./scripts/test-local.sh
./scripts/build.sh MyEnergyWatch
./scripts/build.sh MyEnergyiOS
./scripts/build.sh MyEnergyMac
git diff --check
```

测试失败先区分代码与环境原因，聚焦修复后运行受影响范围；源码冻结后复用已通过结果。更新 README、status、risk、verification 报告和实际 UI 结果，提交本轮改动。

- [x] 独立 review 发现的 P2 已修复并复核关闭；旧确认绑定 expectedStorageURL，异步回归通过。
- [x] 完整回归与最终 Watch／iOS／Mac 三目标构建通过。
- [ ] 记录 App 实际界面结果后完成本轮体验收尾；解锁前只交付实现与已验证部分。
