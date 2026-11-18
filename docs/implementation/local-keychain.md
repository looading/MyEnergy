# 无 Team 的本地 Mac 安全存储

日期：2026-11-18。仅适用于当前本地开发阶段。

原路径显式选择 macOS 数据保护钥匙串。实际未签名进程写入返回 -34018；SDK SecBase.h 将其定义为 errSecMissingEntitlement。使用相同随机键和测试数据，只将 kSecUseDataProtectionKeychain 设为 false，系统登录钥匙串写入、读取、删除成功。最终脚本在独立进程间重复验证，不读取用户已有数据，也不输出值。

修复通过编译条件限定为 macOS Debug，采用独立 service 名 app.myenergy.local-development.v1；Release 与 iOS／watchOS 沿用数据保护钥匙串及原有 service。两套实现不自动混用。macOS 登录钥匙串仍是系统加密存储，使用登录用户的访问控制，没有增加明文凭据文件；ThisDeviceOnly 属性的移动平台语义不被声称适用于这个本地开发实现。

复现：scripts/check-local-keychain.sh。应用账号区也显示当前后端说明。

依据：[Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)、[Apple -34018 排查](https://developer.apple.com/forums/thread/114456)。后续正式签名版本继续核实 entitlement 与数据保护访问组，不将此开发路径作为生产自动回退。
