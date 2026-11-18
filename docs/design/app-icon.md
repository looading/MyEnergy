# MyEnergy 应用图标

2026-11-18，用户要求提供应用图标。本版使用内置 imagegen 生成原创位图，随后只做复制和平台尺寸转换；没有调用 API／CLI 生成后备流程，没有使用竞品图形。

## 视觉含义

蓝绿的叶形环形成流动的 e，金杏色星光位于环的开口。暖米白底与应用的状态主题相呼应，中心图形留出圆形裁切空间。图标不含文字、数值或表情，适用于手表的小尺寸入口。

可交付主图为 `Assets/Brand/myenergy-icon-v1.png`，1024 × 1024，PNG，无透明通道。原始生成图为 1254 × 1254，无透明通道；保留在内置工具的生成目录中，不依赖该目录构建应用。

各平台使用自己的 `Assets.xcassets/AppIcon.appiconset`：iOS／iPadOS 共用，watchOS 使用单张高分辨率图，macOS 提供完整尺寸。工程的 AppIcon 编译设置指向这些资源。实际构建结果见[验证报告](../verification/report.md)；编译结果与运行中的系统图标显示分别记录。

普通 asset catalog 的单图配置依据 Apple 的[应用图标文档](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)和[WWDC22 Watch 开发说明](https://developer.apple.com/videos/play/wwdc2022/10133/)。本版使用 PNG 资源，未使用分层图标格式。

## 生成提示词

方式：内置 `image_gen.imagegen`，`transparent_background=false`，全新生成，无参考图片。

```text
Use case: logo-brand. Create one finished original Apple app icon for MyEnergy, a native iPhone, iPad, Mac and Apple Watch app for subjective energy, mood, sleep and healthy habits. Output one square 1024x1024 full-bleed opaque icon asset, no mockup or presentation sheet. Design a distinctive, beautifully simple energy-flow emblem: a thick softly organic circular loop, gently open near its upper right, with a small rising apricot-gold spark nestled in that opening; the flowing loop can subtly suggest a leaf and the lowercase e without literal lettering. The emblem feels calm, alive and balanced rather than clinical. Soft blue-green / deep teal loop, one warm golden-apricot accent, warm ivory background with an extremely subtle soft tonal gradient. Modern polished Apple-quality graphic, mostly flat with restrained soft depth and clean crisp silhouette, no glossy glass, no busy textures. Strong recognizable mark at 32 pixels and in a circular watchOS crop; emblem centered within the central 65 percent of the square, generous clear space, background extends to every edge. No pre-rounded outer corners, no border, no lettering, no numbers, no app name, no face, no cartoon creature, no ECG or medical cross, no stock battery outline, no watermarks. The entire image is the icon, not a device screenshot.
```

原始输出由内置工具保存，项目副本与各端资源作为构建输入保存在仓库内。
