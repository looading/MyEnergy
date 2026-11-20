# Local AI Implementation Plan

> **For agentic workers:** 按下列独占文件分工实施；root 负责集成与全部串行构建测试。范围由用户的本地 AI、iPhone 优先／Mac 兜底和每日复盘选择确认。

**Goal:** 提供可本地生成的每日复盘和习惯建议，显示真实执行信息并按手机、电脑顺序路由。

**Architecture:** Core 负责有限事实、请求／结果和执行策略；Platform 负责注册及账号授权的局域网通道；独立模型 package 提供 FoundationModels 与 MLX/Qwen，原生入口注入 UI。

**Tech Stack:** Swift 6、SwiftUI、Network/TLS PSK、FoundationModels（按 availability）、MLX Swift 固定版本与 Qwen3-1.7B 4-bit 固定 revision。

## 共享约束

- 不把备注、习惯原名、原始 HealthKit 样本自动放进提示词；缺失不补零。
- 只做日常复盘与小习惯建议，不输出医疗判断。
- 模型不可用明确说明；不得把固定文字或 mock 冒充真实 AI。
- 事实以汇总为主，最多六项：全日精力统计、最近三条自评、完整习惯完成汇总、主要手动睡眠估算；没有匿名习惯明细，内部计数不进提示词。
- MLX 按概述→单条观察→建议详情→建议标题的顺序生成；所有正文由真实模型生成，应用构造结构、数量及指定事实关联。每段新 KV、复用权重，按执行顺序 cap 为 160／96／160／32 token，总计 448。达到该段 cap 仍未 EOS 时，明确拒绝截断结果。
- 按执行顺序的生成目标为 60／40／60／12 字，硬长度上限为 120／80／120／24 字，仍低于 Core 原限。建议标题看到同一条事实及已验证详情草稿后概括名称，草稿不能成为新增事实；指定关联不证明语义正确。
- 保留 Core 严格校验；无效文本明确失败，不做静默 JSON 修复、猜测 ID 或自动重试。
- 用户主动下载模型；下载源、大小、hash、许可及原子启用有记录。
- 跨设备默认关闭，使用当前账号密钥派生的独立 TLS PSK；匿名仅本机。
- 所有新 SDK completion 显式考虑 Sendable／actor 边界。
- 不改用户现有 Xcode 团队和 Run 设置，不直接 xcodegen 覆盖。

## AI-C：契约与路由

负责人 Core agent，独占新增 `MyEnergyCore/LocalAI*.swift` 及对应测试。定义 LocalAIDeviceRole、LocalAIExecutor、LocalAIAvailability、LocalAIError、DailyReflectionInput／Request／Draft／Result、LocalAIRunner 和模型资产管理协议；实现事实构建、输入 hash、输出验证及 iPhone→Mac、系统→下载模型顺序。仅未开始的 unavailable 允许自动回退，取消、无效输出和不确定远端执行不能自动改派。先冻结契约，再由依赖方编写实现。

- [x] 契约及确定事实／路由完成，聚焦回归通过。

## AI-M：模型与资产

负责人 Provider agent，独占新 `Packages/MyEnergyLocalAI` package。消费 Core 契约，提供系统模型与 MLX 模型，下载／校验固定资产，确保非思考模板、token 上限和取消。注册入口为 `NativeLocalAI.install()`，由 Apps 主入口调用；不得自行构建、下载或运行模型，交 root 调度。

- [x] provider、资产与许可证来源完成，真实 Mac 推理有证据；正式分发许可清单仍属发布阶段。

## AI-U：复盘界面

负责人 UI agent，独占新增 LocalAIView／Controller、TodayView 和 EnergySettingsView 入口。消费平台注册和网络 hub，显示模型状态、下载、事实、实际设备、结果、失败和取消；监听 snapshot／storageURL／isDemo 使旧任务失效。结果仅内存，不自动改习惯或保存云端。

- [x] 原生入口、状态与任务生命周期完成，Mac 界面及模拟器／设备 SDK 构建验证。

## AI-N：网络与集成

负责人 root，独占新增 Platform LocalAIRegistry／LocalAINetwork 文件、AccountController 的独立身份派生、Apps 入口、Info／entitlement、工程 package/product 引用和验证脚本。实现 TLS PSK 的认证发现、能力与有界复盘请求、取消／超时／代际检查；停接收或切账号关闭连接。保留未提交用户设置，只做必要的工程补丁。

- [x] 网络与单设备注入完成，认证／错误密钥／取消／路由边界验证；真实 LAN 与物理设备另列。

## AI-V：集成与收尾

root 串行执行轻量包回归、独立模型 package 及 App Xcode 构建、下载并验证固定模型、真实 Mac 虚构事实生成、离线生成验证和独立 review。记录系统模型实际 unavailable 与所有未验证真机项。更新 PMP 状态与风险；Watch 剩余 UI 继续保留，不把本增量当作已完成其现场验收。

- [x] 本地测试、真实生成、独立 review 和文档完成；本轮为本地开发交付，物理设备与发布不在此勾选范围。

## 2026-11-20 执行状态与技术调整

下表是当前阶段证据，最终勾选由 root 完成。已通过的回归或构建不代表正在变更的四段生成路径已经通过最终质量和 UI 验收。

| 工作包 | 已有产出与证据 | 当前余项 |
| --- | --- | --- |
| AI-C | 契约、输入 digest、确定性事实、严格输出校验及 iPhone→Mac 路由已实现；事实缩为最多六项，未纳入备注、习惯原名或原始健康样本。当前 Kit／服务回归为 157 Swift、8 Node 通过 | 随四段生成接口完成最终集成检查；结构及事实 ID 检查不代替语义审阅 |
| AI-M | 系统模型返回真实 deviceNotEligible；固定 Qwen3-1.7B-4bit revision `3b1b1768f8f8cf8351c712464f906e86c2b8269e` 的 984,025,460 bytes 资产下载／校验 ready；Native 14 个测试函数、23 个用例及最新 manifest 检查通过 | 正在实现四段真实文本生成；完整固定场景、取消／清理、最终中文质量和资源指标待 root 复验 |
| AI-U | 原生入口、模型状态、下载、事实、真实执行信息及内存结果已接入；已有 Mac／iOS Simulator 构建成功 | 最终四段结果页面操作、取消与失效的 UI 验收仍在进行；不能把自动回归当作操作验收 |
| AI-N | TLS 1.2 PSK 六项 loopback 正负例通过；使用合成模型、临时回环端口，无 Bonjour 广播；Mac／iOS Simulator／Watch 最近一轮构建通过 | 该 PSK 通道无前向保密；iPhone 真机推理、真实同账号设备及 Bonjour／局域网权限现场未验 |
| AI-V | 保留独立复核、资产、失败原始输出和阶段测试证据 | 四段方案后的真实生成质量、离线验证、最终构建、UI、独立复核及收尾记录尚未完成 |

0.6B 在三次固定场景中仅一次通过严格结构／引用校验，故不沿用简单场景成功作为完整质量结论。1.7B 下载并成功构建后，原始输出在 29、153 token 时即到 EOS，仍未符合 JSON；没有触及 512 token 上限。四段方案针对这组实际格式失败调整输出职责，保留同一份事实与 Core 校验，不通过重试或修补把失败改写成成功。

四段初版的 full-day 曾生成正确的 72 字概述，但被新增的 60 字样式校验拒绝。此次把生成目标和硬上限分开，并将建议详情移至标题之前：先验证详情，再让标题从同一事实和已验证草稿中概括名称。Core 原有医学表达、事实引用和结构校验不放宽。此前 18 个 Native 测试函数通过只是这一轮调整前的阶段基线，限长、顺序与 EOS 检查更新后的最终测试和真实质量仍须由 root 重新记录。

当前 Watch 续验已点击健康连接并进入无样本说明；该页面不能证明各项读取获准。随后 Device Hub 的原生触控、滚动和拖动持续返回 `noWindowsAvailable`，画面与 AX 仍可读，All Devices 与 Info 偏好已还原。睡眠详情、停止连接、主题预览和完整示例隔离仍待现场操作；此前锁屏记录不再作为当前阻塞。此项不扩展为 Watch AI 入口，也不替代原 Watch 工作包验收。

详细生成与最终构建证据由 root 维护[本地 AI 验证记录](../verification/local-ai.md)。本轮不新增费用、生产部署或商店发布。

## 本地验收收尾

最终基线为 157 Swift＋8 Node、模型包 21 个测试函数通过；Mac、iOS Simulator、iOS 设备 SDK、Watch Simulator 四项构建均成功。三个最终固定断网场景完成真实四段生成，生成约 0.93～1.27 秒，含加载约 3.18～3.41 秒；MLX 峰值约 1.38 GiB，不能推算手机表现。完整原始计数见[验证记录](../verification/local-ai.md)。

Mac 示例页面已实际生成与重新生成，显示实际模型及依据；关闭重开无旧结果、退出示例恢复本人空间，均已操作。尝试 UI 取消时生成已结束，不能算真实 GPU 中断已验收；确定异步顺序回归和加密 loopback 的取消证明仍单独记录。iPhone 真机／真实同账号 Bonjour、本地网络权限、最低系统、内存和功耗，以及 Watch 原有剩余现场交互继续为开放项。

Core、Native、UI、网络与工程按文件所有权协作，独立 reviewer 复核本次差异及必要直接依赖；已确认 P2 均有修补和回归，未留下确定 P1／P2。模型来源关联不是语义正确证明，建议价值与真实设备条件留给后续产品验收，不用勾选或固定样例代替。
