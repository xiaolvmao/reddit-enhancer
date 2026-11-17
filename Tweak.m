//
//  RedditEnhancer — TrollStore tweak for Reddit 2026.46.0
//  Bundle ID: com.reddit.Reddit   Executable: RedditApp
//
//  v3 —— 抽屉推广位改走 UI 层拦截
//  （v2 用 UserDefaults 折叠 key 无效的原因：抽屉内容被
//   CommunityDrawerCacheServiceImpl 缓存成 ViewModel，改偏好不会重算）
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
//   1) 抽屉：接管 UITableView 的 datasource/delegate，识别到推广分区后把
//      行数设为 0、header 高度设为 0 —— 行被真正移除，不留空白。
//      识别信号：类名 + accessibilityIdentifier + 文案（三重冗余）。
//   2) 设置入口：导航栏按钮 + 页面内兜底按钮（设置页是 SwiftUI 时没有
//      UINavigationController，v2 的入口会直接消失）。
//   3) 诊断页：显示所有 hook 命中计数与实时日志，便于逐步定位。
//   4) Premium：只做「隐藏所有 Premium 推广入口」，不再假装解锁。
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
static NSInteger gCntHooksInstalled = 0;

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

// 抽屉里「资源 / Reddit Pro / Premium」相关文案 / 标识（全部小写）
static NSArray<NSString *> *REResourceMarkers(void) {
    return @[@"resourcessection", @"resources", @"资源",
             @"advertiseon", @"advertise on reddit",
             @"trypro", @"try pro", @"tryredditpro", @"reddit pro",
             @"premiumtitle", @"reddit premium",
             @"prolinks", @"earntitle", @"vaulttitle", @"trendstitle",
             @"rulestitle", @"reddit rules",
             @"privacypolicy", @"privacy policy",
             @"useragreement", @"user agreement",
             @"osainformation", @"osa information",
             @"acknowledgements", @"impressum", @"help center"];
}

static BOOL REStringIsGamePromo(NSString *s) {
    return REBool(kREHideDrawerGames, YES) && REMatchesAny(s, REGamesMarkers());
}

static BOOL REStringIsResourcePromo(NSString *s) {
    return REBool(kREHideDrawerResources, YES) && REMatchesAny(s, REResourceMarkers());
}

static BOOL REStringIsPromo(NSString *s) {
    return REStringIsGamePromo(s) || REStringIsResourcePromo(s);
}

// 分区标题做「整串匹配」，避免误伤普通社区名
static NSSet<NSString *> *REPromoTitles(void) {
    static NSSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"resources", @"reddit pro", @"try pro", @"try reddit pro",
            @"reddit premium", @"premium", @"earn", @"vault", @"trends",
            @"advertise on reddit", @"reddit rules", @"privacy policy",
            @"user agreement", @"accessibility", @"help center",
            @"acknowledgements", @"impressum", @"osa information",
            @"games on reddit", @"discover more games", @"资源", @"游戏"
        ]];
    });
    return set;
}

static BOOL RETitleIsPromo(NSString *title) {
    if (![title isKindOfClass:NSString.class] || title.length == 0) return NO;
    NSString *low = [title.lowercaseString
                     stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![REPromoTitles() containsObject:low]) return NO;
    return REStringIsPromo(low);
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

    // 3) 视图树文案
    BOOL (^pred)(NSString *) = ^BOOL(NSString *s) { return REStringIsPromo(s); };
    return REScanTextInView(view, 0, pred);
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
static char kREReloadPendingKey;
static char kREFiltersInstalledKey;

// dataSource 类名 -> 已确认的推广分区（跨抽屉实例复用，避免每次打开闪一下）
static NSMutableDictionary<NSString *, NSMutableIndexSet *> *gREHiddenByClass = nil;

static NSObject *REHiddenLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSObject alloc] init];
        gREHiddenByClass = [NSMutableDictionary dictionary];
    });
    return lock;
}

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
        NSString *clsName = RETableClassKey(tv);
        NSMutableIndexSet *seed = nil;
        @synchronized (REHiddenLock()) {
            seed = gREHiddenByClass[clsName];
        }
        set = seed ? [seed mutableCopy] : [NSMutableIndexSet indexSet];
        objc_setAssociatedObject(tv, &kREHiddenSectionsKey, set,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}

static void REMarkSectionHidden(UITableView *tv, NSInteger section, NSString *reason) {
    if (!tv) return;
    NSMutableIndexSet *set = RETableHiddenSet(tv, YES);
    if ([set containsIndex:section]) return;

    // 安全阀：分区行数过多说明它是「整个抽屉」而不是独立的推广分区，
    // 这时只做视觉隐藏，绝不整段清空（否则会把侧边栏清空）
    id ds = tv.dataSource;
    if (ds) {
        SEL sel = @selector(tableView:numberOfRowsInSection:);
        NSInteger (*fn)(id, SEL, UITableView *, NSInteger) = (void *)REOriIMP(ds, sel);
        if (fn) {
            NSInteger rows = fn(ds, sel, tv, section);
            if (rows > 14) {
                RELog(@"分区 #%ld 有 %ld 行，判定为非独立推广分区，跳过整段移除（%@）",
                      (long)section, (long)rows, reason);
                return;
            }
        }
    }

    [set addIndex:section];
    gCntSectionsHidden++;

    NSString *clsName = RETableClassKey(tv);
    @synchronized (REHiddenLock()) {
        NSMutableIndexSet *cached = gREHiddenByClass[clsName];
        if (!cached) {
            cached = [NSMutableIndexSet indexSet];
            gREHiddenByClass[clsName] = cached;
        }
        [cached addIndex:section];
    }

    RELog(@"移除抽屉分区 #%ld（%@）ds=%@", (long)section, reason, clsName);

    if (objc_getAssociatedObject(tv, &kREReloadPendingKey)) return;
    objc_setAssociatedObject(tv, &kREReloadPendingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UITableView *weakTV = tv;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *strongTV = weakTV;
        if (!strongTV) return;
        objc_setAssociatedObject(strongTV, &kREReloadPendingKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [strongTV reloadData];
    });
}

// --- 具体 hook ---

static NSInteger REHookNumberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSMutableIndexSet *set = RETableHiddenSet(tv, NO);
    if (set && [set containsIndex:section]) return 0;

    NSInteger (*orig)(id, SEL, UITableView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    return orig ? orig(self, _cmd, tv, section) : 0;
}

static CGFloat REHookHeightForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *indexPath) {
    NSMutableIndexSet *set = RETableHiddenSet(tv, NO);
    if (set && [set containsIndex:indexPath.section]) return 0.0;

    CGFloat (*orig)(id, SEL, UITableView *, NSIndexPath *) = (void *)REOriIMP(self, _cmd);
    return orig ? orig(self, _cmd, tv, indexPath) : UITableViewAutomaticDimension;
}

static CGFloat REHookHeightForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSMutableIndexSet *set = RETableHiddenSet(tv, NO);
    if (set && [set containsIndex:section]) return 0.0;

    CGFloat (*orig)(id, SEL, UITableView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    return orig ? orig(self, _cmd, tv, section) : 0.0;
}

static NSString *REHookTitleForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    NSString *(*orig)(id, SEL, UITableView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    NSString *title = orig ? orig(self, _cmd, tv, section) : nil;
    if (RETableIsDrawer(tv) && RETitleIsPromo(title)) {
        REMarkSectionHidden(tv, section, @"分区标题");
        return nil;
    }
    return title;
}

static UIView *REHookViewForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    UIView *(*orig)(id, SEL, UITableView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    UIView *view = orig ? orig(self, _cmd, tv, section) : nil;
    if (RETableIsDrawer(tv) && view && REViewIsPromo(view)) {
        REMarkSectionHidden(tv, section, @"分区头视图");
        view.hidden = YES;
        return nil;
    }
    return view;
}

static UITableViewCell *REHookCellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *indexPath) {
    UITableViewCell *(*orig)(id, SEL, UITableView *, NSIndexPath *) = (void *)REOriIMP(self, _cmd);
    UITableViewCell *cell = orig ? orig(self, _cmd, tv, indexPath) : nil;
    if (RETableIsDrawer(tv) && cell && REViewIsPromo(cell)) {
        cell.hidden = YES;
        REMarkSectionHidden(tv, indexPath.section, @"推广 cell");
    }
    return cell;
}

static void REHookWillDisplayCell(id self, SEL _cmd, UITableView *tv,
                                  UITableViewCell *cell, NSIndexPath *indexPath) {
    void (*orig)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *) =
        (void *)REOriIMP(self, _cmd);
    if (orig) orig(self, _cmd, tv, cell, indexPath);

    if (RETableIsDrawer(tv) && cell && REViewIsPromo(cell)) {
        cell.hidden = YES;
        REMarkSectionHidden(tv, indexPath.section, @"cell 显示");
    }
}

static void REHookWillDisplayHeader(id self, SEL _cmd, UITableView *tv,
                                    UIView *view, NSInteger section) {
    void (*orig)(id, SEL, UITableView *, UIView *, NSInteger) = (void *)REOriIMP(self, _cmd);
    if (orig) orig(self, _cmd, tv, view, section);

    if (RETableIsDrawer(tv) && view && REViewIsPromo(view)) {
        view.hidden = YES;
        REMarkSectionHidden(tv, section, @"header 显示");
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
        RESwizzleInstance(obj, @selector(tableView:numberOfRowsInSection:),
                          (IMP)REHookNumberOfRows);
        RESwizzleInstance(obj, @selector(tableView:heightForRowAtIndexPath:),
                          (IMP)REHookHeightForRow);
        RESwizzleInstance(obj, @selector(tableView:heightForHeaderInSection:),
                          (IMP)REHookHeightForHeader);
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
    @synchronized (REHiddenLock()) {
        [gREHiddenByClass removeAllObjects];
    }
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
            objc_setAssociatedObject(tv, &kREHiddenSectionsKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [tv reloadData];
        }
    });
}

// ---------------------------------------------------------------------------
// JSON 过滤（信息流广告 / 推荐 / NSFW 等，保留 v2 逻辑）
// ---------------------------------------------------------------------------
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
    for (NSInteger i = (NSInteger)array.count - 1; i >= 0; i--) {
        if (REIsDrawerPromoItem(array[(NSUInteger)i])) {
            [array removeObjectAtIndex:(NSUInteger)i];
            gCntAdStripped++;
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

    // 广告 / 推广帖
    if (REBool(kREFilterPromoted, YES)) {
        if ([type hasSuffix:@"AdPost"] || [type hasPrefix:@"PROMOTED"] ||
            [type isEqualToString:@"REDDIT_PROMOTED"]) {
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

    // 顶层广告 / 推荐容器：按键名通用匹配
    for (NSString *key in [node.allKeys copy]) {
        id value = node[key];
        if (![value isKindOfClass:[NSArray class]]) continue;
        NSString *lower = key.lowercaseString;
        if (REBool(kREFilterPromoted, YES) &&
            ([lower hasSuffix:@"ads"] || [lower containsString:@"adposts"])) {
            node[key] = @[];
            gCntAdStripped++;
        } else if (REBool(kREFilterRecommended, NO) &&
                   [lower containsString:@"recommend"]) {
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

typedef NSURLSessionDataTask *(*REDataTaskIMP)(id, SEL, NSURLRequest *,
                                               void (^)(NSData *, NSURLResponse *, NSError *));

static NSURLSessionDataTask *REHookedDataTask(id self, SEL _cmd, NSURLRequest *request,
                                              void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    NSString *host = request.URL.host.lowercaseString ?: @"";
    BOOL isReddit = [host containsString:@"reddit.com"] ||
                    [host containsString:@"redd.it"];
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
// 设置项
// ---------------------------------------------------------------------------
static NSArray<NSDictionary *> *RERows(void) {
    static NSArray *rows = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rows = @[
            @{ @"k": kREFilterPromoted,      @"t": @"去除广告与推广",
               @"s": @"移除推广帖、广告和赞助内容", @"d": @YES },
            @{ @"k": kREFilterRecommended,   @"t": @"隐藏推荐内容",
               @"s": @"去掉「相似帖子」等推荐注入", @"d": @NO },
            @{ @"k": kREFilterNSFW,          @"t": @"屏蔽 NSFW 内容",
               @"s": @"从信息流中隐藏 NSFW 内容", @"d": @NO },
            @{ @"k": kREHideAwards,          @"t": @"隐藏赞赏徽章",
               @"s": @"移除帖子和评论的赞赏徽章", @"d": @NO },
            @{ @"k": kREHideScores,          @"t": @"隐藏投票数",
               @"s": @"隐藏点赞／点踩数量", @"d": @NO },

            @{ @"k": kREHideDrawerGames,     @"t": @"隐藏侧边栏游戏位",
               @"s": @"移除左侧菜单「Reddit 上的游戏」整块", @"d": @YES },
            @{ @"k": kREHideDrawerResources, @"t": @"隐藏侧边栏资源位",
               @"s": @"移除「资源 / Reddit Pro / Premium」链接", @"d": @YES },
            @{ @"k": kRECollapseAutoMod,     @"t": @"折叠 AutoMod 评论",
               @"s": @"自动收起 AutoMod 机器人的回复", @"d": @NO },
            @{ @"k": kREHidePremium,         @"t": @"隐藏 Premium 推广",
               @"s": @"移除 Premium 横幅、升级提示与入口", @"d": @NO }
        ];
    });
    return rows;
}

static NSInteger RERowCount(void) { return (NSInteger)RERows().count; }
static NSInteger RESectionCount(void) { return 3; }

static NSInteger RERowsInSection(NSInteger section) {
    if (section == 0) return 5;
    if (section == 1) return RERowCount() - 5;
    return 1;   // 诊断
}

static NSInteger RERowIndexForIndexPath(NSIndexPath *indexPath) {
    return indexPath.section == 0 ? indexPath.row : 5 + indexPath.row;
}

// ---------------------------------------------------------------------------
// 诊断信息
// ---------------------------------------------------------------------------
static NSString *REDiagnosticsText(void) {
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"== Hook 状态 ==\n"];
    [text appendFormat:@"已安装 hook: %ld\n", (long)gCntHooksInstalled];
    [text appendFormat:@"接管抽屉表格: %ld\n", (long)gCntDrawerTables];
    [text appendFormat:@"移除抽屉分区: %ld\n", (long)gCntSectionsHidden];
    [text appendString:@"\n== 网络 ==\n"];
    [text appendFormat:@"NSURLSession 命中: %ld\n", (long)gCntURLSession];
    [text appendFormat:@"JSON 解析命中: %ld\n", (long)gCntJSON];
    [text appendFormat:@"JSON 节点处理: %ld\n", (long)gCntNodes];
    [text appendFormat:@"剥离广告/推荐: %ld\n", (long)gCntAdStripped];
    [text appendString:@"\n== 开关 ==\n"];
    for (NSDictionary *row in RERows()) {
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
    if (section == 0) return @"内容过滤";
    if (section == 1) return @"界面精简";
    return @"其他";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"开关即时生效，无需重启 App。";
    if (section == 1) return @"侧边栏开关会在下次打开左侧菜单时立即生效。";
    return @"Reddit 增强 · 适用于 Reddit 2026.46.0（巨魔）\n"
            "Premium 权限由服务器校验，客户端无法真正解锁，本插件只负责隐藏相关推广入口。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 2) {
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
    NSDictionary *row = RERows()[(NSUInteger)index];

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
    if (indexPath.section == 2) {
        REDiagnosticsViewController *diag = [[REDiagnosticsViewController alloc] init];
        [self.navigationController pushViewController:diag animated:YES];
    }
}

- (void)re_toggle:(UISwitch *)sender {
    NSInteger index = sender.tag;
    if (index < 0 || index >= RERowCount()) return;
    NSDictionary *row = RERows()[(NSUInteger)index];
    NSString *key = row[@"k"];

    REBoolSet(key, sender.on);
    [REGroup() synchronize];
    [NSUserDefaults.standardUserDefaults synchronize];

    RELog(@"开关 %@ = %@", row[@"t"], sender.on ? @"开" : @"关");

    if ([key isEqualToString:kREHideDrawerGames] ||
        [key isEqualToString:kREHideDrawerResources]) {
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
static char kREEntryAssociatedKey;

static BOOL REIsExcludedSettingsLike(NSString *hay) {
    NSArray *blocked = @[@"modtools", @"notification", @"translation",
                         @"gender", @"language", @"posttype", @"room",
                         @"chat", @"redditenhancer", @"diagnostic"];
    for (NSString *word in blocked) {
        if ([hay containsString:word]) return YES;
    }
    return NO;
}

static void REInjectEntryIntoPage(UIViewController *vc) {
    if (objc_getAssociatedObject(vc, &kREEntryAssociatedKey)) return;
    objc_setAssociatedObject(vc, &kREEntryAssociatedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (vc.navigationController) {
        UIBarButtonItem *button =
            [[UIBarButtonItem alloc] initWithTitle:@"增强设置"
                                             style:UIBarButtonItemStylePlain
                                            target:[REUIHelper shared]
                                            action:@selector(openSettings)];
        NSArray *right = vc.navigationItem.rightBarButtonItems;
        vc.navigationItem.rightBarButtonItems =
            right.count ? [right arrayByAddingObject:button] : @[ button ];
        RELog(@"设置页注入导航栏入口：%@", NSStringFromClass([vc class]));
        return;
    }

    // SwiftUI 设置页往往没有 UINavigationController → 页面内兜底按钮
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"增强" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.14];
    button.layer.cornerRadius = 13;
    button.accessibilityIdentifier = @"REEntryButton";
    [button addTarget:[REUIHelper shared]
               action:@selector(openSettings)
     forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor
                                              constant:-12],
        [button.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor
                                        constant:8],
        [button.widthAnchor constraintEqualToConstant:62],
        [button.heightAnchor constraintEqualToConstant:26]
    ]];
    RELog(@"设置页注入页面内入口（无导航栏）：%@", NSStringFromClass([vc class]));
}

static void REHookedViewDidAppear(id self, SEL _cmd, BOOL animated) {
    void (*orig)(id, SEL, BOOL) = (void *)REOriIMP(self, _cmd);
    if (orig) orig(self, _cmd, animated);

    if (![self isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)self;
    if ([vc isKindOfClass:[RESettingsViewController class]]) return;
    if ([vc isKindOfClass:[REDiagnosticsViewController class]]) return;

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
        for (NSDictionary *row in RERows()) {
            defaults[row[@"k"]] = row[@"d"];
        }
        // 只注册到 standard：REBool 先读 App Group 的显式值，再回落到
        // standard（含这里的注册默认值）。若把默认值也注册进 App Group，
        // 会盖住用户之前在 standard 里存的开关状态。
        [NSUserDefaults.standardUserDefaults registerDefaults:defaults];

        REInstallNetworkHook();
        REInstallJSONHook();

        RESwizzleClass([UIViewController class],
                       @selector(viewDidAppear:),
                       (IMP)REHookedViewDidAppear);
        RESwizzleClass([UITableView class],
                       @selector(layoutSubviews),
                       (IMP)REHookTableLayout);

        REWriteDrawerCollapseKeys();
        REDiscoverDrawerTables();

        RELog(@"RedditEnhancer v3 已加载（hook %ld 个）", (long)gCntHooksInstalled);
    }
}
