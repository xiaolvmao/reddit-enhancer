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
1. **去除广告与推广**（默认开）— 过滤推广帖、`AdPost`、`CellGroup.adPayload`、广告容器；
   v5 起额外覆盖 `PromotedCommunityPost`、`ConversationAd`/`CommentAd`（评论区内嵌广告）、
   `isAd`/`isPromoted` 标记节点，并把广告节点**直接从列表里摘除**（不再是只打个隐藏标记）
2. **隐藏推荐内容** — 过滤推荐/相似帖子注入
3. **屏蔽 NSFW 内容** — 屏蔽 NSFW 帖
4. **隐藏赞赏徽章** — 隐藏帖子/评论的 Awards 徽章
5. **隐藏投票数** — 隐藏票数（利用 `isScoreHidden`）

**侧边栏（左侧抽屉）**
6. **隐藏左侧抽屉和入口按钮**（默认开，v7.2）— 抽屉**彻底不出现**，同时把**左上角的抽屉入口按钮**
   一起删掉：① 在 `-[UIViewController presentViewController:animated:completion:]` 里直接拒绝呈现
   `CommunityDrawer*`，连数据都不再拉取；② 拦 `UINavigationItem` 的 `leftBarButtonItem(s)` /
   `rightBarButtonItem(s)` 四个 setter，把 `CommunityDrawerBarButtonItem` /
   `UserAccountDrawerBarButtonItemImpl`（头像式入口）这类条目在挂上去的那一刻就丢掉，
   再加 `viewDidAppear` 兜底扫一遍导航栏。想恢复原生抽屉把这个开关关掉即可
   > v7.2 起从设置里**移除**了「只保留核心入口 / 隐藏 Reddit 上的游戏 / 隐藏资源·关于」三个开关
   > （抽屉已经不显示了，它们没有意义）。对应代码仍保留：默认值就是「开」，
   > 只是不再出现在界面上。

**界面精简**
7. **折叠 AutoMod 评论** — 自动折叠 AutoMod 机器人的回复
8. **隐藏 Premium 推广** — 移除 Premium 横幅、升级提示与 upsell cell
9. **隐藏趋势 / Trending**（默认开）— 去掉搜索页的 Trending 单元（`SearchTrendingFeedUnit`）与抽屉趋势分区
10. **隐藏 Reddit Answers 入口**（默认开）— 去掉搜索栏「Ask Answers」按钮、Answers 预览卡与 AI 产品卡

**隐私与体验**
11. **屏蔽广告与统计追踪**（默认开）— 拦截 `ads.reddit.com`／`ads-api.reddit.com`／`alb.reddit.com`／`pixel-config.reddit.com`／Appsflyer／Firebase／Braze／Sentry 等域名，请求不出网
12. **屏蔽 App Store 评分弹窗**（默认开）— Hook `SKStoreReviewController requestReview`
13. **屏蔽「速率限制」提示**（默认开，v7）— 拦 `UIAlertController` 与挂在窗口上的浮层提示条，
    文案命中 `速率限制 / 请求过于频繁 / rate limit / too many requests` 才动手，普通报错不受影响

> **速率限制到底能不能「解决」？**
>
> 分两种情况：
>
> 1. **抽屉/列表拉取触发的**（`CommunityDrawerTableViewFailedCell`、`CommunityDrawerItemsQuery`）——
>    v7 起抽屉根本不打开，这类请求不再发出，**已经从根上消失**。
> 2. **发帖 / 评论 / 投票 / 私信触发的**（`spamRateLimitMessage`、`rateLimitBanner`、`rateLimitExceeded`）——
>    这是**服务端按账号 + IP + karma + 子版规则**算出来的，客户端**无法解除**。任何「破解限流」
>    的做法最多是伪造成功提示，实际请求照样被拒，还可能加重风控。
>
> 插件能做的是三件事：① 不再发起无谓请求（已拦截追踪/广告域名）；② 不被提示打断（第 13 项）；
> ③ 把抽屉这个高频触发点整个关掉。真要降低触发概率，只能：别在短时间内连发同类操作、
> 新账号先积累 karma、避免使用被大量共享的代理 IP。

> **「折叠 AutoMod 评论」说明**：Subreddit 的 AutoMod 是自动管理机器人，常发置顶规则/说明。开启后，它发的评论在加载时默认是折叠状态（点一下仍可展开），让评论区优先显示真实用户的讨论。默认关闭。
>
> **侧边栏白名单（v6 实现；v7.2 起抽屉默认不打开，仅作兜底，设置里已不再暴露）**：
> 抽屉表里的每一行都带 `accessibilityIdentifier`（`UIIdentifier` 枚举的 rawValue），
> 二进制里能读到确切名字，所以按**白名单**判定比黑名单干净得多：
>
> | 保留 | 标识 |
> |---|---|
> | 热门 | `…E17DrawerPopularItem` |
> | 新闻 | `…E14DrawerNewsItem` |
> | 最新 | `…E16DrawerLatestItem` |
> | 创建社区 | `…e12DrawerCreateE4Item` |
> | 最近访问 | `…E25DrawerRecentlyVisitedItem`（分区 `…E28DrawerRecentlyVisitedSection`） |
> | 你的社区 | `…E29DrawerSubscribedSubredditItem`（分区 `…E28DrawerYourCommunitiesSection`） |
>
> **判定规则**：标识里同时含 `drawer` 与 `item`/`cell` 的，就是抽屉里的一行 ——
> 只有命中上表的才留，其余一律移除（高度归零 = 真正移除，**不留空白**，也不碰行数）。
> 分区标题不在保留列表的（`关于`/`资源`/`规则`/`发现`/`收藏`/`关注`/`我管理的`/`活动`/`趋势`…）
> 整段折叠，header / 行 / footer 三个高度同时归零。
> 拿不到标识的行按文案兜底，两边都不认识就**保留**（宁可留一条，也不误删）。
>
> **两个防误删机制**：① 只有「真标题」（`titleForHeaderInSection`）才做白名单判断，
> 分区头视图里的文字只按明确的垃圾词判定 —— 头视图第一段文字可能是用户名或按钮文案；
> ② 如果某个被折掉的分区里出现了**明确识别**为六个入口之一的行，立刻解折（自愈），
> 不会因为标题判断失误把「你的社区」整段吞掉。
>
> **侧边栏历史（v2–v5.2）**：
> - v2 只写 UserDefaults 折叠 key → 无效（抽屉内容被 `CommunityDrawerCacheServiceImpl` 缓存成 ViewModel）。
> - v3 改成「返回 0 行」→ **闪退**。抽屉表格是 `_UIDiffableDataSource`，行数由快照决定；
>   篡改 `numberOfRowsInSection` 会让行数和快照脱钩，UIKit 在批次更新时抛
>   `NSInternalInconsistencyException（Invalid update）` 直接 abort（崩溃日志已证实）。
> - v4 改为**只动高度**，不再碰行数、不 reloadData。v6 沿用这个安全边界。
> - v5.2 修掉「逐行隐藏留空白」和「分区下标跨实例缓存导致错折正常分区」。
>
> **完全隐藏抽屉是怎么做的（v7）**：二进制里抽屉走的是**模态呈现** —— `DrawerPresentationController`
> + `DrawerAnimator` + `initWithDrawerViewController:`，打开入口是 `CommunityDrawerEdgePanManagerImpl`
> 的边滑手势和 `CommunityDrawerBarButtonItem`。所以在
> `-[UIViewController presentViewController:animated:completion:]` 里判定「要呈现的 VC
> （或它包着的导航栈）类名含 `CommunityDrawer`」就直接 `return`：抽屉不会创建视图，
> 也不会再去拉 `CommunityDrawerItemsQuery`（限流提示的常见来源）。
> 兜底（万一走的是 `addChildViewController` 而不是模态）：`viewWillAppear:` 时把整个呈现容器
> （连调暗遮罩）设成 `hidden` + `userInteractionEnabled = NO`，再 `dismissViewControllerAnimated:NO`。
> hidden 的视图不参与 hitTest，所以即使 dismiss 没成功，也不会出现「看不见的模态层吃掉所有点击」。
>
> **左上角抽屉按钮是怎么删的（v7.2）**：二进制里入口按钮有两套实现 ——
> `CommunityDrawerBarButtonItem`（汉堡键，UIIdentifier `redditCommunityDrawerBarButton`）和
> `UserAccountDrawerBarButtonItemImpl`（头像入口，内部视图标识 `userProfileAccountAvatarButton…`），
> 对齐方式由 `AccountDrawerButtonAlignment` 决定（可能左也可能右）。所以：
> ① swizzle `UINavigationItem` 的 `setLeftBarButtonItem(s):` / `setRightBarButtonItem(s):`，
> 命中「类名含 Drawer / 标识含 drawer·avatar / customView 子树带同样标识」的条目直接丢掉；
> ② `viewDidAppear` 再把导航栏扫一遍（SwiftUI 复写导航栏时会把按钮重新挂上）；
> ③ 最后一道：`setAccessibilityIdentifier:` 里命中 `drawerbar` / `drawerbutton` 的视图直接 `hidden = YES`。
> 想恢复按钮：关掉「隐藏左侧抽屉和入口按钮」。
>
> **趋势 / Answers 是怎么去掉的（v4.2）**：这两块是 SwiftUI 页面，没有可 hook 的 UIKit 类，
> 但 Reddit 会把 `UIIdentifier` 枚举的 rawValue 写进 `accessibilityIdentifier`。所以走两条路：
> ① JSON 层：把 `SearchTrendingFeedUnit`、`SearchAnswersPreview*`、`AnswersProductCard/Hero`
> 这些 `__typename` 打上 `isHidden`，或把 `trendingSearches` 之类的数组清空；
> ② Hook `-[UIView setAccessibilityIdentifier:]`：一旦发现标识是 `...askAnswersButton`、
> `...TrendingToday...`，直接 `hidden = YES`。这条 hook 只在 App 设置标识时触发，开销极低。
>
> **安装提示（重要）**：注入后必须重签**嵌套框架**，否则 dyld 会在启动阶段直接终止，报
> `Library not loaded: @rpath/ExtensionDependencies.framework/...（code signature invalid）`。
> 这跟插件无关（此时 dylib 还没被加载）。要么用会做深度签名的注入器，要么先
> `codesign -f -s <证书> Payload/RedditApp.app/Frameworks/*.framework`，再签主 App。
>
> **Premium 说明（重要）**：设置里的「获取 Premium」是 StoreKit 内购，会员状态由服务端下发（`RedditCore_Models.User.hasPremium` 是 Swift 结构体字段，二进制里没有任何可 swizzle 的 ObjC 账号模型）。**客户端无法真正解锁会员权益**，插件只保留「隐藏 Premium 推广」。想真正去广告用第 1 项即可。

> 入口实现：2026.46.0 的设置页是纯 SwiftUI，因此 Hook 系统 `UIViewController.viewDidAppear:`，
> 检测到设置页时在**导航栏**注入「增强设置」。v4 移除了 v3 那个角落小胶囊按钮：
> 先找 `UINavigationController`，没有就退到 SwiftUI 自己的 `UINavigationBar`（`SwiftUI.UIKitNavigationBar`），
> 找不到就延迟重试 3 次（SwiftUI 导航栏是渲染后才生成的）。**不再有任何悬浮/角落按钮。**
>
> **v5 修掉「嵌套按钮」**：进增强设置后右上角又冒出一个「增强设置」，是因为注入逻辑
> 只看类名/标题里有没有 “settings/设置”——而我们自己的二级菜单标题就叫「增强设置」。
> 现在四道闸：① `REIsOwnVC()` 认自己的 VC（含包裹它的导航控制器）；
> ② 全局 `gREOwnUIVisible` 计数，自身界面在前台时一律不注入；
> ③ `RETopViewControllerIsOurs()` 看 key window 的 modal 链顶层；
> ④ 进页面时主动把导航栏里带「增强」字样的按钮摘掉（幂等兜底）。
>
> **诊断页**：增强设置 → 其他 → 诊断信息。会显示 hook 安装数、抽屉表格接管数、被折叠的分区数、
> 拦截打开抽屉次数、移除抽屉入口按钮数、屏蔽限流提示次数、拦截的追踪请求数、网络命中次数、全部开关状态与实时日志；日志里还会**留档抽屉里出现过的每个
> cell 类名 / 无障碍标识 / 分区标题**，反馈时截图即可精确定位。

其他优化（已内置、无需开关）：
- Hook `NSURLSession` + `NSJSONSerialization` 双通道，覆盖同步回调与 Swift async/await 两条网络路径；
- 对非 feed 的 JSON 通过字节嗅探跳过，几乎零额外开销；
- 递归深度上限 + 递归锁，避免死循环与重复过滤；
- **不依赖 Substrate / ElleKit**（纯 `method_setImplementation` / `class_addMethod`），注入更简单、更少兼容问题；
- 偏好同时写 App Group（`group.com.reddit.Reddit`）与 standard；读取时 Group 显式值优先；
- 抽屉分区过滤带**安全阀**（仅黑名单模式）：分区行数 > 14 且命中 <3 次时放弃折叠，避免误把整条侧边栏清空；
  白名单模式不做该限制（那是明确要删的），但能用「明确保留行 → 解折」自愈；
- 行列状态按 tableView 存，结构指纹（分区数 + 总行数）一变立刻清空，**不跨实例复用下标**；
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
