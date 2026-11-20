# 本地 AI 验证记录

2026-11-20。用户要求 iPhone 优先、Mac 其次的本地推理，并选择先交付每日复盘与习惯建议。本轮只使用虚构记录，不读取真实健康样本、不改变物理设备开发者模式、不部署推理服务。设计见[本地 AI 方案](../design/local-ai-mvp.md)，工作包见[实施计划](../implementation/2026-11-20-local-ai-plan.md)。

## 当前运行证据

| 验证 | 结果与条件 |
| --- | --- |
| Core、Platform、UI 和服务回归 | `./scripts/test-local.sh` 通过 157 项 Swift（41 XCTest、116 Swift Testing）及 8 项 Node 测试，0 失败、0 跳过；`local-ai-kit-tests.log` |
| 原生模型包 | `MyEnergyLocalAI-Package` 聚合 scheme 通过 21 个测试函数，含资产、执行锁和分段生成的参数化用例；`local-ai-native-tests.log` |
| 真实加密传输 | 六项 TLS-PSK loopback 通过：匹配身份生成、错误 key／namespace 拒绝、客户端取消、停止接收取消、忙拒绝、无效事实引用拒绝。临时回环端口和合成模型，不广播 Bonjour，不等同真机互联 |
| 固定资产 | Qwen3-1.7B-4bit revision `3b1b1768f8f8cf8351c712464f906e86c2b8269e`，11 个必须文件合计 984,025,460 bytes，实际下载逐项大小／SHA-256 校验后 ready，包含源模型 LICENSE；`local-ai-model-download.log` |
| 真正离线生成 | 探针进程使用 `sandbox-exec` 的 `(deny network*)`；最终 basic、full-day、full-day 三次固定检查均完成真实四段生成，通过正文、EOS、结构、来源、请求 ID／digest 校验；没有生产自动重试或 mock 代替 |
| 非思考模式 | 四段实际 chat template 均传 `enable_thinking: false`，检查 system／user 正文保留及 assistant 空 think 前缀；不是只隐藏思考文本 |
| 系统模型 | 本机 `SystemLanguageModel.default.availability` 实际为 `unavailable(.deviceNotEligible)`，未称系统模型生成通过 |
| iPhone 设备 SDK | `generic/platform=iOS`、Debug、`CODE_SIGNING_ALLOWED=NO` 构建成功，包含 companion；`local-ai-ios-device-build.log`。这不是物理 iPhone 安装／推理 |

最终生成日志为 `local-ai-offline-generation.log`、`local-ai-full-day-generation.log`、`local-ai-full-day-repeat.log`。输入输出均标为 synthetic-only；CLI 不打开 AppModel、账号、Keychain、HealthKit 或同步记录。

## 本机资源与内容核对

本机为 Apple M5 Pro、macOS 26.6.2，Xcode／SDK 27.2。以下都是独立探针进程的冷启动检查；不能推算手机表现。

| 场景 | 聚合输入／正文输出 token | 四段生成与验证 | 包含加载的耗时 | MLX peak active memory |
| --- | --- | --- | --- | --- |
| basic：两项事实，缺睡眠／心情 | 636／48 | 0.93 秒 | 3.18 秒 | 1,421,596,924 bytes |
| full-day：14 条记录、7 个习惯、手动睡眠，整理为六项事实 | 848／69 | 1.27 秒 | 3.41 秒 | 1,476,057,928 bytes |
| 同一 full-day 再执行 | 848／69 | 1.24 秒 | 3.26 秒 | 1,476,057,928 bytes |

peak 是 MLX 统计的累计峰值，约 1.38 GiB，**不是整个进程 RSS**。输入指标为四段之和；2,048 是每阶段输入上限。三次固定检查不能估计总体成功率；独立进程的采样初始状态也不是多用户随机质量样本。

人工核对最终 basic：概述保留两条主观精力与缺失信息，没有推断心情；观察引用 energy_summary；建议是回顾当天行动并调整下一步，标题对应内容。full-day：均值 59.5、范围 40～79、手动睡眠约 7 小时均有输入来源；未再推断 14:00 之后的状态；建议围绕已完成习惯做可选反思，没有猜具体习惯内容。语言和建议仍偏通用，不能据此宣称健康分析准确或建议有效。

四段文本都由模型生成，应用只组装字段、数量并绑定生成前指定的事实来源。标题根据同一事实和已验证的建议草稿概括；草稿不作为新增事实。来源关联与结构校验不能证明全文语义正确。

## 质量检查推动的技术调整

初选 0.6B 的简单场景曾能生成，但旧 JSON 路径的固定三次检查只有一次通过，出现错误事实名和条目超限。1.7B 原始输出在 29／153 token 就到 EOS，仍缺字段或输出多个 JSON 片段，说明不是单纯 512 token 截断。两种旧路径的失败记录保留，不能挑一次通过掩盖其余失败，也不能据此宣称对全部小模型已完成比较。

MLX 改为概述、观察、建议详情、标题四次独立正文生成；每次新 KV、复用权重。每阶段使用实际模板、输入预算和取消检查，总输出 cap 160＋96＋160＋32＝448；未 EOS 即明确失败。写作目标与拒绝上限分开，72 字的正确概述不再因为 60 字目标而被误拒。可信任务置于资料之后；概述禁止预测、趋势和时段推断；采样 temperature 0.2、top-p 0.8。这些措施是当前验证配置，不是准确性保证。

阶段性检查还发现一次没有输入支持的“14:00 后精力提升”，以及建议只复述打卡数量。最终提示词针对这些实际内容收紧，保留严格 Core 校验；没有静默修补 JSON、替换模型生成的错误事实 ID、接受截断正文或自动重试到通过。

## 独立复核与修正

- Hub 在 await availability 后重新核对空闲与代际，再在同一 MainActor 段取得任务位。
- iPad 不注册本机 runner 或模型下载管理器；Watch 不链接 MLX，也没有本轮 AI 入口。
- Apple／MLX、UI／远端服务共用一个设备执行位；取消等待真实清理后释放。
- 下载只取消本窗口 Task，等待其结束，不误停其他窗口下载。
- 资产首次 ready 必须有实际 hash；每次检查当前文件类型，拒绝符号链接，不复用过期 URL 属性缓存。
- 取消只清本 worker 的 staging；最终目录替换在文件锁内，旧实例恢复不删除另一个实例的新提交。提交后取消保留完整资产；外部 probe 下载后可刷新识别。
- Apple external PSK 不支持 TLS 1.3。按 [Apple TN3213](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework#Plan-for-security) 和官方 P2P 示例采用 TLS 1.2 AES-GCM PSK；没有关闭认证。该 plain-PSK 方案无前向保密。

review 只覆盖本次 AI 变化与必要直接依赖，不是全仓安全审计。各确定 P2 均已修复并复核；模型语义和未验证设备风险继续开放。

## 应用、工程与环境

Metal shader 首次构建报缺组件，使用官方 `xcodebuild -downloadComponent MetalToolchain` 后成功；环境准备与代码错误分开记录。依赖完整锁文件同时保留在模型 package 和 Xcode workspace。正常 build 脚本不重新生成已有工程，保留用户签名／Run 设置；本轮提交不包含其原有私有设置。

最终四项 SDK 构建均成功，0 编译错误：Mac arm64、iOS Simulator 通用目标、iOS 设备通用目标、Watch Simulator 通用目标。对应日志为 local-ai-mac-build.log、local-ai-ios-build.log、local-ai-ios-device-build.log、local-ai-watch-build.log。Mac Debug 真实二进制的 FoundationModels 为 LC_LOAD_WEAK_DYLIB；这只核对链接方式，不等于最低系统运行验证。

最终 Mac 应用已实际操作：进入独立示例，看到真实 deviceNotEligible、Qwen 就绪、发送／承接均关闭且不可开启；生成和重新生成均出现 Mac／Qwen3 1.7B、输入日期、时间、概述、观察、行动及完整依据，排版已截图检查。关闭后重新打开为“尚未生成”，没有自动恢复旧正文；退出示例回到原记录空间，记录数保持原值。只使用示例推理，没有把本人记录送给模型，也没有自动改习惯。

实际 UI 再生成在读取取消按钮前已结束，未把这次尝试计为取消操作通过。取消、晚到结果、跨阶段停止和设备执行位清理已有确定异步顺序回归；不能把它们写成真实 GPU 中断的现场验收。Mac 当前停在本人空间，示例结果已按设计清除。

## 仍待验证

iPhone 真机速度、RSS／功耗／热状态、旧系统 Metal 兼容性、FoundationModels 实际生成、Bonjour 与本地网络授权、真实同账号 iPhone→Mac 互联仍需单列验收。跨设备要求有效账号会话和同一已解锁密钥，发送／承接默认关闭，双方保持复盘页打开，iPhone 仅前台承接。没有后台唤醒、云推理或 Watch AI 执行。

## 手表续验

原专用配对模拟器已实测双向前台记录／习惯与 ACK、重启保留。本轮点击 Watch 连接健康后进入已连接但无可读取样本说明，不能证明各项读取获准；未写合成 HealthKit 样本。

随后 Device Hub 画面和 AX 可读，但多次触控、滚动、拖动均报 noWindowsAvailable；未将其当作应用崩溃，已还原 All Devices 与 Info。睡眠详情、停止连接、主题预览和完整示例隔离仍待手表现场验收，注入测试不能替代操作。
