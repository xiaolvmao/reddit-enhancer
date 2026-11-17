# Reddit Enhancer — Reddit 2026.46.0 去广告 / 优化插件

针对 `com.reddit.Reddit` **2026.46.0**（可执行文件 `RedditApp`，你提供的 IPA）的 TrollStore 注入 dylib 插件。
**去广告默认开启**，设置以原生 iOS 开关（UISwitch）形式呈现，入口是一个可拖动悬浮按钮。

---

## 一、我是怎么分析这个 IPA 的（重要结论）

解包并对 194 MB 主二进制做了 Mach-O / 符号 / 字符串分析，得到几个决定方案的关键事实：

| 项目 | 结论 | 对插件的影响 |
|---|---|---|
| 架构 / 加密 | ARM64，`MH_EXECUTE`，已解密 | 可直接符号分析、可注入 |
| 语言 | **纯 Swift**，模块化（`_TtC` mangled 符号），约 91 万个符号 | 绝大多数类**无法**用传统 Objective-C `%hook` |
| 广告投递方式 | 服务端注入的 JSON：`AdPost` / `PROMOTED_COMMUNITY_POST` / `CellGroup.adPayload` / `recommendationContext` | 应在**网络响应 JSON** 层过滤，而不是 Hook UI 类 |
| 存在的 JSON 键 | `adPayload`、`AdPost`、`SubredditPost`、`CellGroup`、`recommendationContext`、`isScoreHidden`、`awardings`、`isGildable`、`isHidden`、`isNsfw`、`isInitiallyCollapsed`、`authorInfo` 全部**确认存在** | 过滤逻辑对 2026.46.0 有效 |
| 已消失的旧键 | `commentsPageAds`、`commentTreeAds`、`pdpCommentsAds`、`isPromotedUserPostAd` 等 | 旧版 RedditFilter 的这部分 Hook 在新版**已失效**，本插件不再依赖它们 |
| 网络层 | `NSURLSession -dataTaskWithRequest:completionHandler:` 签名存在；同时也用了 Swift `URLSession.data(for:delegate:)` 异步 API | 单 Hook 网络回调不够，**补了一层 JSON 解析 Hook** 双保险 |
| 设置页 | 已是 **SwiftUI**（`RedditAppSettings_Internal` 模块，`AppSettingsRouterImpl` 等）；旧的 `AppSettingsViewController` / `UserDrawerViewController` **不存在** | 无法把入口插进原生设置页，改为**自包含悬浮入口 + 自绘设置面板**，不依赖 App 私有类，最稳 |
| 主题/ cell 类 | `ToggleImageTableViewCell`、`BaseTableReusableView`、`ImageLabelTableViewCell` 仍存在 | 但未使用，避免耦合 |

> 结论：去广告和精简功能，**在网络 JSON 层做是唯一对 2026.46.0 稳定可靠的方案**。上层 SwiftUI 全是 mangled 符号，硬 Hook 会在下次更新即失效且极易崩溃。

参考了开源项目 [level3tjg/RedditFilter（MIT）](https://github.com/level3tjg/RedditFilter) 的成熟过滤思路，并按 2026.46.0 实际存在的键重写与增强。

---

## 二、功能 / 开关

进入 App 的**设置页**（Settings）→ 右上角出现 **「增强设置」** 按钮 → 点开即为原生开关二级菜单，**全中文、全部即时生效**，无需重启 App。

**内容过滤**
1. **去除广告与推广**（默认开）— 过滤推广帖、`AdPost`、`CellGroup.adPayload`、广告容器
2. **隐藏推荐内容** — 过滤推荐/相似帖子注入
3. **屏蔽 NSFW 内容** — 屏蔽 NSFW 帖

**界面精简**
4. **隐藏赞赏徽章** — 隐藏帖子/评论的 Awards 徽章
5. **隐藏投票数** — 隐藏票数（利用 `isScoreHidden`）
6. **自动折叠 AutoMod** — 自动折叠 AutoMod 评论
7. **隐藏 Premium 推广** — 移除 Premium 推广 cell

> 入口实现：由于 2026.46.0 的设置页已改为纯 SwiftUI（无 `AppSettingsViewController` 等 UIKit 类可 Hook），
> 插件改为 Hook 系统 `UIViewController.viewDidAppear:`，在检测到设置页时于其导航栏注入「增强设置」按钮。
> 不依赖任何 Reddit 私有类，因此不受 App 内部重构影响。旧版的悬浮 RE 按钮已移除。

其他优化（已内置、无需开关）：
- Hook `NSURLSession` + `NSJSONSerialization` 双通道，覆盖同步回调与 Swift async/await 两条网络路径；
- 对非 feed 的 JSON 通过字节嗅探跳过，几乎零额外开销；
- 递归深度上限 + 递归锁，避免死循环与重复过滤；
- **不依赖 Substrate / ElleKit**（纯 `method_setImplementation`），注入更简单、更少兼容问题；
- 偏好存于 App 沙盒 `NSUserDefaults`。

---

## 三、编译

### 方式 A：GitHub Actions 云编译（推荐，无需 Mac，本机 Windows 可用）

工程已配好 `.github/workflows/build.yml`，用 `Randomblock1/theos-action@v1` 拉取 Theos + iOS 16.5 SDK 并产出纯 dylib。该 action 在 **Linux runner（ubuntu-latest）** 上交叉编译，不消耗 macOS 额度（新账号的 macOS runner 常被限制）。本工程已在此方式下**实测编译通过**。

仓库已建好：`https://github.com/xiaolvmao/reddit-enhancer`

推送任意提交到 `master` 即自动触发编译；也可在 Actions 页面点 **Run workflow** 手动触发。

1. 打开仓库的 **Actions** 标签页 → 选中 **Build RedditEnhancer dylib**；
2. 构建完成后，在该 run 页面底部 **Artifacts** 下载 `RedditEnhancer-dylib`，解压得到 `RedditEnhancer.dylib`。

> 已验证产物：`RedditEnhancer.dylib`（arm64，约 88 KB），LC_ID_DYLIB 为
> `@executable_path/Frameworks/RedditEnhancer.dylib`，仅依赖系统框架，不含 libsubstrate / libellekit，
> 可直接用于 TrollStore 注入。工程根目录也已放好本次编译好的成品。

### 方式 B：本地 macOS + Theos

```bash
# 安装 Theos（rootless）
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
# 把 iPhoneOS16.5.sdk 放到 $THEOS/sdks/（来自 theos/sdks 仓库）

cd RedditEnhancerTweak
make clean && make FINALPACKAGE=1   # 产出 RedditEnhancer.dylib
```

产物：`RedditEnhancer.dylib`（arm64，无 Substrate 依赖）。

---

## 四、注入 IPA（TrollStore）

### 前置
- 已解密的 Reddit IPA（你提供的这个就是解密版）；
- macOS 上装 `azule`（图形化，最简单）或命令行 `optool` / `insert_dylib`；
- 已安装 TrollStore 的设备。

### 方式 A：Azule（最省事）
1. 打开 Azule → 选择 Reddit IPA；
2. 在 "Dylibs / Tweaks" 里添加编译好的 `RedditEnhancer.dylib`；
3. 模式选 **TrollStore / Rootless**；
4. 注入并导出新 IPA。

### 方式 B：命令行（optool）

```bash
unzip Reddit-2026.46.0.ipa -d work
mkdir -p work/Payload/RedditApp.app/Frameworks
cp RedditEnhancer.dylib work/Payload/RedditApp.app/Frameworks/

optool install -c load \
  -p @executable_path/Frameworks/RedditEnhancer.dylib \
  -t work/Payload/RedditApp.app/RedditApp

cd work && zip -qr ../Reddit-Enhanced.ipa Payload
```

> 注意：Roothless/TrollStore 下 `@executable_path` 指向 App Bundle，路径写法以你的注入工具为准。
> 本 dylib 无 Substrate 依赖，因此**不需要**额外注入 CydiaSubstrate / ElleKit。

### 安装
把 `Reddit-Enhanced.ipa` 通过分享菜单用 **TrollStore** 安装。首次打开会看到悬浮 **RE** 按钮。

---

## 五、验证与排错

- **广告还在？** 确认开关 "Remove Ads / Promoted" 已打开；新版广告由 `adPayload` 注入，需刷新信息流（下拉）才会过滤新数据。
- **悬浮按钮不出现？** 说明 dylib 未被加载：检查注入是否成功（`otool -L RedditApp | grep RedditEnhancer`），以及是否用了 TrollStore 安装。
- **App 崩溃？** 多半是注入路径不对或 dylib 架构/签名问题：确认 arm64、ad-hoc 签名（`ldid -S RedditEnhancer.dylib`）。
- **开关无效？** 所有开关读取 `NSUserDefaults`，改完立即对后续请求生效，已缓存的旧内容需下拉刷新。

---

## 六、源码结构

```
RedditEnhancerTweak/
├── Tweak.m        # 全部逻辑：过滤 + 网络/JSON Hook + 悬浮入口 + 开关面板
├── Makefile       # Theos 构建
├── control        # 包元数据
└── README.md      # 本文件
```

## 七、法律 / 使用声明

本插件仅用于个人学习与本地使用。修改客户端可能违反 Reddit 服务条款，请自行承担账号风险；建议用备用账号测试。请勿二次分发修改后的 IPA。

**重要：** 源码已完成静态审查，但因当前环境无 iOS 工具链，**未在本机实际编译、也未在真机运行验证**。请在可读日志/可调试环境先验证，再日常使用。
