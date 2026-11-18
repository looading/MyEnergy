# MyEnergy

面向 iPhone、iPad、Apple Watch 和 Mac 的原生精力记录与健康习惯应用。

当前交付为四端本地 MVP、Apple 平台适配源码和开发环境的加密同步联调。Mac 已实际运行验证，iPhone／iPad 和 Watch 通用模拟器目标已构建。用户已选择先完成本地版本与开发账号联调。真实 Apple 登录、健康授权、配对真机传输及正式发布放到后续阶段，不阻塞本轮本地验收。

## 立即体验

需要 Xcode、Swift 6、XcodeGen 2.47 或兼容版本。最低系统为 macOS 14、iOS／iPadOS 17、watchOS 10。

```sh
./scripts/run-mac.sh
```

已构建的应用位于 `build/DerivedData/Build/Products/Debug/MyEnergy.app`，也可以打开 `MyEnergy.xcodeproj` 选择 scheme。

## 当前功能

- 今日看板、0～100 主观精力、五档独立心情、备注和发生时间。
- 记录新增、详情、编辑、删除和完整历史入口。
- 习惯创建、编辑、停用、恢复、完成与撤销。
- 7／30 天趋势及等价逐日列表，缺失日不计为零。
- 独立睡眠页、开始／结束与每日主要时长、7／30 天睡眠变化；本地可手动补记并编辑／删除，明确标为自述时段估算。
- 自动睡眠来源按需读取 Apple 健康，重叠样本去重；同日不同来源不相加，原始历史留在设备。
- 独立内存示例空间，持续标识，退出后恢复本人记录；示例不读取健康或同步。
- 校验、原子文件存储、损坏文件保留、JSON 导出及删除标记。
- iPhone tab、iPad／Mac 侧栏、Watch 快记与 Digital Crown；深色及动态字体适配。
- HealthKit 只读适配、HRV 历史对照、睡眠区间去重；Mac 不申请健康读取。
- Watch 持久队列、账号命名空间、因果基线、显式保存确认和冲突选择。

精力与心情来自自评，身体参考独立展示。健康摘要默认关闭；仅在用户单独同意后同步选定的当前摘要，不包含 HealthKit 原始样本或历史序列。Mac 可显示来源、采样时间和更新时间。

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

本机目前没有可用 Simulator runtime。通用目标编译不能算作模拟器或真机运行通过。

## 真机配置

无 Team 的 Debug 关闭签名及需团队的 entitlement。真机使用 `DeviceDebug` configuration，配置你的 Team、唯一 Bundle ID、HealthKit 和 Sign in with Apple；Watch companion 与 iPhone 关联标识保持一致。

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
