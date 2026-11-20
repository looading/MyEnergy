# 当前状态与决策记录

更新：2026-11-18。用户先确认推荐方案，随后明确选择“先完成本地版本与开发账号联调”，并要求完成手表功能。本轮补齐 Watch 本机健康与睡眠体验，真实身份／真机／发布继续为后续阶段。

## 里程碑

| 里程碑 | 状态 | 证据与缺口 |
| --- | --- | --- |
| M0 设计确认 | 已通过 | 用户批准方案 A、首版范围及分阶段交付 |
| M1 本地可运行 | 最终回归／构建安装与双向前台实测通过，余下 UI 待验收 | 最终 130 Swift（41 XCTest＋89 Swift Testing）／8 Node 全通过，三个 generic 均成功；20:38 回调崩溃修复经独立 review 和 SDK 重建重装。Phone 收到 Watch 原记录，习惯完成／撤销双向更新，两端 pending 0、进程 1，无新 crash，Watch 重启保留。健康页入口可见，点击前第三次锁屏，未授权或查询 |
| M2 平台接入 | 源码及编译已交付，真机验收依赖外部资源 | 健康只读、恢复计算、睡眠去重、Watch 队列及因果同步；未读真健康数据，未做配对真机传输 |
| M3 四端账号 | 开发环境双客户端联调通过，真实四端未验收 | 服务、Apple JWT 验证、客户端加密、恢复密钥及冲突选择已实现；本机开发账号生命周期及双客户端通过；真实团队、生产服务和真机验证已由用户选择暂缓 |
| M4 发布准备 | 未完成 | 生产密钥生命周期、隐私和安全审查、发布配置、真机功耗及用户接受仍需完成 |

完整证据见 [验证报告](../verification/report.md)，不使用代码行数或主观百分比替代验收。

## 多 agent 工作包

| 负责人 | 工作 | 结果 |
| --- | --- | --- |
| root／PM兼集成 | 共享契约、服务／账号／密文客户端、原生工程、集成与验收 | 已实现及本机验证，维护外部依赖 |
| core agent | 模型、持久化、日期、恢复与三方合并 | 聚焦回归通过 |
| UI agent | 看板、记录、习惯、历史、趋势、示例、导出和 Watch 页面 | 已集成；Mac 实际操作通过；修复窄屏与历史入口 |
| platform agent | HealthKit、Keychain、Apple 登录、Watch 通道 | SDK 编译和纯行为测试通过；修复 namespace 与因果队列 |
| 独立 review | 核心／服务、跨账号、密钥、删除和 Watch 基线 | 确定问题已修复；真实平台整合仍需真机证据 |

前期产品／PMP、Apple 可行性、UX 三个 agent 的文档继续作为基线。

## 已执行决策

独立 Git 仓库，采用原生 SwiftUI，最低支持 iOS／iPadOS 17、macOS 14、watchOS 10。精力自评和心情独立，身体参考不自动分类情绪。个人健康信息不进入自建 CloudKit，原始 HealthReport／样本历史留设备；用户明确同意后，选定当前摘要通过账号密文同步。

独立 Node／SQLite 服务保存客户端密文，身份与密钥分开。Debug 用于无 Team 通用目标检查；专用模拟器 DeviceDebug 采用本地 ad-hoc 签名携带 HealthKit entitlement，真机 DeviceDebug／Release 仍需实际团队。普通实现选择和批准范围内修复自主推进，付费、正式部署和上架未获授权。

## 环境与下一步

Xcode 27.2、Swift 6.4.2、Node.js 26.3.1、XcodeGen 2.47.0，所需 SDK 27.2 已安装。iOS 27.2 与 watchOS 27.2 Simulator runtime 已通过 Xcode 官方工具安装，专用 iPhone 18 Pro 与 Apple Watch Series 12（42 mm）模拟器已创建配对；此前无 runtime 的环境限制已解除。用户选择先完成本地与开发账号联调，本轮不要求真实团队、真机签名、App ID 分组或物理设备；这些事项已移至后续阶段。

已有本地交付证据包括实际 Mac 开发登录与密钥创建、系统钥匙串跨进程回归和一键隔离联调。最后 WCSession 回调并发修复后的完整回归为 130 Swift／8 Node 全通过，三个 generic 目标全部成功；DeviceDebug 双端 SDK 重建重装及实际双向前台、ACK／FIFO 和 Watch 重启保留通过。review P2 均复核关闭，三个 `@Sendable` 修复也经独立 review 确认合理且无同类遗漏。最新两端均 1 条记录、1 个习惯、1 条 isComplete=false 的打卡记录，pending 0；Watch 进程 1，除旧报告外无新 crash。已有 Mac 数据本轮不作改动。

Xcode 27.2 的模拟器前端为 Device Hub，可在 Xcode → Open Developer Tool 打开；脚本优先打开 Device Hub、回退 Simulator，激活自身专用 pair。验收设备偏好尚未答复，继续按已批准范围使用专用模拟器。用户解锁后实际完成 Watch 快记、Phone 接收、跨端习惯完成／撤销和 Watch 重启保留。身体参考页的未连接说明和连接按钮可见；点击前 Mac 第三次锁屏，尚未授权或查询。最新 CUA 仍确认锁屏，第三次解锁请求待答复，暂不继续 UI；用户回复后再验健康、睡眠和主题等余项。

## 本地收尾记录

OS 实测发现原先未签名 Mac Debug 的数据保护钥匙串写入返回 -34018。只对 Mac Debug 切换到独立系统登录钥匙串空间，跨进程写／读／删通过；其他平台及 Release 路径保持数据保护实现。账号恢复补 isBusy 与不可变 endpoint，激活／退出失败可回滚安全存储与记录空间；独立 review 的具体问题已修复。

## 睡眠范围与交付更新

用户于 2026-11-18 明确补充睡眠观测。Core／Platform agent 负责结构化睡眠、兼容存储与真实睡眠区间汇总；UI agent 负责独立页面、导航、今日／Watch 入口和补记；root 负责 AppModel、按来源的日期聚合、加密集成与统一验证；只读 reviewer 检查数据及日期边界。

已交付独立睡眠页、开始／结束及主要时长、7／30 天趋势、来源和缺失状态、手动记录生命周期、显式授权最新摘要跨设备查看。21 项新增回归及现有用例全部通过，Mac 取消草稿／保存／重启已实际操作。原始健康历史仍留设备，真机数据验收继续按后续安排处理。

## 二维状态主题交付更新

用户查阅颜色心理学核查后要求继续实施。主题已从一维加权位置改为心情 valence 与精力 vitality 两个独立维度：心情决定色彩倾向，精力改变鲜明程度；未填写心情保留未知含义，不会仅凭精力显示积极状态。颜色只表达主观记录，不从健康数据推断心情，也不代表健康评分。

Theme engine agent 负责二维状态解析、六组配色锚点、独立心情／精力指示及主题回归；UI agent 负责设置中的四个只读示例和旧静态配色清理；root 负责双轴动画、逐窗口预览生命周期、集成与串行验证；独立 reviewer 检查本次变更，未确认 P1／P2 问题。

主题使用最近 24 小时内最新有效记录，未来和过期记录不驱动当前状态。两个维度约 1.6 秒缓动变化；减少动态效果开启时关闭动画。编辑预览仅作用于所属窗口，取消后恢复，不写入记录或触发同步。

MyEnergyUI 包构建、完整 `./scripts/test-local.sh` 及最新 Mac／iOS 通用目标构建通过，共 35 项 XCTest、71 项 Swift Testing 和 8 项 Node 测试；iOS 构建含 Watch companion。Mac 在独立示例空间中实际观察低落＋0 的灰紫、低落＋100 的莓紫、无心情＋100 的中性鼠尾草、高兴＋100 的金杏，以及高兴＋0 的柔和蓝绿。取消编辑后恢复原有 12 条示例记录；保存一条验收示例后显示 13 条，切换睡眠页再返回仍保持积极且柔和的主题。退出示例后恢复原有 4 条本机记录，临时示例未混入本人空间。

浅色／深色和增强对比度有声明的语义颜色组合数值采样；减少动态效果的关闭动画路径经代码 review 检查。本轮没有通过原生系统设置切换实测浅色、增强对比度或减少动态效果，完整屏幕与控件背景仍待设备 UI 验收。预览自动测试覆盖 token／状态实例隔离和直接 `clear()`，空间切换清空 hook 的证据来自代码 review 及本次退出示例交互。

真实 Apple 登录、HealthKit 授权及真实样本、配对 Watch 真机联通仍未验证。主题阶段未安装 Simulator runtime 的条件现已解除；睡眠观测与本地开发账号联调边界沿用既有约定。

## Watch 功能补齐更新

用户要求“完成手表功能”，按[已记录设计](../design/watch-completion.md)与[实施计划](../implementation/2026-11-18-watch-plan.md)执行。W1 health model agent 负责健康生命周期与注入客户端回归；W2 Watch UI agent 负责首页、身体参考、睡眠详情和设备设置；root 负责配对 namespace、前台生命周期、模拟器准备及统一验证；独立 reviewer 检查本轮差异与直接依赖。

首页保留精力快记、最近自评和习惯。身体页只在用户点击时连接，区分请求／读取中、无样本、失败、历史不足、过期和个人基线对照；HRV SDNN 以 ms 显示，采样、读取和来源分别可查。睡眠页显示最近主要观测及近 7 天逐日列表，来源和起止时区明确，缺失留白。设备传输、触觉和示例移入设置；没有增加长表单、独立 Watch 云登录、后台采样、widget 或睡眠质量／压力分数。

已连接状态进入前台后，按最近读取尝试间隔至少五分钟刷新；失败尝试同样计入节流，手动刷新可立即重试。operationID 与 generation 隔离停止、重连、切空间和示例期间的晚到结果；失败保留旧报告。共享依赖已确认的账号 namespace，匿名空间禁止共享；开启须单独确认字段及经配对 iPhone 到同账号服务的路径，停止更新并移除此手表摘要也有明确操作。

review 确认一项 P2：旧共享确认可能在账号切换后作用于新空间。已在确认时捕获原 storageURL，并由模型的 expectedStorageURL guard 拒绝失效动作；补充 AsyncStream 控制实际异步顺序的回归。该项 P2 复核关闭，该轮 review 未留下确定 P1／P2。相应完整测试通过 35 项 XCTest、89 项 Swift Testing（合计 124 项 Swift）与 8 项 Node 测试，0 失败、0 跳过；三目标均 `BUILD SUCCEEDED`，专用模拟器两端构建安装通过。随后实际配对验收发现 W5，旧结果仅作为修复前基线，不表示本轮已收尾。

## W5 配对前台确认修复与实测

修复前 Watch 的虚构验收记录未到 Phone；当时 Phone WCSession 为 paired YES、appInstalled NO、reachable NO，Watch 为 companionInstalled YES、reachable YES。该组状态只描述当时观测，不将 isWatchAppInstalled 泛化为 Simulator 恒为 false。后续 Phone 新建习惯已实际传到 Watch，Phone → Watch 主动前台发送不再列为待核。

队首较早的空 snapshot 已进入 Phone 的 receivedIDs 并落盘；Phone 单独调用 transferUserInfo 返回 ACK 失败，FIFO 因此未放行后续 1 条记录。这不是完全未接收或 namespace 拒收。Apple 文档明确 Simulator 不支持该 API，详见[验证报告](../verification/report.md)。

platform agent 已实现前台 sendMessageData.replyHandler 在应用快照与 receivedIDs 落盘后直接返回既有 ACK、namespace／安装就绪后的重试及中文状态。Simulator 不调用 transferUserInfo，生产后台保留，安装与账号 guard 均未绕过；wire v2 与既有队列 schema 保持不变。

review 发现的 2 条 P2——namespace 发布真实错误的显示顺序、生产后台迟到错误覆盖状态——均已修复，复核全部关闭。W5 工程阶段完整 `test-local.sh` 通过 130 项 Swift（41 XCTest＋89 Swift Testing）及 8 项 Node，0 失败、0 跳过，较 124 项基线新增 6 项 XCTest；日志为 `watch-foreground-tests.log`，该阶段 SDK／generic 也均通过。后续 W6 回调修复的最终批次另行记录，不能复用这批旧结果宣称最后源码已全量通过。

最终前台实测：Phone 收到 Watch 原有 1 条虚构记录，两端 metadata pending 均为 0。Phone 新建“验收习惯·起身走走”传到 Watch，Watch 完成后 Phone 为 1／1，撤销后 Phone 为 0／1。双向前台、产品 ACK 和 FIFO 恢复通过，Watch 重启后原记录保留，Phone 主屏及 Watch 启动器品牌图标已看到。该结论不扩大到真机后台传输。

## W6 SDK 回调并发断言修复

20:38 实测前台 reply 时 Watch 出现一次 EXC_BREAKPOINT／SIGTRAP：后台 WCSession 调用了隐式 MainActor 的 closure，进入 Task 前即触发断言。root 将三个 SDK 即时 reply／error 外层 closure 显式标记 `@Sendable`，保留内部 Task 的 MainActor 隔离；DeviceDebug 双端 SDK 重建重装通过。随后观察只有一个 Watch 进程，除 20:38 旧报告外未见新 crash，双向前台交互及队列清空已实测。

最后修复的完整回归已通过：`watch-final-tests.log` 为 41 XCTest＋89 Swift Testing，共 130 Swift，另有 8 Node；`final-MyEnergyWatch.log`、`final-MyEnergyiOS.log`、`final-MyEnergyMac.log` 均 `BUILD SUCCEEDED`。三个 `@Sendable` 修复经独立 review 确认合理且无同类遗漏。HealthKit SDK 的 NS_SWIFT_SENDABLE 静态核对通过，HealthDataClient 未改动。Watch 身体参考入口已进入，点击连接前第三次锁屏阻止操作，未请求授权、未查询；睡眠详情、新主题选择和完整示例隔离仍未验收。

真实健康权限、传感器样本、后台配对传输及真机功耗仍未验证。模拟器和注入客户端的证据不能替代真机结果，也未改动用户既有 Mac 数据。

## 应用图标

先前 Device Hub 的系统配对提示未作为应用故障或同步通过结论；后续按原范围继续专用模拟器，双向前台同步与重启保留已实测。

用户随后要求提供图标，已生成并保存 1024 × 1024 无透明 PNG 主图，接入 iOS／iPadOS、macOS 和 watchOS AppIcon。三端资源编译及专用模拟器重装通过，专用 iPhone 主屏和 Watch 启动器已实际看到品牌图标，通知与设置等其他入口继续待验收。[图标说明](../design/app-icon.md)记录主图、各端尺寸及完整提示词。

## 服务端 Docker 部署

2026-11-20，按用户要求增加同步服务的 Docker 快速部署入口，归入 M3。运行依赖为 Docker Engine 和 Compose，容器自带 Node.js 24，SQLite 使用独立数据卷。实际演练在本机隔离项目完成。目标环境的 HTTPS、真实 Apple 登录和备份恢复仍待验收。[启动说明](../../README.md#用-docker-启动同步服务) · [验证报告](../verification/report.md#服务端-docker-部署验证) · [风险 R16](risk-register.md)

| 工作包 | 负责人 | 输入与依赖 | 产出与实际状态 | 验证与余项 |
| --- | --- | --- | --- | --- |
| D1 容器部署 | root | 现有 Node.js 和 SQLite 服务 | Dockerfile、Compose 和构建上下文白名单，已交付 | 新卷首次启动、非 root、`/healthz`、宿主机端口映射、开发入口关闭及重建后读回均通过 |
| D2 启停与配置说明 | 文档 agent | D1 的端口、数据卷和认证约定 | README 与环境变量示例，已交付 | 默认命令实跑，示例配置可解析；远程 HTTPS 需要目标环境 |
| D3 集成验收 | root、独立复核 agent | D1、D2、本机 Docker | 聚焦回归、独立复核及验收记录，已完成 | 8 项服务测试通过；真实 Apple 身份依赖开发者团队和 App ID 配置，备份恢复依赖目标环境 |
