//
//  RedditEnhancer — TrollStore tweak for Reddit 2026.46.0
//  Bundle ID: com.reddit.Reddit   Executable: RedditApp
//
//  v6 —— 抽屉改成「白名单」：只保留 热门 / 新闻 / 最新 / 创建社区 /
//        最近访问 / 你的社区，其余全部移除（按行高度归零，不留空白）。
//
//  v5 —— 去掉增强设置页里的「嵌套入口」+ 广告清理补全
//
//  v4 —— 修复 v3 崩溃 + 入口收敛到设置页导航栏
//
//  v3 崩溃根因（RedditApp-2026-11-17-210334.ips）：
//    _UIDiffableDataSourceViewUpdater → -[UITableView _endCellAnimationsWithContext:]
//    → NSInternalInconsistencyException（Invalid update）
//    抽屉表格用的是 diffable data source，行数由快照决定；
//    v3 在 numberOfRowsInSection 里返回 0，等于让表格行数和快照脱钩，
//    下一次批次更新必然判定「行数不一致」→ abort。
//  v4 结论：绝对不能动 numberOfRowsInSection / numberOfSections / reloadData，
//    改用「行高 + header 高度归零 + cell 隐藏」的纯视觉折叠，UIKit 不会校验高度。
//
//  静态分析事实（Reddit 2026.46.0 真实二进制）：
//   * 抽屉 = CommunityDrawer_Rendering_Internal.CommunityDrawerViewController
//            + CommunityDrawerTableViewDelegateHandler (UITableViewDataSource/Delegate)
//            + CommunityDrawerTableViewCell / CommunityDrawerSectionView
//   * UI 标识（UIIdentifier 枚举 rawValue，写入 accessibilityIdentifier）：
//       redditCommunityDrawerResourcesSection
//       redditCommunityDrawerFeaturedGameCell / ...DiscoverMoreGamesItem
//       ...AdvertiseOnTitle / ...TryProTitle / ...PremiumTitle / ...ProLinksTitle
//       ...RulesTitle / ...PrivacyPolicyTitle / ...UserAgreementTitle
//       ...AcknowledgementsTitle / ...OSAInformationTitle / ...ImpressumTitle
//   * 会员：RedditCore_Models.User.hasPremium 是 Swift 结构体字段，
//     premiumStatus 只是某个 UI 视图模型的 ivar。没有 ObjC 账号模型，
//     会员状态完全由服务端下发 → 客户端无法真正解锁。
//
//  本版策略：
//   1) 抽屉（v6 白名单）：行级按 accessibilityIdentifier 判定，只留六个入口；
//      不要的行高度归零（= 真正移除，不留空白，也不碰行数）；分区标题不在
//      保留列表的整段折叠。若某个分区里出现保留行，自动解折（自愈）。
//   2) 设置入口：只保留设置页导航栏上的「增强设置」，去掉角落小胶囊按钮；
//      并且自身界面可见时一律不再注入（v5 修掉「嵌套按钮」）。
//   3) 新增：拦截广告 / 统计追踪请求；拦截 App Store 评分弹窗。
//   4) 广告清理（v5）：AdPost / PromotedCommunityPost / ConversationAd /
//      CommentAd 等节点直接从列表里摘除，不留占位块。
//   5) 诊断页：显示所有 hook 命中计数与实时日志，便于逐步定位。
//
//  Build: Theos library.mk -> plain dylib, no Substrate dependency.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdarg.h>

// ---------------------------------------------------------------------------
// 偏好 key
// ---------------------------------------------------------------------------
static NSString *const kREFilterPromoted      = @"RE.filter.promoted";
static NSString *const kREFilterRecommended   = @"RE.filter.recommended";
static NSString *const kREFilterNSFW          = @"RE.filter.nsfw";
static NSString *const kREHideAwards          = @"RE.hide.awards";
static NSString *const kREHideScores          = @"RE.hide.scores";
static NSString *const kRECollapseAutoMod     = @"RE.collapse.automod";
static NSString *const kREHidePremium         = @"RE.hide.premium";
static NSString *const kREHideDrawerGames     = @"RE.hide.drawer.games";
static NSString *const kREHideDrawerResources = @"RE.hide.drawer.resources";
static NSString *const kREBlockTrackers       = @"RE.block.trackers";
static NSString *const kREBlockReviewPrompt   = @"RE.block.reviewprompt";
static NSString *const kREHideTrending        = @"RE.hide.trending";
static NSString *const kREHideAnswers         = @"RE.hide.answers";
static NSString *const kREDrawerWhitelist     = @"RE.drawer.whitelist";

// Reddit 自己的抽屉折叠 key（写入作为次要手段）
static NSString *const kRECollapsedGamesKey     = @"isGamesOnRedditCollapsed";
static NSString *const kRECollapsedResourcesKey = @"isResourcesCollapsed";
static NSString *const kRECollapsedAboutKey     = @"isAboutCollapsed";

// ---------------------------------------------------------------------------
// 偏好读写（App Group + standard 双读双写）
// ---------------------------------------------------------------------------
static NSUserDefaults *REGroup(void) {
    static NSUserDefaults *prefs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefs = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.reddit.Reddit"];
    });
    return prefs;
}

static BOOL REBool(NSString *key, BOOL fallback) {
    id v = [REGroup() objectForKey:key];
    if (v) return [v boolValue];
    v = [NSUserDefaults.standardUserDefaults objectForKey:key];
    if (v) return [v boolValue];
    return fallback;
}

static void REBoolSet(NSString *key, BOOL value) {
    [REGroup() setBool:value forKey:key];
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
}

static void REWriteDrawerCollapseKeys(void) {
    if (REBool(kREHideDrawerGames, YES)) {
        REBoolSet(kRECollapsedGamesKey, YES);
    }
    if (REBool(kREHideDrawerResources, YES)) {
        REBoolSet(kRECollapsedResourcesKey, YES);
        REBoolSet(kRECollapsedAboutKey, YES);
    }
}

// ---------------------------------------------------------------------------
// 日志 / 计数器
// ---------------------------------------------------------------------------
static NSMutableArray<NSString *> *gRELog = nil;
static NSObject *gRELogLock = nil;
static NSDateFormatter *gREDateFmt = nil;
static NSInteger gCntURLSession = 0, gCntJSON = 0, gCntNodes = 0;
static NSInteger gCntAdStripped = 0, gCntDrawerTables = 0, gCntSectionsHidden = 0;
static NSInteger gCntDrawerRowsHidden = 0;
static NSInteger gCntTrackersBlocked = 0, gCntReviewBlocked = 0, gCntViewsHidden = 0;
static NSInteger gCntHooksInstalled = 0;
static NSInteger gCntAdNodesRemoved = 0;

// 我们自己的设置页 / 诊断页正在前台时 > 0。
// 此时绝不能再往任何导航栏注入「增强设置」入口 —— 否则会出现
// 「进了增强设置，右上角又有一个增强设置」的嵌套按钮。
static NSInteger gREOwnUIVisible = 0;

static void RELog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[RedditEnhancer] %@", msg);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gREDateFmt = [[NSDateFormatter alloc] init];
        gREDateFmt.dateFormat = @"HH:mm:ss";
        gRELog = [NSMutableArray array];
        gRELogLock = [[NSObject alloc] init];
    });

    @synchronized (gRELogLock) {
        NSString *line = [NSString stringWithFormat:@"%@  %@",
                          [gREDateFmt stringFromDate:[NSDate date]], msg];
        [gRELog addObject:line];
        while (gRELog.count > 240) [gRELog removeObjectAtIndex:0];
    }
}

// 同一 key 只记一次（诊断用：把抽屉里真实出现的类名/标题都留档）
static void RELogOnce(NSString *key, NSString *fmt, ...) {
    static NSMutableSet *seen = nil;
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seen = [NSMutableSet set];
        lock = [[NSObject alloc] init];
    });
    @synchronized (lock) {
        if (key.length == 0 || seen.count > 200 || [seen containsObject:key]) return;
        [seen addObject:key];
    }
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    RELog(@"%@", msg);
}

// ---------------------------------------------------------------------------
// 文案 / 标识匹配
// ---------------------------------------------------------------------------
static BOOL REMatchesAny(NSString *hay, NSArray<NSString *> *needles) {
    if (![hay isKindOfClass:NSString.class] || hay.length == 0) return NO;
    NSString *low = hay.lowercaseString;
    for (NSString *n in needles) {
        if ([low containsString:n]) return YES;
    }
    return NO;
}

// 抽屉里「Reddit 上的游戏」相关文案 / 标识（全部小写）
static NSArray<NSString *> *REGamesMarkers(void) {
    return @[@"gamesonreddit", @"games on reddit", @"discovermoregames",
             @"discover more games", @"featuredgame", @"drawergames",
             @"devvit", @"游戏"];
}

// 抽屉里「资源 / About / 规则 / 隐私 / 协议」相关文案 / 标识（全部小写）
// 注意：这里的词也会拿去匹配 cell 文案，所以只放「不可能出现在正常社区名里」的词。
// 像 "rules" / "about" / "privacy" 这种裸词一律不放 —— r/privacy、r/About 这类
// 真实社区会被误判，进而把用户订阅列表整段折掉（v5 的事故点）。
static NSArray<NSString *> *REResourceMarkers(void) {
    return @[@"resourcessection", @"resources", @"资源",
             // 广告合作 / 会员升级：都归到「资源」开关下
             @"advertise", @"广告合作",
             @"trypro", @"try pro", @"tryredditpro", @"reddit pro", @"protitle",
             @"premiumtitle", @"reddit premium", @"premiumupsell",
             @"prolinks", @"earntitle", @"vaulttitle",
             // About 分区：关于 / 规则 / 隐私政策 / 用户协议 / 版权声明
             @"aboutsection", @"rulestitle", @"privacypolicy", @"useragreement",
             @"osainformation", @"acknowledgements", @"impressum",
             @"helpcenter", @"help center", @"关于 reddit", @"关于reddit",
             @"隐私政策", @"用户协议", @"服务条款", @"帮助中心", @"辅助功能",
             @"版权", @"鸣谢"];
}

// 抽屉里「趋势 / Trending」相关（独立的开关）
static NSArray<NSString *> *RETrendingMarkers(void) {
    return @[@"trendstitle", @"trending", @"trends", @"趋势"];
}

// 搜索栏 / 卡片里的 Reddit Answers（AI 入口）
static NSArray<NSString *> *REAnswersMarkerList(void) {
    return @[@"askanswers", @"answersproductcard", @"answershero",
             @"answerspreview", @"answersdiscoveryunit"];
}

// 广告相关无障碍标识（取自二进制里的 UIIdentifier rawValue，全小写）
static NSArray<NSString *> *REAdIdentifiers(void) {
    return @[@"redditfeedpromotedpostcell",      // 信息流推广帖
             @"redditpostpromotede",             // 推广帖内部元素（E11/E12…）
             @"redditpostade",                   // 广告浮层
             @"redditpostconvoad",                // 评论区会话广告
             @"redditpostcommentad",              // 评论里的广告内容
             @"redditpromotedcommunitypost",      // 推广社区帖
             @"adpromotedcommunitypostcell",      // 推广社区 cell
             @"conversationad",                   // 会话广告通用
             @"hiddenadpost",                     // 「已隐藏广告」占位块
             @"redditadsamaad",                   // AMA 广告状态条
             @"redditpromotepostentrypoint"];     // 「推广你的帖子」入口
}

static BOOL REStringIsGamePromo(NSString *s) {
    return REBool(kREHideDrawerGames, YES) && REMatchesAny(s, REGamesMarkers());
}

static BOOL REStringIsResourcePromo(NSString *s) {
    return REBool(kREHideDrawerResources, YES) && REMatchesAny(s, REResourceMarkers());
}

static BOOL REStringIsTrendingPromo(NSString *s) {
    return REBool(kREHideTrending, YES) && REMatchesAny(s, RETrendingMarkers());
}

static BOOL REStringIsAnswersPromo(NSString *s) {
    return REBool(kREHideAnswers, YES) && REMatchesAny(s, REAnswersMarkerList());
}

static BOOL REStringIsPromo(NSString *s) {
    return REStringIsGamePromo(s) || REStringIsResourcePromo(s) ||
           REStringIsTrendingPromo(s) || REStringIsAnswersPromo(s);
}

// 分区标题做「整串匹配」，避免误伤普通社区名
static NSSet<NSString *> *REPromoTitles(void) {
    static NSSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"resources", @"reddit pro", @"try pro", @"try reddit pro",
            @"reddit premium", @"premium", @"earn", @"vault", @"trends",
            @"trending", @"trending today", @"reddit answers", @"answers",
            @"advertise on reddit",
            // About 分区（英文 / 中文两套本地化文案都收）
            @"about", @"about reddit", @"reddit rules", @"rules",
            @"privacy policy", @"user agreement", @"terms of service",
            @"accessibility", @"help center", @"acknowledgements",
            @"impressum", @"osa information",
            @"关于", @"关于 reddit", @"关于reddit", @"规则", @"社区规则",
            @"隐私政策", @"隐私权政策", @"用户协议", @"服务条款",
            @"辅助功能", @"帮助中心", @"鸣谢", @"版权声明",
            @"games on reddit", @"discover more games", @"资源", @"游戏"
        ]];
    });
    return set;
}

// 标题命中「整串匹配表」即认定为推广分区，具体归哪个开关控制：
// 游戏 → 游戏开关；趋势 → 趋势开关；Answers → Answers 开关；其余 → 资源开关。
static BOOL RETitleIsPromo(NSString *title) {
    if (![title isKindOfClass:NSString.class] || title.length == 0) return NO;
    NSString *low = [title.lowercaseString
                     stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![REPromoTitles() containsObject:low]) return NO;

    if ([low containsString:@"game"] || [low containsString:@"游戏"]) {
        return REBool(kREHideDrawerGames, YES);
    }
    if ([low containsString:@"trend"]) {
        return REBool(kREHideTrending, YES);
    }
    if ([low containsString:@"answer"]) {
        return REBool(kREHideAnswers, YES);
    }
    return REBool(kREHideDrawerResources, YES);
}

// 递归读取视图树里的文案（Swift 自绘 cell 的类名往往没有信息量，
// 但里面的 UILabel 一定有文字）
static BOOL REScanTextInView(UIView *view, NSUInteger depth,
                             BOOL (^predicate)(NSString *)) {
    if (!view || depth > 3) return NO;
    if ([view isKindOfClass:[UILabel class]]) {
        if (predicate(((UILabel *)view).text)) return YES;
    } else if ([view isKindOfClass:[UIButton class]]) {
        if (predicate([(UIButton *)view titleForState:UIControlStateNormal])) return YES;
    } else if ([view isKindOfClass:[UITextField class]]) {
        if (predicate(((UITextField *)view).text)) return YES;
    }
    for (UIView *sub in view.subviews) {
        if (REScanTextInView(sub, depth + 1, predicate)) return YES;
    }
    return NO;
}

// SwiftUI 自绘的 cell 里没有 UILabel，文案挂在宿主视图的 accessibilityLabel 上，
// 上面的 REScanTextInView 完全看不到 → 这类行会漏掉。再顺着标签扫一遍。
// 只在抽屉 cell 上调用（数量很小），深度限制 6 层。
static BOOL REScanA11yInView(UIView *view, NSUInteger depth) {
    if (!view || depth > 6) return NO;
    if (REStringIsPromo(view.accessibilityLabel)) return YES;
    if (REStringIsPromo(view.accessibilityIdentifier)) return YES;
    for (UIView *sub in view.subviews) {
        if (REScanA11yInView(sub, depth + 1)) return YES;
    }
    return NO;
}

// 真正的广告 cell（推广帖 / 推广社区 / 会话广告）——这类宁可留一条空白也要藏掉。
// 「关于 / 规则 / 隐私政策 / 用户协议」这类不走逐行隐藏，统一走整段折叠，
// 否则会留下「一大块空白」（v5.1 的问题）。
static BOOL REViewIsAdCell(UIView *view) {
    if (!view) return NO;
    NSString *cls = NSStringFromClass([view class]).lowercaseString;
    if ([cls containsString:@"promoted"] || [cls containsString:@"adcell"] ||
        [cls containsString:@"adpost"] || [cls containsString:@"conversationad"]) {
        return YES;
    }
    return REMatchesAny(view.accessibilityIdentifier, REAdIdentifiers());
}

// 判断一个 cell / header 视图是否是抽屉推广位
static BOOL REViewIsPromo(UIView *view) {
    if (!view) return NO;

    NSString *cls   = NSStringFromClass([view class]);
    NSString *ident = view.accessibilityIdentifier;
    NSString *label = view.accessibilityLabel;

    // 1) 类名（最可靠：CommunityDrawerGamesOnRedditCell / GamesOnRedditFeaturedView）
    if (REStringIsGamePromo(cls)) return YES;
    if (REStringIsResourcePromo(cls)) return YES;

    // 2) accessibilityIdentifier / accessibilityLabel（UIIdentifier 的 rawValue）
    if (REStringIsPromo(ident)) return YES;
    if (REStringIsPromo(label)) return YES;

    // 3) 视图树文案（UIKit 自绘 cell）
    BOOL (^pred)(NSString *) = ^BOOL(NSString *s) { return REStringIsPromo(s); };
    if (REScanTextInView(view, 0, pred)) return YES;

    // 4) 视图树上的无障碍标签（SwiftUI 自绘 cell 的唯一出口）
    return REScanA11yInView(view, 0);
}

// ---------------------------------------------------------------------------
// 抽屉白名单（v6）
// 只保留：热门 / 新闻 / 最新 / 创建社区 / 最近访问 / 你的社区，其余整行移除。
// 依据 2026.46.0 二进制里 UIIdentifier 的 rawValue（后缀 ACvau 是混淆后缀）：
//   保留  …E17DrawerPopularItem / …E14DrawerNewsItem / …E16DrawerLatestItem
//         …e12DrawerCreateE4Item / …E25DrawerRecentlyVisitedItem
//         …E29DrawerSubscribedSubredditItem（「你的社区」里每个社区）
//   分区  …E28DrawerRecentlyVisitedSection / …E28DrawerYourCommunitiesSection
//   移除  Discover / Favorites / Following / Moderating / Events / CustomFeeds /
//         Games / Resources / About / Trends / 登录与管理入口 …
// ---------------------------------------------------------------------------

// 取视图里第一段可见文字（SwiftUI 自绘 cell 的文案挂在 accessibilityLabel 上）
static NSString *REFirstTextInView(UIView *view, NSUInteger depth) {
    if (!view || depth > 4) return nil;
    if (view.accessibilityLabel.length) return view.accessibilityLabel;
    if ([view isKindOfClass:[UILabel class]] && ((UILabel *)view).text.length) {
        return ((UILabel *)view).text;
    }
    if ([view isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)view titleForState:UIControlStateNormal];
        if (t.length) return t;
    }
    for (UIView *sub in view.subviews) {
        NSString *t = REFirstTextInView(sub, depth + 1);
        if (t.length) return t;
    }
    return nil;
}

// 要保留的行（小写子串）。标识和文案都能匹配。
static NSArray<NSString *> *REDrawerKeepRowMarkers(void) {
    return @[@"drawerpopularitem", @"popularitem", @"drawernewsitem", @"newsitem",
             @"drawerlatestitem", @"latestitem",
             @"drawercreate", @"createcommunity", @"createcommunityitem",
             @"recentlyvisited",
             @"subscribedsubreddititem", @"yourcommunities",
             // 未登录时的登录入口：不能删，否则无法登录
             @"loginitem",
             // 中文本地化文案兜底
             @"热门", @"新闻", @"最新", @"创建社区", @"最近访问", @"你的社区"];
}

// 已知的「垃圾行」文案（只在拿不到标识时才用来兜底判断）
static NSArray<NSString *> *REDrawerJunkRowTexts(void) {
    return @[@"发现社区", @"自定义信息流", @"收藏", @"关注", @"我管理的", @"版主",
             @"活动", @"游戏", @"资源", @"关于", @"规则", @"隐私", @"用户协议",
             @"服务条款", @"帮助", @"辅助功能", @"鸣谢",
             @"discover communities", @"custom feeds", @"favorites", @"following",
             @"moderating", @"events", @"games on reddit", @"resources", @"about",
             @"reddit rules", @"privacy policy", @"user agreement", @"reddit pro",
             @"premium", @"vault", @"earn", @"advertise", @"answers", @"trends"];
}

// 分区标题里出现这些词 → 一定不要（先判）
static NSArray<NSString *> *REDrawerJunkTitleWords(void) {
    return @[@"关于", @"规则", @"隐私", @"协议", @"条款", @"帮助", @"辅助", @"鸣谢",
             @"版权", @"资源", @"游戏", @"趋势", @"发现", @"收藏", @"关注",
             @"我管理的", @"版主", @"活动", @"自定义",
             @"about", @"rules", @"privacy", @"agreement", @"terms", @"help",
             @"acknowledg", @"impressum", @"resources", @"game", @"trend",
             @"discover", @"favorit", @"following", @"moderating", @"event",
             @"custom", @"pro", @"premium", @"vault", @"earn", @"advertise",
             @"answers", @"osa"];
}

// 分区标题里出现这些词 → 保留
static NSArray<NSString *> *REDrawerKeepTitleWords(void) {
    return @[@"热门", @"新闻", @"最新", @"创建社区", @"最近访问", @"你的社区",
             @"社区", @"订阅",
             @"popular", @"news", @"latest", @"create community",
             @"recently visited", @"your communities", @"communities",
             @"subscribed", @"recent"];
}

// 抽屉里的一行长什么样：标识里同时带 drawer 和 item/cell
static BOOL REStringLooksLikeDrawerRow(NSString *s) {
    if (![s isKindOfClass:NSString.class] || s.length == 0) return NO;
    NSString *low = s.lowercaseString;
    if (![low containsString:@"drawer"]) return NO;
    return [low containsString:@"item"] || [low containsString:@"cell"];
}

// 这一行要不要去掉
static BOOL REDrawerRowShouldBlock(NSString *ident, NSString *text) {
    if (!REBool(kREDrawerWhitelist, YES)) return NO;
    NSString *lowIdent = [ident isKindOfClass:NSString.class] ? ident.lowercaseString : @"";

    if (REStringLooksLikeDrawerRow(lowIdent)) {
        return !REMatchesAny(lowIdent, REDrawerKeepRowMarkers());
    }

    // 拿不到标识时才看文案：认识的保留文案 → 留；认识的垃圾文案 → 去；都不认识 → 留
    if (lowIdent.length == 0 && [text isKindOfClass:NSString.class] && text.length) {
        NSString *lowText = text.lowercaseString;
        if (REMatchesAny(lowText, REDrawerKeepRowMarkers())) return NO;
        if (REMatchesAny(lowText, REDrawerJunkRowTexts())) return YES;
    }
    return NO;
}

// 这个分区标题要不要保留
static BOOL REDrawerTitleShouldKeep(NSString *title) {
    if (![title isKindOfClass:NSString.class] || title.length == 0) return YES;
    NSString *low = [title.lowercaseString
                     stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (low.length == 0) return YES;
    if (REMatchesAny(low, REDrawerJunkTitleWords())) return NO;
    return REMatchesAny(low, REDrawerKeepTitleWords());
}

// ---------------------------------------------------------------------------
// Swizzle 基础设施（任意类；原始 IMP 按 "类名|方法名" 存表）
// ---------------------------------------------------------------------------
static NSMutableDictionary<NSString *, NSValue *> *gREOrigIMPs = nil;
static NSMutableSet<NSString *> *gRESwizzled = nil;

static void REInitSwizzleTables(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gREOrigIMPs = [NSMutableDictionary dictionary];
        gRESwizzled = [NSMutableSet set];
    });
}

// 从 self 的真实类开始向上找原始 IMP（继承来的 hook 也能回落到父类实现）
static IMP REOriIMP(id self, SEL cmd) {
    Class c = object_getClass(self);
    for (int i = 0; c && i < 12; i++, c = class_getSuperclass(c)) {
        NSString *key = [NSString stringWithFormat:@"%s|%s",
                         class_getName(c), sel_getName(cmd)];
        NSValue *value = gREOrigIMPs[key];
        if (value) return (IMP)value.pointerValue;
    }
    return NULL;
}

static void RESwizzleClass(Class cls, SEL sel, IMP hook) {
    if (!cls || !sel || !hook) return;
    REInitSwizzleTables();

    NSString *key = [NSString stringWithFormat:@"%s|%s",
                     class_getName(cls), sel_getName(sel)];
    if ([gRESwizzled containsObject:key]) return;

    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);

    if (!class_addMethod(cls, sel, hook, types)) {
        // 该类自己实现了此方法 → 直接替换它的实现
        Method own = class_getInstanceMethod(cls, sel);
        if (!own) return;
        method_setImplementation(own, hook);
    }
    gREOrigIMPs[key] = [NSValue valueWithPointer:orig];
    [gRESwizzled addObject:key];
    gCntHooksInstalled++;
}

static void RESwizzleInstance(id obj, SEL sel, IMP hook) {
    if (!obj) return;
    Class cls = object_getClass(obj);
    if (!cls) return;
    RESwizzleClass(cls, sel, hook);
}

// ---------------------------------------------------------------------------
// 抽屉表格：分区过滤
// ---------------------------------------------------------------------------
static char kREHiddenSectionsKey;
static char kRENudgePendingKey;
static char kREFiltersInstalledKey;

// 历史教训（v5）：这里曾用「dataSource 类名 → 已隐藏分区下标」的跨实例缓存来
// 消除首次打开的一瞬闪现。但抽屉的分区顺序会变（登录态、游戏服务开关、
// A/B 实验都会增减分区），缓存的下标一旦错位，就会折掉别的分区
// ——表现为「抽屉里一大块空白，还影响了正常功能」。所以现在只按
// 当前这个 tableView 的实时探测结果来折，绝不复用下标。

static NSString *RETableClassKey(UITableView *tv) {
    id ds = tv.dataSource;
    if (!ds) return @"?";
    return NSStringFromClass(object_getClass(ds)) ?: @"?";
}

// 只对我们确认过的抽屉表格动手；别的界面即使共用同一个 dataSource 类，
// hook 也只是原样转发（DiffableDataSource 之类的系统类常被全局共用）
static BOOL RETableIsDrawer(UITableView *tv) {
    return tv && objc_getAssociatedObject(tv, &kREFiltersInstalledKey) != nil;
}

// 隐藏分区集合挂在 tableView 上（dataSource 和 delegate 是两个对象，
// 状态必须挂在公共的 tableView 上，否则高度和行数查询看不到同一份数据）
static NSMutableIndexSet *RETableHiddenSet(UITableView *tv, BOOL create) {
    if (!tv) return nil;
    NSMutableIndexSet *set = objc_getAssociatedObject(tv, &kREHiddenSectionsKey);
    if (!set && create) {
        set = [NSMutableIndexSet indexSet];
        objc_setAssociatedObject(tv, &kREHiddenSectionsKey, set,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}

// 让表格重新询问行高。
// 注意：这里绝对不能 reloadData —— 抽屉是 diffable data source，
// reloadData 会让 UIKit 的内部快照和真实行数脱钩，下一次 applySnapshot 就崩。
// beginUpdates/endUpdates 是零变更批次，只触发高度重算，不会改行数。
static void RELayoutNudge(UITableView *tv) {
    if (!tv) return;
    if (objc_getAssociatedObject(tv, &kRENudgePendingKey)) return;
    objc_setAssociatedObject(tv, &kRENudgePendingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UITableView *weakTV = tv;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *strongTV = weakTV;
        if (!strongTV) return;
        objc_setAssociatedObject(strongTV, &kRENudgePendingKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            [strongTV beginUpdates];
            [strongTV endUpdates];
        } @catch (NSException *e) {
            RELog(@"重算行高被拒（忽略）：%@", e.reason);
        }
    });
}

static char kRESectionCountKey;
static char kRESectionHitKey;

// 记录「这个分区里有几行命中了推广特征」。
// 单行命中不足以折掉一个大分区（可能是误匹配），多行命中才说明整段就是推广区
// ——「关于」分区有 10 行左右（规则/隐私/协议/辅助功能/帮助/鸣谢…），
// 旧版 10 行的安全阀会把它判成「整块列表」而拒绝折叠，于是只剩一堆被隐藏的
// 空行 = 用户看到的那一大块空白。
static NSInteger REBumpSectionHit(UITableView *tv, NSInteger section) {
    if (!tv) return 0;
    NSMutableDictionary<NSNumber *, NSNumber *> *hits =
        objc_getAssociatedObject(tv, &kRESectionHitKey);
    if (!hits) {
        hits = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(tv, &kRESectionHitKey, hits,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber *key = @(section);
    NSInteger next = hits[key].integerValue + 1;
    hits[key] = @(next);
    return next;
}

// 抽屉重新加载后分区数量可能变（登录、游戏服务、A/B 实验都会增减分区），
// 一旦数量变了，之前记下的下标就不可信 → 立刻清空，重新探测。
static void REValidateHiddenSet(UITableView *tv) {
    NSMutableIndexSet *set = RETableHiddenSet(tv, NO);
    if (!set || set.count == 0) return;   // 没有折叠记录时零开销
    NSNumber *expected = objc_getAssociatedObject(tv, &kRESectionCountKey);
    if (expected && expected.integerValue != (NSInteger)tv.numberOfSections) {
        [set removeAllIndexes];
        objc_setAssociatedObject(tv, &kRESectionCountKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tv, &kRESectionHitKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// honorValve = YES  ：黑名单命中（可能误判），行数太多时放弃折叠
// honorValve = NO   ：白名单判定（明确要删），一律折叠
// 返回 YES 表示「这个分区确实被折掉了」——调用方据此决定要不要隐藏视图，
// 避免安全阀拦下之后还留一个空白洞。
static BOOL REMarkSectionHiddenEx(UITableView *tv, NSInteger section,
                                  NSString *reason, BOOL honorValve) {
    if (!tv || section < 0) return NO;
    NSMutableIndexSet *set = RETableHiddenSet(tv, YES);
    if (!set) return NO;
    if ([set containsIndex:section]) return YES;

    // 安全阀：分区行数过多说明它是「整块抽屉列表」而不是独立的推广分区，
    // 这时放弃折叠，避免因为一个 cell 文案匹配把整个侧边栏藏掉。
    // 但如果同一个分区里已经有多行命中推广特征，那就不是误匹配 —— 允许折叠。
    if (honorValve) {
        NSInteger hits = REBumpSectionHit(tv, section);
        id ds = tv.dataSource;
        if (ds) {
            SEL sel = @selector(tableView:numberOfRowsInSection:);
            if ([ds respondsToSelector:sel]) {
                NSInteger (*fn)(id, SEL, UITableView *, NSInteger) =
                    (void *)[ds methodForSelector:sel];
                if (fn) {
                    NSInteger rows = fn(ds, sel, tv, section);
                    if (rows > 14 && hits < 3) {
                        RELog(@"分区 #%ld 有 %ld 行、命中 %ld 次，暂不折叠（%@）",
                              (long)section, (long)rows, (long)hits, reason);
                        return NO;
                    }
                }
            }
        }
    }

    [set addIndex:section];
    objc_setAssociatedObject(tv, &kRESectionCountKey, @(tv.numberOfSections),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gCntSectionsHidden++;

    RELog(@"折叠抽屉分区 #%ld（%@）ds=%@", (long)section, reason, RETableClassKey(tv));

    // 已经显示出来的 cell 先直接藏掉，避免高度重算前闪一下
    for (UITableViewCell *cell in tv.visibleCells) {
        NSIndexPath *ip = [tv indexPathForCell:cell];
        if (ip && ip.section == section) {
            cell.hidden = YES;
            cell.alpha = 0.0;
        }
    }

    RELayoutNudge(tv);
    return YES;
}

static BOOL REMarkSectionHidden(UITableView *tv, NSInteger section, NSString *reason) {
    return REMarkSectionHiddenEx(tv, section, reason, YES);
}

// ---------------------------------------------------------------------------
// 白名单状态（行级）
// 行状态按 tableView 存；结构（分区数/总行数）一变立刻清空，避免下标错位
// —— v5 用「类名 → 分区下标」跨实例缓存时串过位，把正常分区折掉了。
// ---------------------------------------------------------------------------
static char kREBlockedRowsKey;
static char kREKeptSectionsKey;
static char kREDrawerSigKey;

// 被删的行：section -> 行号集合。用 NSNumber 做键（小整数是 tagged pointer，
// 不额外分配）；行高查询每帧都会走这里，尽量别在热路径上建字符串。
static NSMutableDictionary<NSNumber *, NSMutableIndexSet *> *
REBlockedRowsMap(UITableView *tv, BOOL create) {
    if (!tv) return nil;
    NSMutableDictionary *m = objc_getAssociatedObject(tv, &kREBlockedRowsKey);
    if (!m && create) {
        m = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(tv, &kREBlockedRowsKey, m,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return m;
}

static NSMutableIndexSet *REBlockedRowsInSection(UITableView *tv, NSInteger section, BOOL create) {
    NSMutableDictionary *m = REBlockedRowsMap(tv, create);
    if (!m) return nil;
    NSNumber *key = @(section);
    NSMutableIndexSet *rows = m[key];
    if (!rows && create) {
        rows = [NSMutableIndexSet indexSet];
        m[key] = rows;
    }
    return rows;
}

static NSMutableIndexSet *REKeptSections(UITableView *tv, BOOL create) {
    if (!tv) return nil;
    NSMutableIndexSet *set = objc_getAssociatedObject(tv, &kREKeptSectionsKey);
    if (!set && create) {
        set = [NSMutableIndexSet indexSet];
        objc_setAssociatedObject(tv, &kREKeptSectionsKey, set,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}

// 结构指纹（分区数 + 总行数）。结构一变，之前记的行号就不可信 → 全部清空。
static long REDrawerSignatureValue(UITableView *tv) {
    NSInteger sections = (NSInteger)tv.numberOfSections;
    long total = 0;
    for (NSInteger i = 0; i < sections; i++) {
        total += (long)[tv numberOfRowsInSection:i];
    }
    return (long)sections * 100000L + total;
}

static void REValidateDrawerState(UITableView *tv) {
    if (!tv) return;
    long sig = REDrawerSignatureValue(tv);
    NSNumber *old = objc_getAssociatedObject(tv, &kREDrawerSigKey);
    if (old && old.longValue != sig) {
        objc_setAssociatedObject(tv, &kREBlockedRowsKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tv, &kREKeptSectionsKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!old || old.longValue != sig) {
        objc_setAssociatedObject(tv, &kREDrawerSigKey, @(sig),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL REIsRowBlocked(UITableView *tv, NSIndexPath *ip) {
    NSMutableIndexSet *rows = REBlockedRowsInSection(tv, ip.section, NO);
    return rows != nil && [rows containsIndex:ip.row];
}

static void REBlockRow(UITableView *tv, NSIndexPath *ip, NSString *reason) {
    if (!tv || !ip) return;
    NSMutableIndexSet *rows = REBlockedRowsInSection(tv, ip.section, YES);
    if (!rows || [rows containsIndex:ip.row]) return;
    [rows addIndex:ip.row];
    gCntDrawerRowsHidden++;
    RELogOnce([NSString stringWithFormat:@"row|%ld.%ld", (long)ip.section, (long)ip.row],
              @"隐藏抽屉行 section=%ld row=%ld ← %@",
              (long)ip.section, (long)ip.row, reason);
    RELayoutNudge(tv);
}

static void REUnblockRow(UITableView *tv, NSIndexPath *ip) {
    NSMutableIndexSet *rows = REBlockedRowsInSection(tv, ip.section, NO);
    if (!rows || ![rows containsIndex:ip.row]) return;
    [rows removeIndex:ip.row];
    RELayoutNudge(tv);
}

// 统一裁决：这一行留还是删。返回 YES 表示要隐藏。
// 1) 白名单：整行移除（高度归零，不留空白）
// 2) 真广告：逐行隐藏
// 3) 旧的黑名单推广 cell：跟着整段折叠走
static BOOL REApplyRowPolicy(UITableView *tv, UITableViewCell *cell, NSIndexPath *ip) {
    if (!tv || !cell || !ip) return NO;

    NSString *ident = cell.accessibilityIdentifier;
    NSString *text  = REFirstTextInView(cell, 0);

    if (REDrawerRowShouldBlock(ident, text)) {
        REBlockRow(tv, ip, ident.length ? ident : text);
        return YES;
    }

    // 这一行要保留，但它所在的分区被白名单按标题折掉了 → 解折（自愈）
    NSMutableIndexSet *hidden = RETableHiddenSet(tv, NO);
    if (hidden && [hidden containsIndex:ip.section]) {
        [REKeptSections(tv, YES) addIndex:ip.section];
        [hidden removeIndex:ip.section];
        RELog(@"分区 #%ld 里出现了保留行，取消折叠（%@）",
              (long)ip.section, ident.length ? ident : text);
        RELayoutNudge(tv);
    }
    REUnblockRow(tv, ip);

    if (REViewIsAdCell(cell)) return YES;

    if (REViewIsPromo(cell)) {
        if (REMarkSectionHidden(tv, ip.section, @"推广 cell")) return YES;
    }
    return NO;
}

// 分区标题 / 分区头视图 → 决定要不要整段折叠
static void REApplySectionPolicy(UITableView *tv, NSInteger section,
                                 NSString *title, NSString *headerIdent) {
    if (!tv || section < 0) return;
    if (!REBool(kREDrawerWhitelist, YES)) return;

    NSMutableIndexSet *kept = REKeptSections(tv, NO);
    if (kept && [kept containsIndex:section]) return;   // 里面有保留行，别折

    // 分区头的无障碍标识带 drawer 的，直接按黑名单
    NSString *lowIdent = [headerIdent isKindOfClass:NSString.class]
                         ? headerIdent.lowercaseString : @"";
    if (lowIdent.length) {
        if (REStringLooksLikeDrawerRow(lowIdent) &&
            REMatchesAny(lowIdent, @[@"game", @"gamecell", @"discovermoregames"])) {
            REMarkSectionHiddenEx(tv, section, @"白名单：游戏分区头", NO);
            return;
        }
        if (REMatchesAny(lowIdent, @[@"aboutsection", @"resourcessection",
                                     @"trendstitle", @"discoversection",
                                     @"discoverysection", @"favoritessection",
                                     @"followingsection", @"moderatingsection",
                                     @"eventssection", @"customfeeds"])) {
            REMarkSectionHiddenEx(tv, section, @"白名单：分区标识", NO);
            return;
        }
    }

    if ([title isKindOfClass:NSString.class] && title.length) {
        if (!REDrawerTitleShouldKeep(title)) {
            REMarkSectionHiddenEx(tv, section, @"白名单：标题不在保留列表", NO);
        }
        return;
    }

    // 没有标题也没有标识 → 不动（顶部那一组行由行级规则逐个裁决）
}


// --- 具体 hook ---
// 注意：没有 numberOfRowsInSection / numberOfSections 的 hook。
// 抽屉是 diffable data source，行数一旦被改写，UIKit 会抛
// NSInternalInconsistencyException（Invalid update）直接 abort —— 这是 v3 崩溃点。

static BOOL RESectionIsHidden(UITableView *tv, NSInteger section);

static CGFloat REHookHeightForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *indexPath) {
    REValidateHiddenSet(tv);
    REValidateDrawerState(tv);
    NSMutableIndexSet *set = RETableHiddenSet(tv, NO);
    if (set && [set containsIndex:indexPath.section]) return 0.0;
    // 白名单判定要删的行：高度归零 = 真正移除（不留空白，也不碰行数）
    if (REIsRowBlocked(tv, indexPath)) return 0.0;

    CGFloat (*orig)(id, SEL, UITableView *, NSIndexPath *) = (void *)REOriIMP(self, _cmd);
    if (orig) return orig(self, _cmd, tv, indexPath);
    // 原来没有实现这个方法（cell 自撑高）：保持表格自身配置，不要硬塞自动高度
    return tv.rowHeight > 0 ? tv.rowHeight : UITableViewAutomaticDimension;
}

// 表格若用估算行高，被删的行会先按估算值占位（表现为一条空白），
// 这里一并归零，布局时就不会闪出空白条。
static CGFloat REHookEstimatedHeightForRow(id self, SEL _cmd, UITableView *tv,
                                           NSIndexPath *indexPath) {
    NSMutableIndexSet *set = RETableHiddenSet(tv, NO);
    if (set && [set containsIndex:indexPath.section]) return 0.0;
    if (REIsRowBlocked(tv, indexPath)) return 0.0;

    CGFloat (*orig)(id, SEL, UITableView *, NSIndexPath *) = (void *)REOriIMP(self, _cmd);
    if (orig) return orig(self, _cmd, tv, indexPath);
    return tv.estimatedRowHeight > 0 ? tv.estimatedRowHeight : 0.0;
}


static CGFloat REHookHeightForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    REValidateHiddenSet(tv);
    NSMutableIndexSet *set = RETableHiddenSet(tv, NO);
    if (set && [set containsIndex:section]) return 0.0;

    CGFloat (*orig)(id, SEL, UITableView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    if (orig) return orig(self, _cmd, tv, section);
    return tv.sectionHeaderHeight;
}

// 分区被折掉之后，footer（「关于」下面那行版权/版本说明之类的留白）也必须归零，
// 否则会剩下一大块空白 —— 这就是用户反馈的「抽屉里一大块空白」的另一半。
static CGFloat REHookHeightForFooter(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    REValidateHiddenSet(tv);
    NSMutableIndexSet *set = RETableHiddenSet(tv, NO);
    if (set && [set containsIndex:section]) return 0.0;

    CGFloat (*orig)(id, SEL, UITableView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    if (orig) return orig(self, _cmd, tv, section);
    return tv.sectionFooterHeight;
}

static UIView *REHookViewForFooter(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    REValidateHiddenSet(tv);
    NSMutableIndexSet *set = RETableHiddenSet(tv, NO);
    if (set && [set containsIndex:section]) return nil;

    UIView *(*orig)(id, SEL, UITableView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    return orig ? orig(self, _cmd, tv, section) : nil;
}

static NSString *REHookTitleForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSString *(*orig)(id, SEL, UITableView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    NSString *title = orig ? orig(self, _cmd, tv, section) : nil;
    if ([title isKindOfClass:[NSString class]] && title.length > 0) {
        RELogOnce([@"hdr|" stringByAppendingString:title], @"抽屉分区标题：%@", title);
    }
    if (!RETableIsDrawer(tv)) return title;

    if (REBool(kREDrawerWhitelist, YES)) {
        REApplySectionPolicy(tv, section, title, nil);
        if (RESectionIsHidden(tv, section)) return nil;
        return title;
    }

    if (RETitleIsPromo(title)) {
        REMarkSectionHidden(tv, section, @"分区标题");
        return nil;
    }
    return title;
}

// 只有分区真的被折叠了才隐藏视图，避免安全阀拦下之后留下空白洞
static BOOL RESectionIsHidden(UITableView *tv, NSInteger section) {
    NSMutableIndexSet *set = RETableHiddenSet(tv, NO);
    return set != nil && [set containsIndex:section];
}

static UIView *REHookViewForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    UIView *(*orig)(id, SEL, UITableView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    UIView *view = orig ? orig(self, _cmd, tv, section) : nil;
    if (!RETableIsDrawer(tv) || !view) return view;

    if (REBool(kREDrawerWhitelist, YES)) {
        REApplySectionPolicy(tv, section, REFirstTextInView(view, 0),
                            view.accessibilityIdentifier);
        if (RESectionIsHidden(tv, section)) {
            view.hidden = YES;
            return nil;
        }
        return view;
    }

    if (REViewIsPromo(view)) {
        REMarkSectionHidden(tv, section, @"分区头视图");
        if (RESectionIsHidden(tv, section)) {
            view.hidden = YES;
            return nil;
        }
    }
    return view;
}

static UITableViewCell *REHookCellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *indexPath) {
    UITableViewCell *(*orig)(id, SEL, UITableView *, NSIndexPath *) = (void *)REOriIMP(self, _cmd);
    UITableViewCell *cell = orig ? orig(self, _cmd, tv, indexPath) : nil;
    if (!cell || !RETableIsDrawer(tv)) return cell;

    REValidateDrawerState(tv);

    // 留档：抽屉里真实出现的 cell 类名 + 无障碍标识，便于下次精确匹配
    NSString *cls = NSStringFromClass([cell class]) ?: @"?";
    NSString *ident = cell.accessibilityIdentifier ?: @"";
    RELogOnce([NSString stringWithFormat:@"cell|%@|%@|%ld", cls, ident, (long)indexPath.section],
              @"抽屉 cell：%@ ident=%@ section=%ld",
              cls, ident.length ? ident : @"(无)", (long)indexPath.section);

    // alpha 必须一并还原，否则复用时会变透明（看着就是一块空白）
    BOOL hide = REApplyRowPolicy(tv, cell, indexPath);
    cell.hidden = hide;
    cell.alpha = hide ? 0.0 : 1.0;
    return cell;
}

static void REHookWillDisplayCell(id self, SEL _cmd, UITableView *tv,
                                  UITableViewCell *cell, NSIndexPath *indexPath) {
    void (*orig)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *) =
        (void *)REOriIMP(self, _cmd);
    if (orig) orig(self, _cmd, tv, cell, indexPath);

    if (!RETableIsDrawer(tv) || !cell) return;
    BOOL hide = REApplyRowPolicy(tv, cell, indexPath);
    cell.hidden = hide;
    cell.alpha = hide ? 0.0 : 1.0;
}

static void REHookWillDisplayHeader(id self, SEL _cmd, UITableView *tv,
                                    UIView *view, NSInteger section) {
    void (*orig)(id, SEL, UITableView *, UIView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    if (orig) orig(self, _cmd, tv, view, section);

    if (!RETableIsDrawer(tv) || !view) return;

    if (REBool(kREDrawerWhitelist, YES)) {
        REApplySectionPolicy(tv, section, REFirstTextInView(view, 0),
                            view.accessibilityIdentifier);
        if (RESectionIsHidden(tv, section)) view.hidden = YES;
        return;
    }

    if (REViewIsPromo(view)) {
        REMarkSectionHidden(tv, section, @"header 显示");
        if (RESectionIsHidden(tv, section)) view.hidden = YES;
    }
}


static BOOL REIsDrawerName(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return NO;
    return [name containsString:@"CommunityDrawer"] ||
           [name containsString:@"CommunityTab"] ||
           [name containsString:@"Drawer"];
}

static BOOL REViewBelongsToDrawer(UIView *view) {
    UIView *cur = view;
    for (int i = 0; cur && i < 14; i++, cur = cur.superview) {
        if (REIsDrawerName(NSStringFromClass([cur class]))) return YES;
    }
    id responder = view.nextResponder;
    for (int i = 0; responder && i < 14; i++, responder = [responder nextResponder]) {
        if (REIsDrawerName(NSStringFromClass([responder class]))) return YES;
    }
    return NO;
}

static void REInstallFiltersOnTable(UITableView *tableView) {
    if (!tableView) return;
    if (objc_getAssociatedObject(tableView, &kREFiltersInstalledKey)) return;
    if (!REViewBelongsToDrawer(tableView)) return;

    objc_setAssociatedObject(tableView, &kREFiltersInstalledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gCntDrawerTables++;

    id dataSource = tableView.dataSource;
    id delegate   = tableView.delegate;

    NSMutableArray *targets = [NSMutableArray array];
    if (dataSource) [targets addObject:dataSource];
    if (delegate && delegate != dataSource) [targets addObject:delegate];

    for (id obj in targets) {
        RESwizzleInstance(obj, @selector(tableView:heightForRowAtIndexPath:),
                          (IMP)REHookHeightForRow);
        // 只有原本就实现了「估算行高」才接管：否则硬加这个方法会让所有行
        // 先按估算值占位，等于改变了整个表格的布局行为。
        if (class_getInstanceMethod(object_getClass(obj),
                                    @selector(tableView:estimatedHeightForRowAtIndexPath:))) {
            RESwizzleInstance(obj, @selector(tableView:estimatedHeightForRowAtIndexPath:),
                              (IMP)REHookEstimatedHeightForRow);
        }
        RESwizzleInstance(obj, @selector(tableView:heightForHeaderInSection:),
                          (IMP)REHookHeightForHeader);
        RESwizzleInstance(obj, @selector(tableView:heightForFooterInSection:),
                          (IMP)REHookHeightForFooter);
        RESwizzleInstance(obj, @selector(tableView:viewForFooterInSection:),
                          (IMP)REHookViewForFooter);
        RESwizzleInstance(obj, @selector(tableView:titleForHeaderInSection:),
                          (IMP)REHookTitleForHeader);
        RESwizzleInstance(obj, @selector(tableView:viewForHeaderInSection:),
                          (IMP)REHookViewForHeader);
        RESwizzleInstance(obj, @selector(tableView:cellForRowAtIndexPath:),
                          (IMP)REHookCellForRow);
        RESwizzleInstance(obj, @selector(tableView:willDisplayCell:forRowAtIndexPath:),
                          (IMP)REHookWillDisplayCell);
        RESwizzleInstance(obj, @selector(tableView:willDisplayHeaderView:forSection:),
                          (IMP)REHookWillDisplayHeader);
    }

    RELog(@"接管抽屉表格 ds=%@ dg=%@",
          dataSource ? NSStringFromClass([dataSource class]) : @"nil",
          delegate ? NSStringFromClass([delegate class]) : @"nil");
}

static void REDiscoverInView(UIView *view, NSUInteger depth) {
    if (!view || depth > 20) return;
    if ([view isKindOfClass:[UITableView class]]) {
        REInstallFiltersOnTable((UITableView *)view);
    }
    for (UIView *sub in view.subviews) {
        REDiscoverInView(sub, depth + 1);
    }
}

static void REDiscoverDrawerTables(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                REDiscoverInView(window.rootViewController.view, 0);
            }
        }
    });
}

// UITableView -layoutSubviews：首次布局时判断是不是抽屉，是就装过滤
static void REHookTableLayout(id self, SEL _cmd) {
    void (*orig)(id, SEL) = (void *)REOriIMP(self, _cmd);
    if (orig) orig(self, _cmd);

    if (objc_getAssociatedObject(self, &kREFiltersInstalledKey)) return;
    REInstallFiltersOnTable((UITableView *)self);
}

// 偏好变化后清掉缓存并重画抽屉
static void RECollectTables(UIView *view, NSUInteger depth, NSMutableArray *out) {
    if (!view || depth > 20) return;
    if ([view isKindOfClass:[UITableView class]] &&
        objc_getAssociatedObject(view, &kREFiltersInstalledKey)) {
        [out addObject:view];
    }
    for (UIView *sub in view.subviews) {
        RECollectTables(sub, depth + 1, out);
    }
}

static void REResetDrawerCache(void) {
    REWriteDrawerCollapseKeys();

    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *tables = [NSMutableArray array];
        UIApplication *app = UIApplication.sharedApplication;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                RECollectTables(window.rootViewController.view, 0, tables);
            }
        }
        for (UITableView *tv in tables) {
            // 重新探测：清掉旧下标、旧分区数基准、旧的按行状态
            objc_setAssociatedObject(tv, &kREHiddenSectionsKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tv, &kRESectionCountKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tv, &kRESectionHitKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tv, &kREBlockedRowsKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tv, &kREKeptSectionsKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tv, &kREDrawerSigKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (UITableViewCell *cell in tv.visibleCells) {
                cell.hidden = NO;
                cell.alpha = 1.0;
            }
            RELayoutNudge(tv);
        }
    });
}

// ---------------------------------------------------------------------------
// JSON 过滤（信息流广告 / 推荐 / NSFW 等，保留 v2 逻辑）
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// 广告识别（JSON 层 / UI 层共用）
// 依据 2026.46.0 二进制里的真实类型名：
//   AdPost / AsAdPost / SearchAdPost / PromotedCommunityPost /
//   ConversationAd / ConversationAdFeedUnit / CommentAd / …AdCell
// ---------------------------------------------------------------------------
static BOOL RETypeIsAd(NSString *type) {
    if (![type isKindOfClass:[NSString class]] || type.length == 0) return NO;
    if ([type hasPrefix:@"PROMOTED"]) return YES;
    if ([type hasPrefix:@"ConversationAd"]) return YES;      // 评论/信息流会话广告
    if ([type hasPrefix:@"AsConversationAd"]) return YES;
    if ([type containsString:@"PromotedCommunity"]) return YES;
    if ([type containsString:@"HiddenAdPostReplacement"]) return YES;
    NSArray<NSString *> *suffixes = @[@"AdPost", @"PromotedPost", @"CommentAd",
                                      @"AdFeedUnit", @"SponsoredPost",
                                      @"AdCell", @"AdSlot"];
    for (NSString *suffix in suffixes) {
        if ([type hasSuffix:suffix]) return YES;
    }
    return NO;
}

// 节点自带广告标记（二进制里出现过的字段：isAd / isPromoted / isCommentAd / adPayload）
static BOOL REDictIsAd(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return NO;

    for (NSString *key in @[@"isAd", @"isPromoted", @"isSponsored", @"isCommentAd"]) {
        id v = dict[key];
        if ([v respondsToSelector:@selector(boolValue)] && [v boolValue]) return YES;
    }
    if ([dict[@"adPayload"] isKindOfClass:[NSDictionary class]]) return YES;

    id type = dict[@"__typename"];
    if ([type isKindOfClass:[NSString class]] && RETypeIsAd(type)) return YES;
    return NO;
}

static BOOL REIsDrawerPromoItem(id item) {
    if (![item isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *dict = (NSDictionary *)item;

    if (REBool(kREHideDrawerGames, YES)) {
        NSString *type = dict[@"__typename"];
        if ([type isKindOfClass:[NSString class]]) {
            if ([type isEqualToString:@"PersonalizedDevvitGame"] ||
                [type isEqualToString:@"FeaturedDevvitGame"] ||
                [type isEqualToString:@"GameCategoryTagSlice"]) return YES;
        }
        if (dict[@"monthlyPlayers"] || dict[@"personalizedDevvitGame"] ||
            dict[@"featuredDevvitGame"]) return YES;
    }
    return NO;
}

static void REPruneArray(NSMutableArray *array) {
    if (![array isKindOfClass:[NSMutableArray class]]) return;
    BOOL stripAds = REBool(kREFilterPromoted, YES);
    for (NSInteger i = (NSInteger)array.count - 1; i >= 0; i--) {
        id item = array[(NSUInteger)i];
        if (REIsDrawerPromoItem(item)) {
            [array removeObjectAtIndex:(NSUInteger)i];
            gCntAdStripped++;
            continue;
        }
        // 直接从列表里摘掉广告节点：这是最干净的做法 —— 广告根本进不到视图层，
        // 也就不会留下「已隐藏广告」的占位块（HiddenAdPostReplacement）。
        // 评论树里的广告不动结构，只标记隐藏（见 REFilterNode）。
        if (stripAds && [item isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)item;
            BOOL isComment = [dict[@"__typename"] isEqual:@"Comment"];
            // 兼容 GraphQL 连接结构：{ cursor, node: { __typename: AdPost } }
            id inner = dict[@"node"];
            BOOL innerIsAd = [inner isKindOfClass:[NSDictionary class]] &&
                             REDictIsAd((NSDictionary *)inner);
            if (!isComment && (REDictIsAd(dict) || innerIsAd)) {
                [array removeObjectAtIndex:(NSUInteger)i];
                gCntAdStripped++;
                gCntAdNodesRemoved++;
            }
        }
    }
}

static void REFilterNode(NSMutableDictionary *node) {
    if (![node isKindOfClass:[NSMutableDictionary class]]) return;
    gCntNodes++;

    id rawType = node[@"__typename"];
    NSString *type = [rawType isKindOfClass:[NSString class]] ? rawType : nil;

    // 普通帖子
    if ([type isEqualToString:@"SubredditPost"] || [type hasSuffix:@"Post"]) {
        if (REBool(kREHideAwards, NO)) {
            node[@"awardings"] = @[];
            node[@"isGildable"] = @NO;
        }
        if (REBool(kREHideScores, NO)) node[@"isScoreHidden"] = @YES;
        if (REBool(kREFilterNSFW, NO) && [node[@"isNsfw"] boolValue]) {
            node[@"isHidden"] = @YES;
        }
    }

    // 广告 / 推广帖 / 会话广告（ConversationAd、PromotedCommunityPost 等）
    if (REBool(kREFilterPromoted, YES)) {
        if (REDictIsAd(node)) {
            node[@"isHidden"] = @YES;
            gCntAdStripped++;
        }
    }

    // 评论
    if ([type isEqualToString:@"Comment"]) {
        if (REBool(kREHideAwards, NO)) {
            node[@"awardings"] = @[];
            node[@"isGildable"] = @NO;
        }
        if (REBool(kREHideScores, NO)) node[@"isScoreHidden"] = @YES;
        NSDictionary *author = node[@"authorInfo"];
        if (REBool(kRECollapseAutoMod, NO) &&
            [author isKindOfClass:[NSDictionary class]] &&
            [[author[@"id"] description] isEqualToString:@"t2_6l4z3"]) {
            node[@"isInitiallyCollapsed"] = @YES;
        }
    }

    // CellGroup：2026.46.0 用它在信息流内注入广告和推荐
    if ([type isEqualToString:@"CellGroup"]) {
        NSArray *cells = node[@"cells"];
        BOOL strip = NO;
        if ([cells isKindOfClass:[NSArray class]]) {
            for (id cellObj in cells) {
                if (![cellObj isKindOfClass:[NSMutableDictionary class]]) continue;
                NSMutableDictionary *cell = cellObj;
                id rawCellType = cell[@"__typename"];
                NSString *cellType = [rawCellType isKindOfClass:[NSString class]] ? rawCellType : @"";
                if ([cellType isEqualToString:@"ActionCell"]) {
                    if (REBool(kREHideAwards, NO)) {
                        cell[@"isAwardHidden"] = @YES;
                        NSMutableDictionary *golden = cell[@"goldenUpvoteInfo"];
                        if ([golden isKindOfClass:[NSMutableDictionary class]]) {
                            golden[@"isGildable"] = @NO;
                        }
                    }
                    if (REBool(kREHideScores, NO)) cell[@"isScoreHidden"] = @YES;
                }
                if (REBool(kREHidePremium, NO)) {
                    NSString *lower = cellType.lowercaseString;
                    if ([lower containsString:@"premium"] ||
                        [lower containsString:@"upsell"]) {
                        strip = YES;
                    }
                }
                NSString *lowerCell = cellType.lowercaseString;
                // 搜索页的 Trending 单元（SearchTrendingFeedUnit 等）
                if (REBool(kREHideTrending, YES) &&
                    ([lowerCell containsString:@"trending"] ||
                     [lowerCell containsString:@"trends"])) {
                    strip = YES;
                }
                // Reddit Answers 的预览 / 产品卡
                if (REBool(kREHideAnswers, YES) &&
                    REMatchesAny(lowerCell, REAnswersMarkerList())) {
                    strip = YES;
                }
                // 广告 cell：AdPromotedCommunityPostCell / ConversationAd* /
                // PromotedCommunityPostCell 等都藏在这个 CellGroup 里
                if (REBool(kREFilterPromoted, YES) &&
                    (RETypeIsAd(cellType) || REDictIsAd(cell))) {
                    strip = YES;
                    gCntAdNodesRemoved++;
                }
            }
        }
        if (REBool(kREFilterPromoted, YES) &&
            [node[@"adPayload"] isKindOfClass:[NSDictionary class]]) {
            strip = YES;
        }
        if (REBool(kREFilterRecommended, NO)) {
            NSDictionary *ctx = node[@"recommendationContext"];
            if ([ctx isKindOfClass:[NSDictionary class]] &&
                ctx[@"typeIdentifier"] &&
                ![ctx[@"typeIdentifier"] isEqual:NSNull.null]) {
                strip = YES;
            }
        }
        if (strip) {
            node[@"cells"] = @[];
            gCntAdStripped++;
        }
    }

    // 趋势 / Answers 单元：多数是信息流里的独立节点，不在 CellGroup 里
    if (type.length > 0) {
        NSString *lowType = type.lowercaseString;
        if (REBool(kREHideTrending, YES) &&
            ([lowType containsString:@"trendingfeedunit"] ||
             [lowType hasSuffix:@"trending"])) {
            node[@"isHidden"] = @YES;
            gCntAdStripped++;
        }
        if (REBool(kREHideAnswers, YES) &&
            ([lowType containsString:@"answerspreview"] ||
             [lowType containsString:@"answersproductcard"] ||
             [lowType containsString:@"answershero"])) {
            node[@"isHidden"] = @YES;
            gCntAdStripped++;
        }
    }

    // 顶层广告 / 推荐容器：按键名通用匹配
    for (NSString *key in [node.allKeys copy]) {
        id value = node[key];
        if (![value isKindOfClass:[NSArray class]]) continue;
        NSString *lower = key.lowercaseString;
        if (REBool(kREFilterPromoted, YES) &&
            ([lower hasSuffix:@"ads"] || [lower containsString:@"adposts"] ||
             [lower containsString:@"promotedposts"] ||
             [lower containsString:@"conversationads"] ||
             [lower containsString:@"adslots"] || [lower containsString:@"adunits"] ||
             [lower containsString:@"bannerads"] || [lower containsString:@"sponsored"])) {
            node[key] = @[];
            gCntAdStripped++;
        } else if (REBool(kREFilterRecommended, NO) &&
                   [lower containsString:@"recommend"]) {
            node[key] = @[];
            gCntAdStripped++;
        } else if (REBool(kREHideTrending, YES) &&
                   [lower containsString:@"trending"]) {
            node[key] = @[];
            gCntAdStripped++;
        } else if (REBool(kREHideAnswers, YES) &&
                   ([lower containsString:@"answersdiscovery"] ||
                    [lower containsString:@"answerspreview"] ||
                    [lower containsString:@"answerscarousel"] ||
                    [lower containsString:@"answersunit"])) {
            node[key] = @[];
            gCntAdStripped++;
        }
    }
}

static void REWalkJSON(id obj, NSUInteger depth) {
    if (depth > 16) return;
    if ([obj isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *array = (NSMutableArray *)obj;
        REPruneArray(array);
        for (id item in array) REWalkJSON(item, depth + 1);
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) REWalkJSON(item, depth + 1);
    } else if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)obj;
        REFilterNode(dict);
        for (NSString *key in [dict.allKeys copy]) REWalkJSON(dict[key], depth + 1);
    }
}

// ---------------------------------------------------------------------------
// Hook: NSURLSession
// ---------------------------------------------------------------------------
static IMP gOrigDataTask = NULL;
static _Thread_local BOOL gREInFilter = NO;

// 广告 / 统计追踪域名（从 2026.46.0 二进制里挖出来的真实域名 + 常见第三方 SDK）
static NSArray<NSString *> *RETrackerHosts(void) {
    static NSArray *hosts = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hosts = @[
            @"ads.reddit.com", @"ads-api.reddit.com", @"alb.reddit.com",
            @"pixel-config.reddit.com",
            @"app.appsflyer.com", @"appsflyersdk.com",
            @"app-measurement.com", @"google-analytics.com",
            @"firebaselogging", @"crashlytics.com",
            @"braze.com", @"appboy.com",
            @"sentry.io", @"amplitude.com", @"mixpanel.com",
            @"doubleclick.net", @"googlesyndication.com"
        ];
    });
    return hosts;
}

static BOOL REHostIsTracker(NSString *host) {
    if (host.length == 0) return NO;
    for (NSString *needle in RETrackerHosts()) {
        if ([host hasSuffix:needle] || [host containsString:needle]) return YES;
    }
    return NO;
}

// 直接回一个 204 空响应，请求不出网
static void REBlockRequest(NSURLRequest *request,
                           void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    gCntTrackersBlocked++;
    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                    statusCode:204
                                   HTTPVersion:@"HTTP/1.1"
                                  headerFields:@{}];
    dispatch_async(dispatch_get_main_queue(), ^{
        completionHandler([NSData data], response, nil);
    });
}

typedef NSURLSessionDataTask *(*REDataTaskIMP)(id, SEL, NSURLRequest *,
                                               void (^)(NSData *, NSURLResponse *, NSError *));

static NSURLSessionDataTask *REHookedDataTask(id self, SEL _cmd, NSURLRequest *request,
                                              void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    NSString *host = request.URL.host.lowercaseString ?: @"";
    BOOL isReddit = [host containsString:@"reddit.com"] ||
                    [host containsString:@"redd.it"];

    // 追踪/广告域名先拦，不看是不是 reddit 域（appsflyer 之类是第三方域）
    if (completionHandler && REBool(kREBlockTrackers, YES) && REHostIsTracker(host)) {
        REBlockRequest(request, completionHandler);
        return nil;   // nil 的 task 上 resume/cancel 都是空操作
    }

    if (!isReddit || !completionHandler) {
        return ((REDataTaskIMP)gOrigDataTask)(self, _cmd, request, completionHandler);
    }

    gCntURLSession++;

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *outData = data;
            if (data.length > 8 && !error && !gREInFilter) {
                NSError *jsonError = nil;
                gREInFilter = YES;
                id json = [NSJSONSerialization JSONObjectWithData:data
                                                          options:NSJSONReadingMutableContainers
                                                            error:&jsonError];
                if (json && !jsonError) {
                    REWalkJSON(json, 0);
                    NSData *serialized = [NSJSONSerialization dataWithJSONObject:json
                                                                         options:0
                                                                           error:nil];
                    if (serialized) outData = serialized;
                }
                gREInFilter = NO;
            }
            completionHandler(outData, response, error);
        };

    return ((REDataTaskIMP)gOrigDataTask)(self, _cmd, request, wrapped);
}

static void REInstallNetworkHook(void) {
    Class cls = objc_getClass("NSURLSession");
    SEL sel = @selector(dataTaskWithRequest:completionHandler:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    gOrigDataTask = method_getImplementation(m);
    method_setImplementation(m, (IMP)REHookedDataTask);
    gCntHooksInstalled++;
}

// ---------------------------------------------------------------------------
// Hook: NSJSONSerialization（覆盖 Swift async/await 网络路径）
// ---------------------------------------------------------------------------
static IMP gOrigJSONObject = NULL;

typedef id (*REJSONObjectIMP)(id, SEL, NSData *, NSJSONReadingOptions, NSError **);

static id REHookedJSONObject(id self, SEL _cmd, NSData *data,
                             NSJSONReadingOptions options, NSError **error) {
    BOOL looksLikeFeed = NO;
    if (data.length >= 8) {
        NSArray<NSData *> *markers = @[
            [@"__typename" dataUsingEncoding:NSUTF8StringEncoding],
            [@"adPayload"  dataUsingEncoding:NSUTF8StringEncoding],
            [@"CellGroup"  dataUsingEncoding:NSUTF8StringEncoding]
        ];
        for (NSData *marker in markers) {
            if ([data rangeOfData:marker options:0
                            range:NSMakeRange(0, data.length)].location != NSNotFound) {
                looksLikeFeed = YES;
                break;
            }
        }
    }
    if (!looksLikeFeed || gREInFilter) {
        return ((REJSONObjectIMP)gOrigJSONObject)(self, _cmd, data, options, error);
    }

    gCntJSON++;
    id result = ((REJSONObjectIMP)gOrigJSONObject)(self, _cmd, data,
                                                   options | NSJSONReadingMutableContainers,
                                                   error);
    if (result &&
        ([result isKindOfClass:[NSMutableDictionary class]] ||
         [result isKindOfClass:[NSMutableArray class]])) {
        gREInFilter = YES;
        REWalkJSON(result, 0);
        gREInFilter = NO;
    }
    return result;
}

static void REInstallJSONHook(void) {
    Class cls = objc_getClass("NSJSONSerialization");
    SEL sel = @selector(JSONObjectWithData:options:error:);
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    gOrigJSONObject = method_getImplementation(m);
    method_setImplementation(m, (IMP)REHookedJSONObject);
    gCntHooksInstalled++;
}

// ---------------------------------------------------------------------------
// Hook: SKStoreReviewController —— 屏蔽「给 Reddit 评分」弹窗
// ---------------------------------------------------------------------------
static IMP gOrigRequestReview = NULL;
static IMP gOrigRequestReviewInScene = NULL;

static void REHookRequestReview(id self, SEL _cmd) {
    if (!REBool(kREBlockReviewPrompt, YES)) {
        if (gOrigRequestReview) ((void (*)(id, SEL))gOrigRequestReview)(self, _cmd);
        return;
    }
    gCntReviewBlocked++;
    RELog(@"拦截 App Store 评分弹窗");
}

static void REHookRequestReviewInScene(id self, SEL _cmd, id scene) {
    if (!REBool(kREBlockReviewPrompt, YES)) {
        if (gOrigRequestReviewInScene) {
            ((void (*)(id, SEL, id))gOrigRequestReviewInScene)(self, _cmd, scene);
        }
        return;
    }
    gCntReviewBlocked++;
    RELog(@"拦截 App Store 评分弹窗（scene）");
}

static void REInstallReviewHook(void) {
    Class cls = objc_getClass("SKStoreReviewController");
    if (!cls) {
        RELog(@"没找到 SKStoreReviewController，跳过评分拦截");
        return;
    }
    Method m = class_getClassMethod(cls, @selector(requestReview));
    if (m) {
        gOrigRequestReview = method_getImplementation(m);
        method_setImplementation(m, (IMP)REHookRequestReview);
        gCntHooksInstalled++;
    }
    Method m2 = class_getClassMethod(cls, @selector(requestReviewInScene:));
    if (m2) {
        gOrigRequestReviewInScene = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)REHookRequestReviewInScene);
        gCntHooksInstalled++;
    }
}

// ---------------------------------------------------------------------------
// Hook: -[UIView setAccessibilityIdentifier:]
// SwiftUI 里的「Ask Answers」按钮、搜索页 Trending 标题都带 UIIdentifier 的
// rawValue 作为 accessibilityIdentifier；在这里拦下来直接隐藏，比遍历视图树便宜。
// ---------------------------------------------------------------------------
// 广告相关无障碍标识（取自二进制里的 UIIdentifier rawValue，全小写）
// 这是最后一道兜底：JSON 层没拦住的广告，至少不能显示出来。
static BOOL REIdentifierShouldHide(NSString *ident) {
    if (![ident isKindOfClass:[NSString class]] || ident.length == 0) return NO;
    NSString *low = ident.lowercaseString;
    if (REBool(kREFilterPromoted, YES) && REMatchesAny(low, REAdIdentifiers())) return YES;
    if (REBool(kREHideAnswers, YES) && REMatchesAny(low, REAnswersMarkerList())) return YES;
    if (REBool(kREHideTrending, YES) &&
        ([low containsString:@"trendingtoday"] ||
         [low containsString:@"screentrendingtopics"] ||
         [low containsString:@"drawertrendstitle"])) return YES;
    return NO;
}

static void REHookSetA11yIdentifier(id self, SEL _cmd, NSString *ident) {
    void (*orig)(id, SEL, NSString *) = (void *)REOriIMP(self, _cmd);
    if (orig) orig(self, _cmd, ident);

    if (![self isKindOfClass:[UIView class]] || !REIdentifierShouldHide(ident)) return;
    ((UIView *)self).hidden = YES;
    gCntViewsHidden++;
    RELogOnce([@"a11y|" stringByAppendingString:ident], @"按标识隐藏元素：%@", ident);
}

static void REInstallA11yHook(void) {
    NSInteger before = gCntHooksInstalled;
    RESwizzleClass([UIView class], @selector(setAccessibilityIdentifier:),
                   (IMP)REHookSetA11yIdentifier);
    RELog(@"无障碍标识 hook：%@",
          gCntHooksInstalled > before ? @"已安装" : @"未安装（系统方法不存在）");
}

// ---------------------------------------------------------------------------
// 设置项
// ---------------------------------------------------------------------------
// 设置页数据模型：分区 -> 行；最后一个分区是「其他」，只有一行（诊断入口）
static NSArray<NSDictionary *> *RESettingsModel(void) {
    static NSArray *model = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        model = @[
            @{ @"t": @"内容过滤",
               @"f": @"开关即时生效，无需重启 App。",
               @"rows": @[
                    @{ @"k": kREFilterPromoted,    @"t": @"去除广告与推广",
                       @"s": @"移除推广帖、广告和赞助内容", @"d": @YES },
                    @{ @"k": kREFilterRecommended, @"t": @"隐藏推荐内容",
                       @"s": @"去掉「相似帖子」等推荐注入", @"d": @NO },
                    @{ @"k": kREFilterNSFW,        @"t": @"屏蔽 NSFW 内容",
                       @"s": @"从信息流中隐藏 NSFW 内容", @"d": @NO },
               ]},

            @{ @"t": @"界面精简",
               @"f": @"隐藏类开关只影响显示，不改变内容排序。",
               @"rows": @[
                    @{ @"k": kREHideAwards,      @"t": @"隐藏赞赏徽章",
                       @"s": @"移除帖子和评论的赞赏徽章", @"d": @NO },
                    @{ @"k": kREHideScores,      @"t": @"隐藏投票数",
                       @"s": @"隐藏点赞／点踩数量", @"d": @NO },
                    @{ @"k": kRECollapseAutoMod, @"t": @"折叠 AutoMod 评论",
                       @"s": @"自动收起 AutoMod 机器人的回复", @"d": @NO },
                    @{ @"k": kREHidePremium,     @"t": @"隐藏 Premium 推广",
                       @"s": @"移除 Premium 横幅、升级提示与入口", @"d": @NO },
                    @{ @"k": kREHideTrending,    @"t": @"隐藏趋势 / Trending",
                       @"s": @"去掉搜索页的热门趋势与抽屉趋势分区", @"d": @YES },
                    @{ @"k": kREHideAnswers,     @"t": @"隐藏 Reddit Answers 入口",
                       @"s": @"去掉搜索栏「Ask Answers」与 AI 卡片", @"d": @YES },
               ]},

            @{ @"t": @"侧边栏（左侧抽屉）",
               @"f": @"打开左侧抽屉时生效；若没变化，去「其他 → 诊断信息」看命中数。",
               @"rows": @[
                    @{ @"k": kREDrawerWhitelist,     @"t": @"只保留核心入口",
                       @"s": @"只留热门、新闻、最新、创建社区、最近访问、你的社区，其余全部移除", @"d": @YES },
                    @{ @"k": kREHideDrawerGames,     @"t": @"隐藏「Reddit 上的游戏」",
                       @"s": @"折叠抽屉里的 Devvit 游戏推荐分区", @"d": @YES },
                    @{ @"k": kREHideDrawerResources, @"t": @"隐藏「资源 / 关于」分区",
                       @"s": @"去掉资源、Reddit Pro、Premium、关于、规则、隐私政策、用户协议", @"d": @YES },
               ]},

            @{ @"t": @"隐私与体验",
               @"f": @"屏蔽后不影响正常刷帖，只是不再上报统计、不再弹评分。",
               @"rows": @[
                    @{ @"k": kREBlockTrackers,     @"t": @"屏蔽广告与统计追踪",
                       @"s": @"拦截广告服务器与第三方统计域名", @"d": @YES },
                    @{ @"k": kREBlockReviewPrompt, @"t": @"屏蔽 App Store 评分弹窗",
                       @"s": @"不再弹出「给 Reddit 评分」", @"d": @YES },
               ]},

            @{ @"t": @"其他",
               @"f": @"Reddit 增强 · 适用于 Reddit 2026.46.0（巨魔）\n"
                     "会员权限由服务器校验，客户端无法真正解锁；本插件只做展示层优化。",
               @"rows": @[] }
        ];
    });
    return model;
}

static NSArray<NSDictionary *> *REAllRows(void) {
    static NSArray *rows = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *all = [NSMutableArray array];
        for (NSDictionary *section in RESettingsModel()) {
            [all addObjectsFromArray:section[@"rows"]];
        }
        rows = [all copy];
    });
    return rows;
}

static NSInteger RESectionCount(void) { return (NSInteger)RESettingsModel().count; }

static NSDictionary *RESectionAt(NSInteger section) {
    NSArray *model = RESettingsModel();
    if (section < 0 || section >= (NSInteger)model.count) return nil;
    return model[(NSUInteger)section];
}

static BOOL RESectionIsDiagnostics(NSInteger section) {
    NSDictionary *sec = RESectionAt(section);
    return sec != nil && [(NSArray *)sec[@"rows"] count] == 0;
}

static NSInteger RERowsInSection(NSInteger section) {
    NSDictionary *sec = RESectionAt(section);
    if (!sec) return 0;
    NSArray *rows = sec[@"rows"];
    return rows.count > 0 ? (NSInteger)rows.count : 1;   // 诊断入口占一行
}

static NSInteger RESectionBaseIndex(NSInteger section) {
    NSInteger base = 0;
    for (NSInteger i = 0; i < section; i++) {
        NSDictionary *sec = RESectionAt(i);
        base += (NSInteger)[(NSArray *)sec[@"rows"] count];
    }
    return base;
}

static NSInteger RERowIndexForIndexPath(NSIndexPath *indexPath) {
    return RESectionBaseIndex(indexPath.section) + indexPath.row;
}

// ---------------------------------------------------------------------------
// 诊断信息
// ---------------------------------------------------------------------------
static NSString *REDiagnosticsText(void) {
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"== Hook 状态 ==\n"];
    [text appendFormat:@"已安装 hook: %ld\n", (long)gCntHooksInstalled];
    [text appendFormat:@"接管抽屉表格: %ld\n", (long)gCntDrawerTables];
    [text appendFormat:@"折叠抽屉分区: %ld\n", (long)gCntSectionsHidden];
    [text appendFormat:@"移除抽屉行: %ld\n", (long)gCntDrawerRowsHidden];
    [text appendFormat:@"白名单模式: %@\n", REBool(kREDrawerWhitelist, YES) ? @"开" : @"关"];
    [text appendFormat:@"按标识隐藏元素: %ld\n", (long)gCntViewsHidden];
    [text appendFormat:@"拦截评分弹窗: %ld\n", (long)gCntReviewBlocked];
    [text appendString:@"\n== 网络 ==\n"];
    [text appendFormat:@"NSURLSession 命中: %ld\n", (long)gCntURLSession];
    [text appendFormat:@"拦截追踪请求: %ld\n", (long)gCntTrackersBlocked];
    [text appendFormat:@"JSON 解析命中: %ld\n", (long)gCntJSON];
    [text appendFormat:@"JSON 节点处理: %ld\n", (long)gCntNodes];
    [text appendFormat:@"剥离广告/推荐: %ld\n", (long)gCntAdStripped];
    [text appendFormat:@"其中摘除广告节点: %ld\n", (long)gCntAdNodesRemoved];
    [text appendString:@"\n== 开关 ==\n"];
    for (NSDictionary *row in REAllRows()) {
        NSString *key = row[@"k"];
        BOOL on = REBool(key, [row[@"d"] boolValue]);
        [text appendFormat:@"%@ %@\n", on ? @"[开]" : @"[关]", row[@"t"]];
    }
    [text appendString:@"\n== 日志 ==\n"];
    @synchronized (gRELogLock ?: [NSNull null]) {
        if (gRELog.count == 0) {
            [text appendString:@"(暂无日志)\n"];
        } else {
            for (NSString *line in gRELog) {
                [text appendFormat:@"%@\n", line];
            }
        }
    }
    return text;
}

// ---------------------------------------------------------------------------
// 二级菜单 UI
// ---------------------------------------------------------------------------
@class RESettingsViewController;
@class REDiagnosticsViewController;

@interface REUIHelper : NSObject
+ (instancetype)shared;
- (void)openSettings;
@end

@interface REDiagnosticsViewController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@end

// ---------------------------------------------------------------------------
// 「是不是我们自己的界面」——用于防止在增强设置页里再注入一个增强设置按钮
// ---------------------------------------------------------------------------
static BOOL REIsOwnVC(UIViewController *vc) {
    if (!vc) return NO;
    NSString *name = NSStringFromClass([vc class]);
    if ([name isEqualToString:@"RESettingsViewController"] ||
        [name isEqualToString:@"REDiagnosticsViewController"]) return YES;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *top = ((UINavigationController *)vc).topViewController;
        if (top && REIsOwnVC(top)) return YES;
    }
    return NO;
}

static UIWindow *REKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindow *first = ((UIWindowScene *)scene).windows.firstObject;
        if (first) return first;
    }
    return nil;
}

// 当前最顶层的控制器是不是我们自己的（含 modal 链）
static BOOL RETopViewControllerIsOurs(void) {
    UIViewController *vc = REKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = ((UINavigationController *)vc).visibleViewController ?: vc;
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        vc = ((UITabBarController *)vc).selectedViewController ?: vc;
    }
    return REIsOwnVC(vc);
}

// 把我们注入的「增强设置」按钮从导航栏里摘掉（幂等，可以反复调用）
static void REStripEntryBarItems(UINavigationItem *item) {
    if (!item) return;
    NSArray<UIBarButtonItem *> *right = item.rightBarButtonItems;
    if (right.count == 0) return;

    NSMutableArray<UIBarButtonItem *> *keep = [NSMutableArray arrayWithCapacity:right.count];
    BOOL removed = NO;
    for (UIBarButtonItem *bar in right) {
        BOOL isOurs = [bar.accessibilityIdentifier isEqualToString:@"REEntryBarItem"] ||
                      ([bar.title isKindOfClass:[NSString class]] &&
                       [bar.title containsString:@"增强"]);
        if (isOurs) { removed = YES; continue; }
        [keep addObject:bar];
    }
    if (removed) item.rightBarButtonItems = keep.count ? keep : nil;
}

static void REStripEntryFromBarsOf(UIViewController *vc) {
    if (!vc) return;
    REStripEntryBarItems(vc.navigationItem);
    UINavigationController *nav = vc.navigationController;
    if (!nav) return;
    REStripEntryBarItems(nav.navigationItem);
    if (nav.topViewController) REStripEntryBarItems(nav.topViewController.navigationItem);
    for (UINavigationItem *item in nav.navigationBar.items) REStripEntryBarItems(item);
}

@implementation REDiagnosticsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"诊断信息";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.alwaysBounceVertical = YES;
    self.textView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self.textView.font = [UIFont monospacedSystemFontOfSize:11
                                                     weight:UIFontWeightRegular];
    self.textView.text = REDiagnosticsText();
    [self.view addSubview:self.textView];

    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"刷新"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(refresh)];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    gREOwnUIVisible++;
    REStripEntryFromBarsOf(self);
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (gREOwnUIVisible > 0) gREOwnUIVisible--;
}

- (void)refresh {
    REWriteDrawerCollapseKeys();
    REDiscoverDrawerTables();
    REResetDrawerCache();
    self.textView.text = REDiagnosticsText();
}

@end

@interface RESettingsViewController : UITableViewController
@end

@implementation RESettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"增强设置";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(re_done)];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    gREOwnUIVisible++;
    // 双保险：万一有别的 hook 路径把「增强设置」按钮塞进来了，进页面后立刻摘掉
    REStripEntryFromBarsOf(self);
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (gREOwnUIVisible > 0) gREOwnUIVisible--;
}

- (void)re_done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return RESectionCount();
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return RERowsInSection(section);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *title = RESectionAt(section)[@"t"];
    return title ?: @"";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *footer = RESectionAt(section)[@"f"];
    return footer ?: @"";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (RESectionIsDiagnostics(indexPath.section)) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"REDiagCell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"REDiagCell"];
        }
        cell.textLabel.text = @"诊断信息";
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RECell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"RECell"];
    }

    NSInteger index = RERowIndexForIndexPath(indexPath);
    NSArray *all = REAllRows();
    if (index < 0 || index >= (NSInteger)all.count) return cell;
    NSDictionary *row = all[(NSUInteger)index];

    cell.textLabel.text = row[@"t"];
    cell.detailTextLabel.text = row[@"s"];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = REBool(row[@"k"], [row[@"d"] boolValue]);
    toggle.tag = index;
    [toggle addTarget:self
               action:@selector(re_toggle:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (RESectionIsDiagnostics(indexPath.section)) {
        REDiagnosticsViewController *diag = [[REDiagnosticsViewController alloc] init];
        [self.navigationController pushViewController:diag animated:YES];
    }
}

- (void)re_toggle:(UISwitch *)sender {
    NSInteger index = sender.tag;
    NSArray *all = REAllRows();
    if (index < 0 || index >= (NSInteger)all.count) return;
    NSDictionary *row = all[(NSUInteger)index];
    NSString *key = row[@"k"];

    REBoolSet(key, sender.on);
    [REGroup() synchronize];
    [NSUserDefaults.standardUserDefaults synchronize];

    RELog(@"开关 %@ = %@", row[@"t"], sender.on ? @"开" : @"关");

    if ([key isEqualToString:kREHideDrawerGames] ||
        [key isEqualToString:kREHideDrawerResources] ||
        [key isEqualToString:kREDrawerWhitelist]) {
        REResetDrawerCache();
    }
}

@end

@implementation REUIHelper

+ (instancetype)shared {
    static REUIHelper *helper = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        helper = [[REUIHelper alloc] init];
    });
    return helper;
}

- (UIWindow *)re_keyWindow {
    UIApplication *app = UIApplication.sharedApplication;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindow *first = ((UIWindowScene *)scene).windows.firstObject;
        if (first) return first;
    }
    return nil;
}

- (UIViewController *)re_topViewController {
    UIViewController *vc = [self re_keyWindow].rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = ((UINavigationController *)vc).visibleViewController ?: vc;
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        vc = ((UITabBarController *)vc).selectedViewController ?: vc;
    }
    return vc;
}

- (void)openSettings {
    UIViewController *top = [self re_topViewController];
    if (!top) {
        RELog(@"打开设置失败：找不到顶层控制器");
        return;
    }
    RESettingsViewController *settings =
        [[RESettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:settings];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
    RELog(@"打开增强设置（from %@）", NSStringFromClass([top class]));
}

@end

// ---------------------------------------------------------------------------
// Hook: UIViewController -viewDidAppear:  —— 抽屉接管 + 设置入口注入
// ---------------------------------------------------------------------------
static char kREEntryRetryKey;

static BOOL REIsExcludedSettingsLike(NSString *hay) {
    NSArray *blocked = @[@"modtools", @"notification", @"translation",
                         @"gender", @"language", @"posttype", @"room",
                         @"chat", @"redditenhancer", @"diagnostic",
                         // 我们自己的二级菜单（标题就叫「增强设置」，
                         // 含有「设置」两个字，必须显式排除）
                         @"增强", @"diagnostics"];
    for (NSString *word in blocked) {
        if ([hay containsString:word]) return YES;
    }
    return NO;
}

static UINavigationController *REFindNavigationController(UIViewController *vc) {
    for (UIViewController *cur = vc; cur; cur = cur.parentViewController) {
        if ([cur isKindOfClass:[UINavigationController class]]) {
            return (UINavigationController *)cur;
        }
        if (cur.navigationController) return cur.navigationController;
    }
    return nil;
}

// SwiftUI 的 NavigationStack 用的是 SwiftUI 自己的 UINavigationBar 子类，
// 不在 UINavigationController 里，所以只能从视图树里捞。
static UINavigationBar *REFindNavigationBar(UIView *view, NSUInteger depth) {
    if (!view || depth > 12) return nil;
    if ([view isKindOfClass:[UINavigationBar class]]) return (UINavigationBar *)view;
    for (UIView *sub in view.subviews) {
        UINavigationBar *bar = REFindNavigationBar(sub, depth + 1);
        if (bar) return bar;
    }
    return nil;
}

static BOOL REBarItemExists(NSArray<UIBarButtonItem *> *items) {
    for (UIBarButtonItem *item in items) {
        if ([item.accessibilityIdentifier isEqualToString:@"REEntryBarItem"]) return YES;
        if ([item.title containsString:@"增强"]) return YES;
    }
    return NO;
}

static UIBarButtonItem *REMakeEntryBarItem(void) {
    UIBarButtonItem *item =
        [[UIBarButtonItem alloc] initWithTitle:@"增强设置"
                                         style:UIBarButtonItemStylePlain
                                        target:[REUIHelper shared]
                                        action:@selector(openSettings)];
    item.accessibilityIdentifier = @"REEntryBarItem";
    return item;
}

// 入口只放导航栏：普通 UIKit 导航栈 → 退到 SwiftUI 自绘导航栏。
// 不再放任何悬浮／角落小按钮。
static void REInjectEntryIntoPage(UIViewController *vc);

// SwiftUI 的导航栏是渲染之后才有的，viewDidAppear 时可能还没生成 → 稍后重试
static void REScheduleEntryRetry(UIViewController *vc) {
    NSNumber *tries = objc_getAssociatedObject(vc, &kREEntryRetryKey);
    if (tries.integerValue >= 3) return;
    objc_setAssociatedObject(vc, &kREEntryRetryKey, @(tries.integerValue + 1),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        if (strongVC && strongVC.isViewLoaded) REInjectEntryIntoPage(strongVC);
    });
}

static void REInjectEntryIntoPage(UIViewController *vc) {
    // 绝不在我们自己的设置页/诊断页上再注入入口（否则进增强设置后右上角
    // 又出现一个「增强设置」，看起来像嵌套）
    if (!vc || REIsOwnVC(vc)) return;
    if (gREOwnUIVisible > 0 || RETopViewControllerIsOurs()) return;

    UINavigationController *nav = REFindNavigationController(vc);
    if (nav) {
        UIViewController *target = nav.topViewController ?: vc;
        if (!target || REIsOwnVC(target)) return;
        if (REBarItemExists(target.navigationItem.rightBarButtonItems)) return;
        NSArray *right = target.navigationItem.rightBarButtonItems ?: @[];
        target.navigationItem.rightBarButtonItems =
            [right arrayByAddingObject:REMakeEntryBarItem()];
        RELog(@"设置入口 → 导航栏（%@）", NSStringFromClass([target class]));
        return;
    }

    if (!vc.isViewLoaded) return;
    UINavigationBar *bar = REFindNavigationBar(vc.view, 0);
    UINavigationItem *item = bar.topItem;
    if (item) {
        // SwiftUI 导航栏的 topItem 有可能属于我们自己的页面，靠标题兜一层
        if ([item.title isKindOfClass:[NSString class]] &&
            ([item.title containsString:@"增强设置"] ||
             [item.title containsString:@"诊断信息"])) return;
        if (REBarItemExists(item.rightBarButtonItems)) return;
        NSArray *right = item.rightBarButtonItems ?: @[];
        item.rightBarButtonItems = [right arrayByAddingObject:REMakeEntryBarItem()];
        RELog(@"设置入口 → SwiftUI 导航栏（%@）", NSStringFromClass([vc class]));
        return;
    }
    RELog(@"设置页暂时没有导航栏，稍后重试：%@", NSStringFromClass([vc class]));
    REScheduleEntryRetry(vc);
}

static void REHookedViewDidAppear(id self, SEL _cmd, BOOL animated) {
    void (*orig)(id, SEL, BOOL) = (void *)REOriIMP(self, _cmd);
    if (orig) orig(self, _cmd, animated);

    if (![self isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)self;
    // 自己的设置页 / 诊断页 / 承载它们的导航控制器：一律不处理
    if (REIsOwnVC(vc)) return;

    NSString *cls = NSStringFromClass([vc class]);

    // 抽屉出现：装过滤 + 写折叠 key
    if (REIsDrawerName(cls)) {
        REWriteDrawerCollapseKeys();
        if (vc.isViewLoaded) REDiscoverInView(vc.view, 0);
        REDiscoverDrawerTables();
    }

    // 设置页：注入入口
    NSString *title = vc.navigationItem.title ?: (vc.title ?: @"");
    NSString *hay = [NSString stringWithFormat:@"%@ %@", title, cls].lowercaseString;
    if (REIsExcludedSettingsLike(hay)) return;
    BOOL isSettings = [hay containsString:@"settings"] ||
                      [hay containsString:@"设置"] ||
                      [hay containsString:@"preferences"] ||
                      [hay containsString:@"account"];
    if (!isSettings) return;

    REInjectEntryIntoPage(vc);
}

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------
__attribute__((constructor)) static void REInitialize(void) {
    @autoreleasepool {
        REInitSwizzleTables();

        NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
        for (NSDictionary *row in REAllRows()) {
            defaults[row[@"k"]] = row[@"d"];
        }
        // 只注册到 standard：REBool 先读 App Group 的显式值，再回落到
        // standard（含这里的注册默认值）。若把默认值也注册进 App Group，
        // 会盖住用户之前在 standard 里存的开关状态。
        [NSUserDefaults.standardUserDefaults registerDefaults:defaults];

        REInstallNetworkHook();
        REInstallJSONHook();
        REInstallReviewHook();
        REInstallA11yHook();

        RESwizzleClass([UIViewController class],
                       @selector(viewDidAppear:),
                       (IMP)REHookedViewDidAppear);
        RESwizzleClass([UITableView class],
                       @selector(layoutSubviews),
                       (IMP)REHookTableLayout);

        REWriteDrawerCollapseKeys();
        REDiscoverDrawerTables();

        RELog(@"RedditEnhancer v6 已加载（hook %ld 个）", (long)gCntHooksInstalled);
    }
}
