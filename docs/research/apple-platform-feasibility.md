# Apple 四端架构可行性

核查日期：2026-11-18。用途：支持 MyEnergy 首版范围与架构决策。本文只核查公开资料并提出工程建议，没有创建工程、配置账号或验证真机。工具链信息由主任务提供：Xcode 27.2、Swift 6.4.2，iOS、macOS、watchOS 27.2 SDK 已安装；SDK 齐全不代表相应 Simulator runtime、签名、服务权限和真机齐全。

主任务的环境检查目前只发现状态为 Unavailable 的 iOS 26.5 runtime，没有可用的模拟器。现阶段可尝试 generic destination 编译，模拟器启动与运行验收要等可用 runtime 安装完成；不能把编译成功写成运行通过。

## 推荐原生四端与独立同步服务

与 [首版范围与架构提案](../design/mvp-proposal.md) 的方案 A 对齐：SwiftUI 原生应用，共享业务模型，先完成本地可运行版本；随后接入 Apple Health 和 Watch；最后实现 Sign in with Apple、设备加入和独立端到端加密同步服务。HealthKit 原始样本默认留在 Apple Health，服务只保存用户选择同步的应用记录与必要摘要的密文。

这个建议满足 Mac、iPhone、iPad、Apple Watch 的产品方向，同时避开“把全部健康记录交给 CloudKit 自动同步”的审核假设。它仍需要账号配置、安全设计、真机和发布前审核，本文没有给出上架保证。

## iCloud 健康信息禁令仍然存在

**已核实。** 当前 App Review Guidelines 5.1.3(ii) 仍写明：“may not store personal health information in iCloud”。它没有公开列出“私有 CloudKit 数据库”“用户同意”或“应用先加密”的豁免。健康情境下的数据也有用途与披露限制。[Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#health-and-health-research)

**已核实。** 当前 Apple Developer Program License Agreement 3.3.3(D) 对敏感、可识别个人的健康信息及可能让 Apple 承担 business associate 身份的使用另有限制，明确点名 iCloud 和 CloudKit。3.3.3(H) 要求 HealthKit 信息用于健康或健身服务，向第三方披露需事先明确同意。[Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)

**需要审核确认。** 精力自评、情绪记录、备注、HRV 衍生分数是否在具体产品情境下属于相关条款中的个人健康信息，公开文件没有逐字段裁定。MyEnergy 将这些数据用于健康与恢复解释，工程上应先按敏感健康信息处理，不能通过改字段名、改成摘要或加密后就推定可以写入 CloudKit。协议适用范围及目标地区的法律义务应在正式发布前确认。

**没有获得豁免依据。** Apple 开发者论坛有一篇直接询问“加密、个人私有 CloudKit 是否例外”的帖子；Apple App Review 工作人员建议预约 App Review 咨询，没有在回复中给出允许结论。论坛回复不是正式豁免。[App Review 官方回复](https://developer.apple.com/forums/thread/838493)

Apple Health 自己的系统同步是另一条已公开支持的路径。Apple 说明健康信息可以通过 iCloud 同步，具备相应加密保护；在同一 iCloud 账号的设备间，删除也会传播。这不能解释成第三方应用可将其读取的数据重新上传至自己的 CloudKit 容器。[管理 Apple Health 数据](https://support.apple.com/en-us/108779)

## 各端能力不同

| 平台 | Apple 官方能力 | MyEnergy 应如何实现 |
| --- | --- | --- |
| iPhone | HealthKit 可读写，仍受设备限制与用户逐类型授权约束 | 主要健康接入端；请求最少数据类型；查询结果为空时保留未知状态 |
| iPad | iPadOS 17 起可以读写 HealthKit；更早系统即使能链接框架也没有数据访问能力 | 最低版本 17 可行；启动时仍检查 `isHealthDataAvailable()` |
| Mac | macOS 13 起存在 HealthKit 框架，官方明确不能读写数据，`isHealthDataAvailable()` 返回 `false` | 不申请本机健康数据读取；展示用户授权传来的摘要，或导入明确来源的文件 |
| Apple Watch | HealthKit 可用；WatchConnectivity 连接对应的 iPhone companion | 快记先落本地，后台传输给 iPhone；不能拿它连接 iPad 或 Mac |

平台结论以 API 的运行时说明为准。文档页列出 macOS 的 API availability，只表示符号可以存在，不代表该系统拥有可用的健康数据库。[HealthKit 运行时可用性](https://developer.apple.com/documentation/healthkit/hkhealthstore/ishealthdataavailable())、[HealthKit 配置流程](https://developer.apple.com/documentation/healthkit/setting-up-healthkit)、[WatchConnectivity 支持设备](https://developer.apple.com/documentation/watchconnectivity/wcsession/issupported())

HealthKit 按类型分别授权读写。出于隐私保护，应用不能据“没有读到样本”判断用户是否拒绝读取。设备锁定后，后台读取也可能暂时无法访问受保护数据。UI 与算法应区分“当前没有可用数据”和“已成功取得有效样本”。[保护 HealthKit 用户隐私](https://developer.apple.com/documentation/healthkit/protecting-user-privacy)

## 心情与精力要保留自己的记录模型

`HKStateOfMind` 可表达心境，公开 API 从 iOS／iPadOS 18、watchOS 11 开始可用。因此提案中的 iOS／iPadOS 17、watchOS 10 最低版本不能统一依赖它；如后续接入，需做版本判断并保留自己的记录模型。macOS 上出现该类型的符号同样不改变健康数据不可读取的限制。[HKStateOfMind 与 availability](https://developer.apple.com/documentation/healthkit/hkstateofmind)

HealthKit 使用已定义的数据类型标识保存样本。本文没有找到一个可直接对应 MyEnergy 任意“精力 0～100”或自定义恢复分数的标准类型，不应把这类分数写成消耗热量、心率或其他含义不同的样本。自定义分数及备注保存在应用自己的数据层。[保存 HealthKit 数据](https://developer.apple.com/documentation/healthkit/saving-data-to-healthkit)

`heartRateVariabilitySDNN` 的官方定义是正常心搏间隔的标准差，通常以毫秒计，Apple Watch 会自动记录样本。该 API 没有把 HRV 定义成情绪、主观精力或 MyEnergy 的恢复分数，也没有承诺固定频率连续采样。产品应显示来源、样本时间、有效历史长度和缺失状态，计算解释属于另外的算法规格。[HRV SDNN 类型](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn)

## 同步方案比较

以下为工程判断。方案字母与首版提案一致；“可行”指可以继续设计和实现，不代表审核已经批准。

| 方案 | 健康数据路径 | 四端互联能力 | 主要代价与判断 |
| --- | --- | --- | --- |
| A．原生四端＋独立端到端加密服务 | 原始样本默认留 HealthKit；选定应用记录与摘要由客户端加密后传入自有服务 | 可覆盖全部目标平台；Watch 先经 iPhone 传送，后续可增加独立联网 | 推荐。需要身份、密钥恢复、设备撤销、冲突与删除协议，另做安全及审核确认 |
| B．本地健康数据＋CloudKit 仅非健康偏好 | 支持的数据留 HealthKit，由 Apple Health 的系统设置决定是否同步；CloudKit 只存主题、语言等无健康含义的设置 | iPhone／iPad 可分别读健康数据；Mac 无原生读取通道；应用自定义记录无法因此自动四端共享 | 适合缩减范围或早期开发，单独采用不能完成用户要求的完整健康记录互联 |
| C．跨平台 UI＋独立服务 | 与 A 相同的数据边界 | 服务可以覆盖四端，但 Watch 和健康接口仍需原生实现 | 能做；Apple-only 首版没有明显减少平台工作量，暂不优先 |
| 补充选项．HealthKit＋用户主动加密导出／导入 | 标准样本留 HealthKit，选定记录以加密文件保存到本地或直接传输 | Mac 可导入，设备间依赖手动操作；不提供持续账号同步 | 可作备份或迁移辅助。任何云文件目标的适用条款另行确认，用户主动操作也不构成已确认的豁免 |

CloudKit 的私有库确实与设备上的 iCloud 账号关联，相关 App 也可以通过获授权的容器访问数据；这个技术能力不能解决前述数据分类问题。[CloudKit 私有库](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)、[CloudKit 容器](https://developer.apple.com/documentation/cloudkit/ckcontainer)

自有服务也不能简单地被称为“因此合规”。选择服务位置、子处理者、保留期限和用户授权时，仍需完成对应审查。MyEnergy 首版应尽量减少离开设备的内容，默认不上传 HealthKit 原始样本。

## Apple 登录不提供跨设备加密密钥

Sign in with Apple 提供登录身份与可由服务端校验的凭证。相关 iOS、macOS App ID 可在开发者团队内分组，减少用户重复授权；产品账户应绑定服务端验证后的稳定标识，不能用可变邮箱或显示名作为唯一主键。[Sign in with Apple 身份流程](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple)、[跨平台 App ID 配置](https://developer.apple.com/help/account/capabilities/about-sign-in-with-apple)、[App 分组](https://developer.apple.com/help/account/capabilities/group-apps-for-sign-in-with-apple/)

**工程建议。** 把账户登录与解密能力分开设计。同一 Apple 账号登录成功，只允许设备申请加入产品账户；新设备获得数据密钥仍须经过已有可信设备确认，或使用明确设计的用户恢复流程。Apple 登录令牌、邮箱和用户标识都不能充当加密密钥。

端到端加密服务的首版设计至少应回答这些问题：

- 每台设备怎样生成并保护自己的密钥，怎样登记可信设备。
- 既有设备如何核验新设备，恢复密钥遗失后能否恢复，产品如何告知恢复边界。
- 撤销设备后如何停止新数据访问及轮换密钥；已经被设备解密保存的数据无法靠远端撤销抹去。
- 退出账号、删除账号、删除健康摘要与 HealthKit 本地权限分别怎样处理。
- 服务看不到正文时，怎样处理版本、幂等、冲突、删除 tombstone 与旧设备重新上线。

以上是待实现的设计条件。未经专门评审和故障测试，不应宣称已有生产可用的端到端加密。TLS 保护传输，账户权限隔离用户，端到端加密限制服务端读取正文，三者分别需要验证。密文之外的账户、设备数、大小和时间等元数据也要最小化。

## Watch 离线队列需要配对真机

WatchConnectivity 的 `sendMessage` 用于当前可达端的即时通信；`updateApplicationContext` 只保留最新状态，会覆盖此前内容，不能用来可靠承载每一条用户记录。`transferUserInfo` 会排队传输，适合在本地持久化之后发送记录变更；后台送达时机由系统决定，不应承诺即时到达。[WCSession 通信方式](https://developer.apple.com/documentation/watchconnectivity/wcsession)

Apple 对 `transferUserInfo` 明确要求在配对设备上测试，Simulator 不支持这个方法。因此模拟器上让 Watch 页面显示“已入队”，只能证明本地流程，不能证明后台传输完成。[transferUserInfo 的真机限制](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:))

**工程建议。** Watch 记录先写入持久队列，再尝试传输；iPhone 使用稳定事件 ID 幂等接收，并在产品协议内确认。连接状态、系统传输完成、服务已保存、其他设备已收到要分别表示。必须覆盖断连、进程退出、重复接收、重新配对、账号切换和删除后旧队列回放。

若未来要求 Watch 没有 iPhone 也能独立完成联网与账号设置，应升级为独立 watchOS 应用设计。Apple 要求这类应用能自行取得所需信息，不能以 WatchConnectivity 为主要数据来源；官方允许考虑自己的服务。普通 Watch 网络请求采用 HTTPS `URLSession`；常规应用不能把持续 WebSocket 或任意底层 socket 当成通用后台连接。[独立 watchOS 应用](https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps)、[TN3135：watchOS 网络限制](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos)

## 本地可运行阶段无需先配置付费团队

Apple 明确说明，没有需 provisioning 的能力时，Mac 应用在本机运行无需设置签名。iPhone、iPad、Watch 在具备可用 runtime 后，可以先以模拟器和合成数据验证页面与共享业务；模拟器的硬件与服务行为不能作为真机验收证据。[Xcode 运行与签名说明](https://developer.apple.com/documentation/xcode/building-and-running-an-app)

| 里程碑 | 当前可以推进的工作 | 不能据此宣布完成的能力 |
| --- | --- | --- |
| M1 本地可运行 | 无账号本地记录、习惯与趋势；本机 Mac 应用；iPhone／iPad／Watch 模拟器 UI；共享逻辑测试；明确标记的合成样本 | 真实 HealthKit 授权、Watch 后台转发、真实 Apple 登录、跨设备健康数据同步 |
| M2 平台接入 | 在可用签名和设备上接入 HealthKit，验证权限、锁屏与样本缺失；配对 iPhone／Watch 验证离线队列 | 没有真实设备与授权证据时，不计平台接入完成 |
| M3 同账号互联 | 完成 Apple 登录、设备加入、密钥恢复和自有服务；联调四端增改删与离线恢复 | 用开发身份、内存 transport 或单进程模拟两个客户端，不能计真实四端互联完成 |
| M4 发布准备 | 分发签名、隐私资料、导出与删除、安全审查、真实设备功耗和审核资料 | 本地可编译不等于已经部署、可分发或已通过 App Review |

免费 Apple Account 可在 Xcode 中形成 Personal Team，安装到自己的设备需要登录、签名与 provisioning，并有短期有效限制。当前能力表中，HealthKit 对免费开发者也可用，CloudKit 和 Sign in with Apple 的免费开发者列则不支持。**免费 Personal Team 与完全不配置 Team 是两种开发状态。** 本项目没有检查用户当前的证书、团队或 provisioning profile，更没有推定它们已经存在。[开发者账户与 Personal Team](https://developer.apple.com/help/account/basics/about-your-developer-account)、[iOS 能力及会员要求](https://developer.apple.com/help/account/reference/supported-capabilities-ios)

真实跨机功能的外部配置应记录在任务依赖中：

- 有效开发者团队、唯一 Bundle ID、相应 App ID 与 capability、匹配的签名和 provisioning；使用所需能力的全部 target 都要覆盖。
- Sign in with Apple 的主 App ID、相关平台分组、服务端凭证校验和账户撤销流程；配置材料通过安全渠道处理，项目文档不保存私钥或证书内容。
- 健康数据授权、真实历史样本、配对 iPhone／Watch；iPad 需支持版本，设备是否可用仍须实际确认。
- 自有服务的 HTTPS 地址、部署环境与持久存储；开发服务可以先本地跑，真机连接、正式部署和发布属于另外的验收事项。
- 若采用方案 B 的 CloudKit 偏好同步，还需付费开发者能力、iCloud 容器、正确 entitlement、同一 iCloud 用户及环境配置。只有设置同步可用时，不得展示健康记录已同步。

Apple 的 CloudKit 开发文档明确要求 Apple Developer Program 账户来访问 CloudKit 服务与团队容器，私有库保存还需要 iCloud 账户。[Core Data 与 CloudKit 的开发前置条件](https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit)

## 关闭应用云同步还要检查备份

**已核实。** 本地应用数据可能进入 iCloud Backup。Foundation 的 `isExcludedFromBackup` 只是给系统的排除提示，不能保证文件永不出现在备份或恢复设备；某些文件操作会重置这个标记。[优化 iCloud Backup 数据](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)

**工程建议。** 对 M1 明确禁用应用级 CloudKit／iCloud 自动同步，避免把健康记录和普通偏好混在同一自动镜像 store。对敏感本地文件设置合适的保护与备份策略，每次保存后保持策略有效，并在真机核查实际行为。不要把备份排除标记写成“绝不会备份”的承诺，也不要把用户不可丢失的记录放进可清理缓存目录来规避备份。导出、恢复与数据遗失告知应一起设计。

## 发布前需要关闭的未知项

| 未知项 | 需要什么证据 | 对计划的影响 |
| --- | --- | --- |
| 情绪、精力、备注与衍生分数的数据分类 | 最终字段与用途清单；必要时向 App Review 提交具体数据流咨询并取得可保留的回复 | 确认前维持“不写入应用 CloudKit”的边界 |
| 独立服务对敏感信息的处理条件 | 目标地区、服务商、授权和保留政策的审查；必要时取得专业法律意见 | 正式发布前完成；不能凭 E2EE 自动免除 |
| 端到端加密密钥恢复与设备撤销 | 协议审查、实现证据、设备丢失和旧设备回网测试 | M3 的完成条件 |
| 真机 HealthKit 与 Watch 后台行为 | 设备、系统版本、授权、测量时间、断连和重启记录 | M2 的完成条件 |
| Team、身份配置与部署环境 | 所需配置的存在性及实际联调结果；不收集私钥内容 | 未具备时保持外部依赖状态，继续做本地独立工作 |

全部链接访问于 2026-11-18。Apple Support《管理 Apple Health 数据》页面标注发布于 2026-09-14；TN3135 修订记录包含 2026-07-16。其他页面未显示明确发布日期，本文不按搜索引擎抓取时间推定发布时间。引用仅采用 Apple 官方规范、文档、支持页，以及明确标识 Apple App Review 身份的回复。
