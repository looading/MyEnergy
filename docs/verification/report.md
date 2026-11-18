# 首版验证报告

日期：2026-11-18。范围为本地 MVP、睡眠观测、二维状态主题、Watch 本机功能补齐、通用目标编译和开发身份加密同步。真实四端账号互联和发布尚未验收。当前最新完整本地测试、review 修复后的最终三目标构建与配对模拟器安装均通过；MyEnergy 原生 UI 尚未验收，当前阻塞为 Mac 锁屏，等待用户手动解锁。

## 已通过检查

| 检查 | 命令与条件 | 结果 |
| --- | --- | --- |
| Swift | `./scripts/test-local.sh` 自动创建独立本机服务 | 最新 124 项通过：35 XCTest、89 Swift Testing；0 失败、0 跳过，双客户端及账号生命周期全部实际执行 |
| 服务 | `node --test server/test/*.test.mjs` | 8 项通过，0 失败 |
| MyEnergyUI | `swift build --package-path Packages/MyEnergyKit --target MyEnergyUI`；本轮完整 Swift 回归 | 二维主题阶段独立构建通过；Watch 补齐后的共享包随最新回归通过 |
| Mac | `./scripts/build.sh MyEnergyMac` | 跨账号旧确认修复后的最终通用目标 `BUILD SUCCEEDED`；本轮未改动已有 Mac 数据，历史实际启动证据保留 |
| iPhone／iPad | `./scripts/build.sh MyEnergyiOS` | 跨账号旧确认修复后的最终通用模拟器目标 `BUILD SUCCEEDED`，包含 Watch companion |
| Watch | `./scripts/build.sh MyEnergyWatch` | 跨账号旧确认修复后的最终独立 scheme 通用目标 `BUILD SUCCEEDED` |
| 配置 | `plutil -lint Configuration/*.plist Configuration/*.entitlements`、`zsh -n scripts/*.sh` | 历史静态检查通过；新增模拟器准备路径在本轮 `--prepare-only` 实际执行成功 |
| 模拟器环境 | Xcode 官方 runtime 安装及专用设备准备 | iOS 27.2、watchOS 27.2 runtime 已可用；专用 iPhone 18 Pro／Apple Watch Series 12（42 mm）已启动并配对 |
| 模拟器构建与安装 | `./scripts/run-watch.sh --prepare-only` | DeviceDebug ad-hoc iPhone／Watch 构建通过，两端应用安装成功；从实际 arm64 可执行文件断言两端内嵌 `com.apple.developer.healthkit=true` |
| 独立复核 | 跨账号旧确认修复及直接依赖 | P2 已复核关闭，当前未解决的确定 P1／P2 为 0；不等于应用 UI 或真机验收通过 |

主题阶段日志为 theme-tests.log；早期 swift-tests.log 单独保留为历史验证记录。服务与早期构建日志包括 server-tests.log 和 build-mac／build-ios／build-watch.log。本轮修复后最终日志为 `build-MyEnergyWatch-completion.log`、`build-MyEnergyiOS-completion.log`、`build-MyEnergyMac-completion.log`，三项均 `BUILD SUCCEEDED`；专用配对模拟器准备日志为 `watch-simulator-prepare.log`，构建和两端安装成功。日志均未纳入 Git。AppIntents 元数据提示表示未依赖该框架而跳过提取，不影响构建。

## Mac 实际交互

以原生可访问性树及截图观察验证：首次空态；新增精力 51、心情“愉快”和备注“功能验收样例：记录、趋势与重启保留。”；详情与输入一致；新建“起身走一走”并打卡后显示 1／1；进入独立示例有持续标识，健康与账号操作禁用；趋势缺失日留白；退出示例后恢复原来的 1 条记录与习惯；退出进程重新启动后数据仍保留。

应用保留这条明确标记的验收样例。未读取真实健康数据、未进行真实 Apple 登录，也没有通过界面删除用户记录。

## 回归和 review

核心覆盖非法输入及解码绕过、schema、坏文件保留、DST／时区、三方合并、删除防复活和 HRV 充分性／过期。UI 状态测试覆盖示例不落盘、空间切换失败保留当前记录、过期编辑器不复活删除内容，以及清除后的删除标记。

服务覆盖账户隔离、CAS 并发、幂等、删除撤销会话、nonce 一次性、RSA／issuer／audience／时间验证和开发入口隔离。密文测试覆盖账号 AAD、错密钥、篡改、恢复密钥与 HTTPS 边界。双客户端实际经过上传、接收、连续编辑、冲突选择、离线删除防复活，以及显式健康摘要的密文传输和撤销后离线副本防复活。

Watch 回归覆盖异步 namespace 串行／合并、旧账号队列隔离、ACK 前持久化、因果基线和离线 40→50→60、60 KiB 总大小。独立 review 的确定问题已修复：共同基线在持久化后推进；存储空间切换即时更新 namespace 并在接收端核对；正确密钥可由界面验证替换；空账号删除不会因目录不存在而残留会话。

## 未验证及发布前事项

| 项目 | 缺口 |
| --- | --- |
| iPhone／iPad／Watch UI 实际运行 | runtime、配对启动及两端安装已通过。CUA 仅观察 Device Hub 的专用 Watch 表盘和配对指示，尚未打开 MyEnergy 时 Mac 锁屏；等待用户手动解锁，所有应用 UI 与辅助功能用例保持未验收，iPad 专项仍未运行 |
| Apple Health 真数据 | 需要签名、授权及有历史样本的设备 |
| Watch 后台互联 | 需要配对 iPhone／Watch，验证断连、后台、切账号和重启 |
| 真实 Apple 身份 | 需要开发者团队、App ID 分组、签名与 audience；当前为受控签名夹具及开发身份 |
| 生产密钥和撤销 | 恢复密钥导入已实现；轮换、丢失设备、撤销与远端本地清除仍需专项验收 |
| 健康摘要真机验证 | 独立授权、默认关闭、摘要加密同步、来源显示与撤销已实现并用注入样本回归；真实设备及真实健康数据仍待验证 |
| 大量 Watch 历史 | 完整快照＋因果基线共用 60 KiB 上限，需增量方案 |
| 生产交付 | 未部署生产服务，未完成商店条目、隐私清单、发布签名、真机功耗和 Sponsor 最终验收 |

以上未计为通过，不宣称 M2～M4 整体完成。

## 健康摘要补充

新增 5 项 Core 和 6 项 UI 状态测试，并增加 1 项实际双客户端摘要传输回归。验证读取健康不等于开启分享；匿名／示例禁止分享；开启后使用稳定代际 ID，停用使用删除标记；账号切换停止分享和在途读取；不支持 HealthKit 的设备可显示接收摘要但不查询健康。健康摘要专项只读 review 未发现确定的 P1／P2 问题。所有样本均为明确测试夹具，不是真实测量。

## 本地版本与开发账号收尾

用户明确选择本轮只完成本地版本与开发账号联调。`./scripts/test-local.sh` 已实际执行：20 项 XCTest、48 项 Swift Testing，共 68 项 Swift 测试，加 8 项服务端测试，全部通过、无跳过。服务使用临时数据库与随机端口，结束后自动清理，不修改 8787 演示服务。

新增 8 项账号 controller 真实本机服务回归：登录／建密钥／同步／恢复／退出，两个账号及匿名空间隔离，竞争建密钥后的正确恢复，空账号删除，服务离线时数据保留，激活失败回滚，退出切换失败回滚，以及确定性暂停下的恢复 endpoint 锁定。安全存储在这些用例中为隔离的内存注入；OS Keychain 单独以 `./scripts/check-local-keychain.sh` 验证跨进程写／读／删。

实际 Mac 界面已登录 local-acceptance 开发账号、创建系统钥匙串中的恢复密钥、保存“本地开发账号联调验收样例。”记录。本机服务实际存在版本 1 的密文 vault；原匿名空间的记录没有自动导入。没有显示、复制或记录原恢复密钥，也没有进行真实 Apple 登录。

定位并修复原未签名 Mac Debug 对数据保护钥匙串写入的 -34018（errSecMissingEntitlement）。对照仅改变钥匙串实现，原路径失败而系统登录钥匙串成功；修复限定 macOS Debug，使用独立 service 名称。正式版、iOS／watchOS 不作同类降级。另修复恢复过程可改 endpoint 的竞态，并用受控挂起加独立远端客户端回归，review 已确认修复。

一项早期恢复测试错误地让两个 controller 共用同一设备的基线文件；已改用独立设备目录和基线重现远端更新，最终完整回归通过。未用删除断言或放宽结果来绕过失败。

## 睡眠观测增量

用户要求将睡眠独立纳入观测。本轮实际执行 `./scripts/test-local.sh`：35 项 XCTest、54 项 Swift Testing，合计 89 项 Swift 测试，加 8 项 Node 服务测试，全部通过、没有跳过。相较上轮新增 21 项 Swift 回归。Mac 和 iPhone／iPad 通用目标（含 Watch companion）均构建通过。

新增覆盖：SleepRecord／SleepNight 输入与解码校验、旧 schema 1 兼容、睡眠三方合并与 tombstone、有效 asleep 区间并集、awake／inBed 排除、未结束与无效区间、跨午夜、春秋 DST、主要片段与午睡、来源优先级、缺失日、手动增改删与重启、示例隔离、整空间删除、最新摘要单独共享，以及真实开发服务的睡眠记录／摘要密文传输及离线删除防复活。

独立 review 发现查看设备与来源时区混用会让刚结束的睡眠从统计中消失。已将范围与分组统一为查看设备时区，保留来源时区显示边界，并加入上海记录在洛杉矶午夜前查看的具体回归。相关文字也已调整。

Mac 实际操作：新增“睡眠”侧栏与今日卡片；空态无伪造数值；补记默认昨夜 23:00 至今晨 07:00，明确为自述时段估算；输入“睡眠功能验收样例，非真实睡眠测量。”，取消后重开仍保留草稿；保存后显示 8.0 小时和 1／7 有观测日；切换 30 天显示 1／30，均值仍为 8.0 小时，其余日为空；退出并重新启动后今日卡片仍显示同一记录。没有读取真实健康数据或进行真实 Apple 登录。

原始睡眠历史只存在 HealthReport 临时数据中；健康摘要仍须明确共享，且只写入选定最新 SleepNight。手动补记作为用户填写的应用记录进入当前账号的加密同步。全部代码沿用原生与本地开发阶段，不宣称真机睡眠检测、分期或睡眠质量评分通过。

## 二维状态主题增量

本轮完整 `./scripts/test-local.sh` 已通过：35 项 XCTest、71 项 Swift Testing，合计 106 项 Swift 测试，另有 8 项 Node 服务测试。相较睡眠观测阶段新增 17 项 Swift 回归。`swift build --package-path Packages/MyEnergyKit --target MyEnergyUI` 和最新 Mac／iOS 通用目标构建均成功，iOS 构建包含 Watch companion。独立 review 检查本次主题变更及直接依赖，未确认 P1／P2 问题。

主题将心情 valence（-1～1）与精力 vitality（0～1）分别解析和连续插值；心情决定色彩倾向，精力改变鲜明程度。未知心情不显示积极百分比，未知精力采用中等鲜明度并保留未知标志。最近 24 小时内最新有效主观记录驱动主题，未来、过期、无记录和非法输入采用对应降级。双轴约 1.6 秒缓动过渡；开启减少动态效果时关闭动画。逐窗口 token 管理临时预览，取消后恢复，预览不落盘。设置中的四个样例只展示配色。

自动回归覆盖两维独立映射、不同精力下的未知心情、低精力好心情与高精力低落、时间边界及稳定选择、连续中间色，以及预览覆盖、token／状态实例隔离、取消恢复和直接调用 `clear()` 后清空全部预览。Host 在 `storageURL`／`isDemo` 变化时清空预览的接入路径经代码 review 检查，本次退出示例也有原生交互证据；自动测试没有直接触发这些 SwiftUI `onChange` hook。

对比度数值测试在心情和精力各取 21 点，分别检查浅色／深色、普通／增强对比度下声明的语义颜色组合：`ink`、`secondary` 和 `accent` 对 `canvas`／`surface`／`accentSoft`，以及 `onAccent` 对 `accent`。正文阈值普通模式为 4.5:1、增强模式为 7:1；强调色阈值分别为 3:1 和 4.5:1。这些采样不等于完整屏幕及所有控件背景通过可读性验收，具体呈现仍需设备 UI 验证。颜色值属于产品设计，测试通过也不代表已验证颜色的心理效果。

Mac 原生界面在独立示例空间中已实际观察以下组合：低落＋精力 0 呈灰紫；低落＋精力 100 呈莓紫；无心情＋精力 100 保持中性鼠尾草；高兴＋精力 100 呈金杏；高兴＋精力 0 呈柔和蓝绿。取消编辑后回到示例原有 12 条记录。将一条明确标记的验收示例保存到示例空间后，首页显示积极方向、较柔和，记录数由 12 变为 13；切换睡眠页再返回仍保留该状态。退出示例后恢复原有 4 条本机记录，临时示例未进入本人空间。以上仅记录聚合数量，不记录本人记录的时间、分值或心情。

浅色／深色和增强对比度的可读性证据限于上述语义颜色组合的数值采样；减少动态效果的关闭动画路径来自代码 review。本轮未在原生系统设置中切换实测浅色、增强对比度或减少动态效果，因此这些项目未记为原生系统交互通过。完整屏幕、控件背景组合及系统辅助设置仍待设备 UI 验收。

二维主题阶段尚无可用 Simulator runtime，原生交互观察仅来自 Mac；当前 iOS／watchOS runtime 已安装，这项旧环境条件已解除。真实 Apple 登录、HealthKit 授权／样本及配对 Watch 真机联通均未测试；通用目标编译不替代这些证据。

## Watch 本机功能补齐

按[Watch 设计](../design/watch-completion.md)及[实施计划](../implementation/2026-11-18-watch-plan.md)交付：首页保留快记、最近自评和习惯，身体参考、睡眠详情、设备与设置分别展开。健康页只在用户点击时请求 HRV SDNN、静息心率和睡眠只读授权，区分请求中、读取中、无样本、失败、历史不足、过期和可用个人基线；列出 ms、采样时间、读取时间和来源。睡眠显示最近主要观测及近 7 天逐日列表，保留起止、来源和时区；缺失不补零，手动补记继续在 iPhone 完成。

最新完整 `./scripts/test-local.sh` 已实际通过 35 项 XCTest、89 项 Swift Testing，共 124 项 Swift 测试，另有 8 项 Node 服务测试，0 失败、0 跳过；相较二维主题阶段新增 18 项 Swift 用例。健康生命周期以注入客户端测试，不调用真实 HealthKit，不创建合成健康样本。

新增回归覆盖：未支持／未连接／示例不自动读取、授权失败显式重试、重复连接不重复请求、查询失败后保留连接、失败保留旧报告、手动刷新跳过节流、前台五分钟按最近尝试节流、空结果不推断拒绝、停止读取后晚到授权或报告失效、停止后重连的旧完成不能结束新操作，以及切空间／示例使在途结果失效。展示状态按传入当前时刻重新判断 HRV 24 小时过期。明确的 companion namespace 区分匿名与账号，匿名配对空间无法开启摘要共享；原始健康历史仍留本机，手表摘要经配对 iPhone 到同账号服务。

独立 review 确认一项 P2：用户在旧账号打开共享确认后切换空间，旧确认可能作用于新账号。修复在 UI 打开确认时捕获原 storageURL，模型以 expectedStorageURL 再次校验；新增回归使用 AsyncStream 暂停实际异步操作，切换账号后恢复旧动作，验证旧确认不能启用或移除新空间摘要。上述完整测试结果包含此修复，P2 已经复核关闭，当前未解决的确定 P1／P2 为 0。修复后的 `MyEnergyWatch`、`MyEnergyiOS`（含 Watch）与 `MyEnergyMac` 最终通用目标构建全部 `BUILD SUCCEEDED`。

Xcode 官方 iOS 27.2 和 watchOS 27.2 runtime 已安装可用，专用 iPhone 18 Pro 与 Apple Watch Series 12（42 mm）模拟器已启动并配对。`./scripts/run-watch.sh --prepare-only` 已成功：DeviceDebug ad-hoc iPhone／Watch 构建通过，两端应用安装成功。脚本会复用并激活自身专用 pair；默认启动路径在启动前结束已有应用进程，确保使用最新构建。

本地模拟器签名的普通 codesign entitlement 输出为空属于 Simulator 机制，未据此改动签名。已用 `otool` 从两端实际 arm64 主可执行文件的 `__TEXT,__entitlements` 段解析 plist，并断言 `com.apple.developer.healthkit` 为 true。此检查证明本次模拟器产物携带声明，不能证明真实健康授权或查询成功。

Xcode 27.2 的模拟器前端为 Device Hub，可从 Xcode → Open Developer Tool 打开。脚本优先打开 Device Hub，旧环境回退 Simulator。CUA 已实际观察专用 Watch 表盘与配对指示；尚未打开 MyEnergy 时 Mac 随即锁屏。CUA 无法自动解锁，已请用户手动解锁并等待。本轮阻塞来自锁屏，runtime、配对启动和应用安装条件均已满足；表盘可见不算 MyEnergy UI 通过。

待补应用 UI 证据：打开 MyEnergy、快记本机保存及重启保留、独立心情与主题预览、习惯完成／撤销、睡眠缺失与来源、身体入口与无样本状态、匿名共享限制、设置与示例隔离、窄屏及动态字体。当前以上用例全部保持未验收。已有 Mac 本机数据本轮不作改动；不得通过导入或删除本人记录来准备界面。

模拟器不能提供真实传感器或用户日常健康历史，也不能替代真实系统授权、后台配对送达、真机断连恢复和功耗验收。本轮没有新增独立 Watch 云登录、后台采样、widget、睡眠质量或压力分数；这些平台和范围边界继续保留。
