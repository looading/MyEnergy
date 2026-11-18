# MyEnergy

面向 iPhone、iPad、Apple Watch 和 Mac 的原生精力记录与健康习惯应用。

当前交付为四端本地 MVP、Apple 平台适配源码和开发环境的加密同步联调。Mac 已实际运行验证；本轮补齐 Watch 本机健康入口、睡眠详情和设备设置，完整本地回归及修复后的 Watch／iOS／Mac 最终构建均通过。专用配对模拟器已启动、两端应用已安装；MyEnergy 原生 UI 尚未验收，当前因 Mac 锁屏等待用户手动解锁。用户已选择先完成本地版本与开发账号联调。真实 Apple 登录、健康授权、配对真机传输及正式发布放到后续阶段，不阻塞本轮本地验收。

## 立即体验

需要 Xcode、Swift 6、XcodeGen 2.47 或兼容版本。最低系统为 macOS 14、iOS／iPadOS 17、watchOS 10。

```sh
./scripts/run-mac.sh
```

已构建的应用位于 `build/DerivedData/Build/Products/Debug/MyEnergy.app`，也可以打开 `MyEnergy.xcodeproj` 选择 scheme。

应用图标主图为 [myenergy-icon-v1.png](Assets/Brand/myenergy-icon-v1.png)，1024 × 1024、无透明通道；iPhone／iPad、Mac 和 Watch 已配置对应图标资源。[图标说明](docs/design/app-icon.md)记录设计、生成提示词和资源位置。

## 当前功能

- 今日看板、0～100 主观精力、五档独立心情、备注和发生时间。
- 二维连续状态主题：心情决定色彩倾向，精力独立改变鲜明程度；按最近 24 小时有效记录变化，编辑时可临时预览，取消后恢复。设置中有四个只读配色示例。
- 记录新增、详情、编辑、删除和完整历史入口。
- 习惯创建、编辑、停用、恢复、完成与撤销。
- 7／30 天趋势及等价逐日列表，缺失日不计为零。
- 独立睡眠页、开始／结束与每日主要时长、7／30 天睡眠变化；本地可手动补记并编辑／删除，明确标为自述时段估算。
- 自动睡眠来源按需读取 Apple 健康，重叠样本去重；同日不同来源不相加，原始历史留在设备。
- 独立内存示例空间，持续标识，退出后恢复本人记录；示例不读取健康或同步。
- 校验、原子文件存储、损坏文件保留、JSON 导出及删除标记。
- iPhone tab、iPad／Mac 侧栏、Watch 快记与 Digital Crown；深色及动态字体适配。
- Watch 首页保留快记、最近自评和习惯，身体参考、睡眠详情、设备与设置分别展开；保存成功触觉可关闭。
- Watch 主动连接本机 Apple 健康，查看 HRV SDNN（ms）、个人历史对照、静息心率和睡眠；无样本、历史不足、过期、读取中与失败分别说明。
- HealthKit 只读适配、HRV 历史对照、睡眠区间去重；Mac 不申请健康读取。
- Watch 持久队列、账号命名空间、因果基线、显式保存确认和冲突选择。

精力与心情来自自评，身体参考独立展示。健康摘要默认关闭；仅在用户单独同意后同步选定的当前摘要，不包含 HealthKit 原始样本或历史序列。Mac 可显示来源、采样时间和更新时间。

体验主题时，点击“记一下”并调整精力或心情，可看到约 1.6 秒的连续过渡；取消会恢复当前记录的配色。“我的 → 状态主题”展示四组独立输入的示例，未填写心情时保留中性含义。开启系统“减少动态效果”后关闭该过渡。

## 手表本地体验

本机已通过 Xcode 官方工具安装 iOS 27.2 和 watchOS 27.2 Simulator runtime，并创建专用的 iPhone 18 Pro／Apple Watch Series 12（42 mm）配对模拟器。可使用：

```sh
./scripts/run-watch.sh
# 仅构建并安装，不启动界面
./scripts/run-watch.sh --prepare-only
```

脚本复用并激活专用配对设备，使用带 HealthKit entitlement 的本地 ad-hoc `DeviceDebug` 模拟器构建，安装 iPhone 和 Watch 应用；默认打开 Device Hub 并启动两端，启动前结束已有应用进程以使用最新构建。Xcode 27.2 的模拟器前端名为 Device Hub，可从 Xcode 的 Open Developer Tool 菜单打开；脚本优先使用它，旧环境回退到 Simulator。

本轮 `--prepare-only` 已成功完成两端构建与安装，并从实际可执行文件核对 HealthKit entitlement。已观察到 Device Hub 的专用 Watch 表盘和配对指示；随后 Mac 锁屏，尚未打开 MyEnergy，全部应用 UI 用例仍未验收。模拟器数据与已有 Mac 本机记录分开，详细结果见[验证报告](docs/verification/report.md)。

在手表“身体参考”中点击连接，才会请求健康只读授权。请求完成不代表所有读权限获准，空结果也不能判定拒绝。连接仅在本次进程内有效；进入前台后，已连接状态按最近尝试间隔至少五分钟重读，手动重试可立即执行。失败保留上次结果和时间；停止读取会清除本机临时展示，示例不读取或共享健康。

手表账号沿用配对 iPhone 的账号空间，没有独立云登录。匿名配对空间不能开启健康摘要共享。用户单独确认后，最新摘要经配对 iPhone 进入同账号服务；停止更新并移除此手表摘要也有明确确认，删除需恢复同步后传播。睡眠详情展示最近主要观测及近 7 天逐日列表，来源、起止时间与时区可查，缺失日留白；手动补记仍在 iPhone 完成。

## 本机加密同步

使用 Node.js 24 以上及内置 SQLite，无 npm 依赖：

```sh
./scripts/run-server.sh
```

应用“我的 → 设备与同步”保留 `http://127.0.0.1:8787`，展开“本机开发联调”，在两端输入相同开发账号名称。首台设备创建恢复密钥，另一台导入原恢复密钥。开发入口只在 Debug 界面及显式开启的 loopback 服务中存在，不代表真实 Apple 登录。

账号空间与原离线记录分开；只有主动选择“合并此设备的离线记录”才合并。密钥保存在当前设备 Keychain，不发送给服务。服务保存 AES-GCM 密文；同账号登录不等于取得解密能力。

前台记录变更延迟同步，进入前台尝试更新，也提供手动同步。状态只确认当前设备与服务的一轮交换，不声称全部设备同时收到。真正冲突要求用户选择版本，删除标记防止离线复活。

生产部署、TLS、密钥轮换／恢复审查、设备撤销与远端清除须在 M3／M4 继续验收。

## 一键本地联调验收

```sh
./scripts/test-local.sh
./scripts/check-local-keychain.sh
```

第一条会自动启动临时 SQLite 与随机端口的隔离服务，运行全部 Swift 测试（包含账号生命周期与双客户端联调）和服务端测试，并清理自己的进程与临时文件。不占用正在体验的 8787 服务，无需 Apple Team、账号密码或 sudo。第二条用随机测试项目验证 Mac Debug 系统钥匙串跨进程写入、读取和删除，不访问已有应用凭据。

Mac Debug 使用系统登录钥匙串的独立开发空间，解决未签名构建访问数据保护钥匙串的 `-34018`。密钥没有改为明文文件；Release、iOS 与 watchOS 继续采用数据保护钥匙串。开发与正式版凭据不自动混用，正式环境需要重新登录并按恢复流程导入密钥。

## 构建与测试

```sh
./scripts/test.sh
./scripts/build.sh MyEnergyMac
./scripts/build.sh MyEnergyiOS
./scripts/build.sh MyEnergyWatch
```

完整双客户端集成测试先在另一终端启动服务，再运行：

```sh
MYENERGY_TEST_SYNC_URL=http://127.0.0.1:8787 ./scripts/test.sh
```

直接运行通用测试且不配置服务地址时，三项双客户端测试及八项账号生命周期测试会明确跳过；本轮验收使用 test-local.sh，相关用例全部实际执行。iPhone 和 iPad 共用 iOS target，device family 为 1、2；构建串行执行。

本轮 Watch 补齐后的完整 `./scripts/test-local.sh` 通过：124 项 Swift（35 XCTest、89 Swift Testing）和 8 项 Node 服务测试，0 失败、0 跳过。新增回归覆盖健康生命周期、前台节流、晚到结果隔离、匿名共享保护，以及账号切换后旧确认的失效。跨账号旧确认 P2 已修复并经复核关闭，当前未解决的确定 P1／P2 为 0。修复后 `MyEnergyWatch`、`MyEnergyiOS`（含 Watch）与 `MyEnergyMac` 最终通用目标构建均为 `BUILD SUCCEEDED`；配对模拟器 DeviceDebug 构建和两端安装也已通过。应用 UI 因 Mac 锁屏尚未验收。

二维主题阶段的 MyEnergyUI、Mac 与 iPhone／iPad 构建和 Mac 主题交互证据继续保留。Simulator runtime 当前已可用，通用目标编译仍不能替代模拟器 UI 或真机运行；系统辅助功能与各平台边界见[验证报告](docs/verification/report.md)。

## 真机配置

通用目标的无 Team `Debug` 关闭签名及需团队的 entitlement。`run-watch.sh` 的模拟器 `DeviceDebug` 使用本地 ad-hoc 签名携带 HealthKit entitlement，不需要 Apple Team；这不等于真机签名完成。真机使用 `DeviceDebug` configuration，配置你的 Team、唯一 Bundle ID、HealthKit 和 Sign in with Apple；Watch companion 与 iPhone 关联标识保持一致。

真实身份要求服务设置 `MYENERGY_APPLE_AUDIENCES`，并与开发者团队的 App ID 分组一致。参考 `server/.env.example`，不提交 `.env`、令牌、证书和私钥。

HealthKit 需要支持设备及授权；空结果不能证明拒绝授权。Watch 后台传输需配对真机。当前消息上限 60 KiB，包含完整快照及因果基线，大量历史会得到明确大小错误，后续需改为增量事件。

## 工程与管理

`Apps/` 是原生入口；`Packages/MyEnergyKit/` 是 Core／Platform／UI；`server/` 是身份与密文服务；`Configuration/` 和 `scripts/` 支持复现构建。独立 Git 分支为 `codex/myenergy-mvp`，尚未配置远程仓库。

- [当前状态](docs/project/status.md)
- [验证报告](docs/verification/report.md)
- [已批准设计](docs/design/mvp-proposal.md)
- [交付计划](docs/project/delivery-plan.md)
- [风险台账](docs/project/risk-register.md)
- [共享接口](docs/implementation/contracts.md)
- [Apple 平台依据](docs/research/apple-platform-feasibility.md)

睡眠观测的日期与时区、来源优先级和数据边界见 [睡眠增量说明](docs/implementation/sleep-observation.md)。
二维主题的状态来源、未知状态与过渡规则见[状态主题说明](docs/implementation/state-theme.md)；颜色设计依据与适用限制见[颜色心理学核查](docs/research/color-psychology.md)。
手表补齐范围、健康生命周期和数据边界见[手表功能设计](docs/design/watch-completion.md)及[实施计划](docs/implementation/2026-11-18-watch-plan.md)。
