//
//  RedditEnhancer — TrollStore tweak for Reddit 2026.46.0
//  Bundle ID: com.reddit.Reddit   Executable: RedditApp
//
//  Strategy (based on static analysis of the real 2026.46.0 binary):
//   * The app is a pure-Swift, heavily modularised Mach-O. Almost every class
//     is a mangled Swift symbol (_TtC...) that cannot be swizzled with classic
//     Objective-C method swizzling.
//   * Stable hook point #1: NSURLSession -dataTaskWithRequest:completionHandler:
//     Reddit still fetches GraphQL through it; ads arrive as JSON.
//   * Stable hook point #2: NSJSONSerialization +JSONObjectWithData:options:error:
//     catches Swift async/await URLSession requests too. Verified keys from the
//     binary: adPayload, AdPost, CellGroup, recommendationContext,
//     isScoreHidden, awardings, isHidden, isNsfw, isInitiallyCollapsed.
//   * Settings UI in 2026.46.0 is pure SwiftUI (no AppSettingsViewController).
//     Instead of a floating button, we hook UIViewController's viewDidAppear:
//     (a UIKit system method) and, when the Reddit Settings screen appears,
//     inject a "增强设置" bar button into its navigation bar. Tapping it opens
//     our native UISwitch二级菜单. No app-private class is required.
//
//  Build: Theos library.mk -> plain dylib, no Substrate dependency.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
// 偏好设置 — 存于 App 沙盒，实时读取（无需重启）
// ---------------------------------------------------------------------------
static NSString *const kREFilterPromoted   = @"RE.filter.promoted";
static NSString *const kREFilterRecommended= @"RE.filter.recommended";
static NSString *const kREFilterNSFW       = @"RE.filter.nsfw";
static NSString *const kREHideAwards       = @"RE.hide.awards";
static NSString *const kREHideScores       = @"RE.hide.scores";
static NSString *const kRECollapseAutoMod  = @"RE.collapse.automod";
static NSString *const kREHidePremium      = @"RE.hide.premium";

static inline BOOL REBool(NSString *key, BOOL fallback) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    id v = [d objectForKey:key];
    return v ? [v boolValue] : fallback;
}

// ---------------------------------------------------------------------------
// JSON 过滤 — 就地修改可变的 GraphQL 响应
// 思路参考 level3tjg/RedditFilter (MIT)，针对 2026.46.0 实际结构重写
// ---------------------------------------------------------------------------
static void REFilterNode(NSMutableDictionary *node) {
    if (![node isKindOfClass:NSMutableDictionary.class]) return;
    id rawType = node[@"__typename"];
    NSString *type = [rawType isKindOfClass:NSString.class] ? rawType : nil;

    // 普通帖子
    if ([type isEqualToString:@"SubredditPost"] || [type hasSuffix:@"Post"]) {
        if (REBool(kREHideAwards, NO)) {
            node[@"awardings"] = @[];
            node[@"isGildable"] = @NO;
        }
        if (REBool(kREHideScores, NO)) {
            node[@"isScoreHidden"] = @YES;
        }
        if (REBool(kREFilterNSFW, NO) && [node[@"isNsfw"] boolValue]) {
            node[@"isHidden"] = @YES;
        }
    }

    // 广告/推广帖以独立 typename 注入
    if (REBool(kREFilterPromoted, YES)) {
        if ([type hasSuffix:@"AdPost"] || [type hasPrefix:@"PROMOTED"] ||
            [type isEqualToString:@"REDDIT_PROMOTED"]) {
            node[@"isHidden"] = @YES;
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
            [author isKindOfClass:NSDictionary.class] &&
            [[author[@"id"] description] isEqualToString:@"t2_6l4z3"]) {
            node[@"isInitiallyCollapsed"] = @YES;   // AutoMod
        }
    }

    // CellGroup: 2026.46.0 用它在信息流内注入广告和推荐
    if ([type isEqualToString:@"CellGroup"]) {
        NSArray *cells = node[@"cells"];
        BOOL shouldStripCells = NO;
        if ([cells isKindOfClass:NSArray.class]) {
            for (id cellObj in cells) {
                NSMutableDictionary *cell = cellObj;
                if (![cell isKindOfClass:NSMutableDictionary.class]) continue;
                id rawCellType = cell[@"__typename"];
                NSString *cellType = [rawCellType isKindOfClass:NSString.class] ? rawCellType : @"";
                if ([cellType isEqualToString:@"ActionCell"]) {
                    if (REBool(kREHideAwards, NO)) {
                        cell[@"isAwardHidden"] = @YES;
                        NSMutableDictionary *golden = cell[@"goldenUpvoteInfo"];
                        if ([golden isKindOfClass:NSMutableDictionary.class]) golden[@"isGildable"] = @NO;
                    }
                    if (REBool(kREHideScores, NO)) cell[@"isScoreHidden"] = @YES;
                }
                if (REBool(kREHidePremium, NO) &&
                    ([cellType rangeOfString:@"premium" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                     [cellType rangeOfString:@"upsell" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
                    shouldStripCells = YES;
                }
            }
        }
        if (REBool(kREFilterPromoted, YES) &&
            [node[@"adPayload"] isKindOfClass:NSDictionary.class]) {
            shouldStripCells = YES;
        }
        if (REBool(kREFilterRecommended, NO)) {
            NSDictionary *rc = node[@"recommendationContext"];
            if ([rc isKindOfClass:NSDictionary.class] &&
                ![rc[@"typeIdentifier"] isEqual:NSNull.null]) {
                shouldStripCells = YES;
            }
        }
        if (shouldStripCells) node[@"cells"] = @[];
    }

    // 顶层广告/推荐容器：按键名通用匹配，Reddit 改字段名时仍可工作
    for (NSString *key in [node.allKeys copy]) {
        id value = node[key];
        NSString *lower = key.lowercaseString;
        if ([value isKindOfClass:NSArray.class]) {
            if (REBool(kREFilterPromoted, YES) &&
                ([lower hasSuffix:@"ads"] || [lower containsString:@"adposts"])) {
                node[key] = @[];
            } else if (REBool(kREFilterRecommended, NO) &&
                       [lower containsString:@"recommend"]) {
                node[key] = @[];
            }
        }
    }
}

static void REWalkJSON(id obj, NSUInteger depth) {
    if (depth > 16) return;
    if ([obj isKindOfClass:NSMutableArray.class]) {
        for (id item in (NSMutableArray *)obj) REWalkJSON(item, depth + 1);
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)obj) REWalkJSON(item, depth + 1);
    } else if ([obj isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)obj;
        REFilterNode(dict);
        for (NSString *key in [dict.allKeys copy]) REWalkJSON(dict[key], depth + 1);
    }
}

// ---------------------------------------------------------------------------
// Hook #1: NSURLSession
// ---------------------------------------------------------------------------
static IMP gOriginalDataTask = NULL;
static _Thread_local BOOL gREInFilter = NO;

typedef NSURLSessionDataTask *(*REDataTaskIMP)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));

static NSURLSessionDataTask *REHookedDataTask(id self, SEL _cmd, NSURLRequest *request,
                                              void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    NSString *host = request.URL.host.lowercaseString ?: @"";
    BOOL isGraphQL = [host hasPrefix:@"gql"] || [host hasPrefix:@"oauth"] ||
                     [host isEqualToString:@"reddit.com"] ||
                     [host isEqualToString:@"www.reddit.com"];

    if (!isGraphQL || !completionHandler) {
        return ((REDataTaskIMP)gOriginalDataTask)(self, _cmd, request, completionHandler);
    }

    void (^newHandler)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *outData = data;
            if (data && !error) {
                NSError *jsonError = nil;
                gREInFilter = YES;
                id json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:NSJSONReadingMutableContainers
                                                           error:&jsonError];
                if (json && !jsonError) {
                    REWalkJSON(json, 0);
                    NSData *serialized = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                    if (serialized) outData = serialized;
                }
                gREInFilter = NO;
            }
            completionHandler(outData, response, error);
        };

    return ((REDataTaskIMP)gOriginalDataTask)(self, _cmd, request, newHandler);
}

static void REInstallNetworkHook(void) {
    Class cls = NSClassFromString(@"NSURLSession");
    SEL sel  = @selector(dataTaskWithRequest:completionHandler:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    gOriginalDataTask = method_getImplementation(m);
    method_setImplementation(m, (IMP)REHookedDataTask);
}

// ---------------------------------------------------------------------------
// Hook #2: NSJSONSerialization — 覆盖 Swift async/await 网络路径
// ---------------------------------------------------------------------------
static IMP gOriginalJSONObject = NULL;

typedef id (*REJSONObjectIMP)(id, SEL, NSData *, NSJSONReadingOptions, NSError **);

static id REHookedJSONObject(id self, SEL _cmd, NSData *data,
                             NSJSONReadingOptions options, NSError **error) {
    BOOL looksLikeFeed = NO;
    if (data && data.length >= 8) {
        NSArray<NSData *> *markers = @[
            [@"__typename" dataUsingEncoding:NSUTF8StringEncoding],
            [@"adPayload"  dataUsingEncoding:NSUTF8StringEncoding],
            [@"CellGroup"  dataUsingEncoding:NSUTF8StringEncoding]
        ];
        for (NSData *marker in markers)
            if ([data rangeOfData:marker options:0 range:NSMakeRange(0, data.length)].location != NSNotFound) {
                looksLikeFeed = YES;
                break;
            }
    }
    if (!looksLikeFeed || gREInFilter) {
        return ((REJSONObjectIMP)gOriginalJSONObject)(self, _cmd, data, options, error);
    }

    id result = ((REJSONObjectIMP)gOriginalJSONObject)(self, _cmd, data,
                                                       options | NSJSONReadingMutableContainers,
                                                       error);
    BOOL isMutableContainer = [result isKindOfClass:NSMutableDictionary.class] ||
                              [result isKindOfClass:NSMutableArray.class];
    if (result && isMutableContainer) {
        gREInFilter = YES;
        REWalkJSON(result, 0);
        gREInFilter = NO;
    }
    return result;
}

static void REInstallJSONHook(void) {
    Class cls = NSClassFromString(@"NSJSONSerialization");
    SEL sel  = @selector(JSONObjectWithData:options:error:);
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    gOriginalJSONObject = method_getImplementation(m);
    method_setImplementation(m, (IMP)REHookedJSONObject);
}

// ---------------------------------------------------------------------------
// 设置数据（全中文）
// ---------------------------------------------------------------------------
static NSArray<NSString *> *RESettingKeys(void) {
    return @[kREFilterPromoted, kREFilterRecommended, kREFilterNSFW,
             kREHideAwards, kREHideScores, kRECollapseAutoMod, kREHidePremium];
}

static NSArray<NSString *> *RESettingTitles(void) {
    return @[@"去除广告与推广", @"隐藏推荐内容", @"屏蔽 NSFW 内容",
             @"隐藏赞赏徽章", @"隐藏投票数", @"自动折叠 AutoMod", @"隐藏 Premium 推广"];
}

static NSArray<NSString *> *RESettingSubtitles(void) {
    return @[@"移除推广帖、广告和赞助内容",
             @"去除「相似帖子」等推荐注入",
             @"从信息流中隐藏 NSFW 内容",
             @"移除帖子和评论的赞赏徽章",
             @"隐藏点赞／点踩数量",
             @"自动折叠 AutoMod 机器人的评论",
             @"移除 Reddit Premium 横幅和提示"];
}

static BOOL REDefaultForIndex(NSInteger i) { return (i == 0); }  // 仅去广告默认开

// 两个分组：内容过滤 / 界面精简
static NSInteger RESectionCount(void) { return 2; }
static NSInteger RERowsInSection(NSInteger section) { return section == 0 ? 3 : 4; }
static NSInteger REGlobalIndex(NSIndexPath *indexPath) {
    return indexPath.section == 0 ? indexPath.row : 3 + indexPath.row;
}

// ---------------------------------------------------------------------------
// 二级菜单：原生开关列表
// ---------------------------------------------------------------------------
@interface RESettingsViewController : UITableViewController
@end

@interface REUIHelper : NSObject
+ (void)openSettings;
@end

// Hook UIViewController.viewDidAppear: — 设置页出现时注入导航栏入口
static IMP gOriginalViewDidAppear = NULL;
static char kREEntryAssociatedKey;

static void REHookedViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOriginalViewDidAppear)
        ((void (*)(id, SEL, BOOL))gOriginalViewDidAppear)(self, _cmd, animated);

    UIViewController *vc = (UIViewController *)self;
    if (![vc isKindOfClass:UIViewController.class]) return;
    if ([vc isKindOfClass:[RESettingsViewController class]]) return;  // 排除我们自己的页面
    if (!vc.navigationController) return;                 // 只在有导航栏的页面注入
    if (objc_getAssociatedObject(vc, &kREEntryAssociatedKey)) return;  // 已注入

    // 设置页是 SwiftUI（AppSettingsView -> UIHostingController），运行时类名
    // 不一定稳定，因此标题/类名都做大小写不敏感的宽松匹配：只要出现在本 App
    // 任意「设置」相关页面就注入入口，确保用户一定能找到。
    NSString *title = vc.navigationItem.title ?: @"";
    NSString *cls = NSStringFromClass([vc class]);
    NSString *hay = [NSString stringWithFormat:@"%@ %@", title, cls].lowercaseString;
    BOOL isSettingsPage = [hay containsString:@"settings"] || [hay containsString:@"设置"];
    if (!isSettingsPage) return;

    UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"增强设置"
                                                           style:UIBarButtonItemStylePlain
                                                          target:[REUIHelper class]
                                                          action:@selector(openSettings)];
    NSArray *right = vc.navigationItem.rightBarButtonItems;
    vc.navigationItem.rightBarButtonItems = right.count ? [right arrayByAddingObject:btn] : @[btn];
    objc_setAssociatedObject(vc, &kREEntryAssociatedKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void REInstallUIHook(void) {
    Method m = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (!m) return;
    gOriginalViewDidAppear = method_getImplementation(m);
    method_setImplementation(m, (IMP)REHookedViewDidAppear);
}

@implementation RESettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"增强设置";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                       target:self
                                                       action:@selector(re_done)];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"RECell"];
}

- (void)re_done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return RESectionCount(); }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return RERowsInSection(section);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"内容过滤" : @"界面精简";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RECell" forIndexPath:indexPath];
    NSInteger idx = REGlobalIndex(indexPath);
    cell.textLabel.text = RESettingTitles()[idx];
    cell.detailTextLabel.text = RESettingSubtitles()[idx];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = REBool(RESettingKeys()[idx], REDefaultForIndex(idx));
    sw.tag = idx;
    [sw addTarget:self action:@selector(re_toggle:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != RESectionCount() - 1) return nil;
    return @"开关即时生效，无需重启 App。\nReddit 增强 · 适用于 Reddit 2026.46.0（巨魔）";
}

- (void)re_toggle:(UISwitch *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:RESettingKeys()[sender.tag]];
    [NSUserDefaults.standardUserDefaults synchronize];
}

@end

@implementation REUIHelper

+ (UIWindow *)re_keyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    if (w.isKeyWindow) return w;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

+ (UIViewController *)re_topViewController {
    UIViewController *vc = [self re_keyWindow].rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

+ (void)openSettings {
    UIViewController *top = [self re_topViewController];
    if (!top) return;
    RESettingsViewController *settings = [[RESettingsViewController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
}

@end

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------
__attribute__((constructor)) static void REInitialize(void) {
    @autoreleasepool {
        NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
        NSArray *keys = RESettingKeys();
        for (NSUInteger i = 0; i < keys.count; i++) defaults[keys[i]] = @(REDefaultForIndex(i));
        [NSUserDefaults.standardUserDefaults registerDefaults:defaults];

        REInstallNetworkHook();
        REInstallJSONHook();
        REInstallUIHook();
    }
}
