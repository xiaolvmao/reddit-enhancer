# Reddit Enhancer — Reddit 2026.46.0 去广告 / 优化插件

针对 `com.reddit.Reddit` **2026.46.0**（可执行文件 `RedditApp`，你提供的 IPA）的 TrollStore 注入 dylib 插件。
**去广告默认开启**，设置以原生 iOS 开关（UISwitch）形式呈现，入口是设置页导航栏的「增强设置」。

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
| 设置页 | 已是 **SwiftUI**（`RedditAppSettings_Internal` 模块，`AppSettingsRouterImpl` 等）；旧的 `AppSettingsViewController` / `UserDrawerViewController` **不存在** | 不能往 SwiftUI 列表里塞行，改为 Hook `viewDidAppear:` 后往**导航栏**注入「增强设置」，打开自绘的二级菜单 |
| 主题/ cell 类 | `ToggleImageTableViewCell`、`BaseTableReusableView`、`ImageLabelTableViewCell` 仍存在 | 但未使用，避免耦合 |

> 结论：去广告和精简功能，**在网络 JSON 层做是唯一对 2026.46.0 稳定可靠的方案**。上层 SwiftUI 全是 mangled 符号，硬 Hook 会在下次更新即失效且极易崩溃。

参考了开源项目 [level3tjg/RedditFilter（MIT）](https://github.com/level3tjg/RedditFilter) 的成熟过滤思路，并按 2026.46.0 实际存在的键重写与增强。

---

## 二、功能 / 开关

进入 App 的**设置页**（Settings）→ 导航栏右上角出现 **「增强设置」** → 点开即为原生开关二级菜单，**全中文、全部即时生效**，无需重启 App。

**内容过滤**
1. **去除广告与推广**（默认开）— 过滤推广帖、`AdPost`、`CellGroup.adPayload`、广告容器
2. **隐藏推荐内容** — 过滤推荐/相似帖子注入
3. **屏蔽 NSFW 内容** — 屏蔽 NSFW 帖
4. **隐藏赞赏徽章** — 隐藏帖子/评论的 Awards 徽章
5. **隐藏投票数** — 隐藏票数（利用 `isScoreHidden`）

**侧边栏（左侧抽屉）**
6. **隐藏「Reddit 上的游戏」**（默认开）— 折叠抽屉里的 Devvit 游戏推荐分区
7. **隐藏「资源」推广区**（默认开）— 折叠 Reddit Pro／Premium／广告合作等入口

**界面精简**
8. **折叠 AutoMod 评论** — 自动折叠 AutoMod 机器人的回复
9. **隐藏 Premium 推广** — 移除 Premium 横幅、升级提示与 upsell cell

**隐私与体验**
10. **屏蔽广告与统计追踪**（默认开）— 拦截 `ads.reddit.com`／`ads-api.reddit.com`／`alb.reddit.com`／`pixel-config.reddit.com`／Appsflyer／Firebase／Braze／Sentry 等域名，请求不出网
11. **屏蔽 App Store 评分弹窗**（默认开）— Hook `SKStoreReviewController requestReview`

> **「折叠 AutoMod 评论」说明**：Subreddit 的 AutoMod 是自动管理机器人，常发置顶规则/说明。开启后，它发的评论在加载时默认是折叠状态（点一下仍可展开），让评论区优先显示真实用户的讨论。默认关闭。
>
> **侧边栏游戏位 / 资源位（v4 已重写）**：
> - v2 只写 UserDefaults 折叠 key → 无效（抽屉内容被 `CommunityDrawerCacheServiceImpl` 缓存成 ViewModel）。
> - v3 改成「返回 0 行」→ **闪退**。抽屉表格是 `_UIDiffableDataSource`，行数由快照决定；
>   篡改 `numberOfRowsInSection` 会让行数和快照脱钩，UIKit 在批次更新时抛
>   `NSInternalInconsistencyException（Invalid update）` 直接 abort（崩溃日志已证实）。
> - v4 改为**只动高度**：把该分区的 `heightForRow` / `heightForHeader` 归零 + 隐藏 cell，
>   再用 `beginUpdates/endUpdates` 触发高度重算。**不碰行数、不 reloadData**，因此不可能触发该崩溃。
>   识别信号三重冗余：cell/header 类名 + `accessibilityIdentifier` + 视图树文案。
>
> **Premium 说明（重要）**：设置里的「获取 Premium」是 StoreKit 内购，会员状态由服务端下发（`RedditCore_Models.User.hasPremium` 是 Swift 结构体字段，二进制里没有任何可 swizzle 的 ObjC 账号模型）。**客户端无法真正解锁会员权益**，插件只保留「隐藏 Premium 推广」。想真正去广告用第 1 项即可。

> 入口实现：2026.46.0 的设置页是纯 SwiftUI，因此 Hook 系统 `UIViewController.viewDidAppear:`，
> 检测到设置页时在**导航栏**注入「增强设置」。v4 移除了 v3 那个角落小胶囊按钮：
> 先找 `UINavigationController`，没有就退到 SwiftUI 自己的 `UINavigationBar`（`SwiftUI.UIKitNavigationBar`），
> 找不到就延迟重试 3 次（SwiftUI 导航栏是渲染后才生成的）。**不再有任何悬浮/角落按钮。**
>
> **诊断页**：增强设置 → 其他 → 诊断信息。会显示 hook 安装数、抽屉表格接管数、被折叠的分区数、
> 拦截的追踪请求数、网络命中次数、全部开关状态与实时日志；日志里还会**留档抽屉里出现过的每个
> cell 类名 / 无障碍标识 / 分区标题**，反馈时截图即可精确定位。

其他优化（已内置、无需开关）：
- Hook `NSURLSession` + `NSJSONSerialization` 双通道，覆盖同步回调与 Swift async/await 两条网络路径；
- 对非 feed 的 JSON 通过字节嗅探跳过，几乎零额外开销；
- 递归深度上限 + 递归锁，避免死循环与重复过滤；
- **不依赖 Substrate / ElleKit**（纯 `method_setImplementation` / `class_addMethod`），注入更简单、更少兼容问题；
- 偏好同时写 App Group（`group.com.reddit.Reddit`）与 standard；读取时 Group 显式值优先；
- 抽屉分区过滤带**安全阀**：分区行数 > 10 视为「整块抽屉列表」，放弃折叠，避免把整条侧边栏清空；
- 所有会在布局期间/批次更新期间执行的 hook 都加了 `@try/@catch`，异常只记日志不崩溃。

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
