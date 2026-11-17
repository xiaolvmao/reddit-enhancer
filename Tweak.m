//
//  RedditEnhancer — TrollStore / jailed tweak for Reddit 2026.46.0
//  Bundle ID: com.reddit.Reddit   Executable: RedditApp
//
//  Strategy (chosen after static analysis of the real 2026.46.0 binary):
//   * The app is a 194 MB pure-Swift, heavily modularised Mach-O. Almost every
//     class is a Swift mangled symbol (_TtC...) which CANNOT be hooked with
//     the classic Objective-C Method Swizzling used by old tweaks.
//   * The one stable, Objective-C visible hook point is NSURLSession's
//     -dataTaskWithRequest:completionHandler:. Reddit still fetches its
//     GraphQL feed through it, and the ad payload is delivered as JSON.
//     All verified ad/filter JSON keys (adPayload, AdPost, SubredditPost,
//     CellGroup, recommendationContext, isScoreHidden, awardings, isHidden,
//     isNsfw, isInitiallyCollapsed) exist in this exact binary.
//   * The old UIKit settings classes (AppSettingsViewController,
//     UserDrawerViewController) are GONE in 2026.46.0 (settings is SwiftUI).
//     Therefore the settings UI is 100% self-contained UIKit, presented from
//     a floating, draggable entry button. No app-private class is needed.
//
//  Build: Theos (rootless / TrollStore). See Makefile and README.md.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
// Preferences — stored in the app's own sandbox, read live (no respring).
// ---------------------------------------------------------------------------
static NSString *const kREFilterPromoted   = @"RE.filter.promoted";    // 去广告/推广帖
static NSString *const kREFilterRecommended= @"RE.filter.recommended"; // 过滤推荐内容
static NSString *const kREFilterNSFW       = @"RE.filter.nsfw";        // 屏蔽 NSFW
static NSString *const kREHideAwards       = @"RE.hide.awards";        // 隐藏 Awards
static NSString *const kREHideScores       = @"RE.hide.scores";        // 隐藏票数
static NSString *const kRECollapseAutoMod  = @"RE.collapse.automod";   // 折叠 AutoMod
static NSString *const kREHidePremium      = @"RE.hide.premium";       // 隐藏 Premium 推广

static inline BOOL REBool(NSString *key, BOOL fallback) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    id v = [d objectForKey:key];
    return v ? [v boolValue] : fallback;
}

// ---------------------------------------------------------------------------
// JSON filter — mutates the mutable GraphQL response in place.
// This is the same battle-tested approach used by level3tjg/RedditFilter
// (MIT), updated with the keys that actually exist in 2026.46.0.
// ---------------------------------------------------------------------------
static void REFilterNode(NSMutableDictionary *node) {
    if (![node isKindOfClass:NSMutableDictionary.class]) return;
    id rawType = node[@"__typename"];
    NSString *type = [rawType isKindOfClass:NSString.class] ? rawType : nil;

    // Regular feed post
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

    // Promoted / ad posts are injected as their own typenames
    if (REBool(kREFilterPromoted, YES)) {
        if ([type hasSuffix:@"AdPost"] || [type hasPrefix:@"PROMOTED"] ||
            [type isEqualToString:@"REDDIT_PROMOTED"]) {
            node[@"isHidden"] = @YES;
        }
    }

    // Comments
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

    // CellGroup: this is how 2026.46.0 delivers ads & recommendations inline
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
                // Premium / "get coins" upsell cells
                if (REBool(kREHidePremium, NO) &&
                    ([cellType rangeOfString:@"premium" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                     [cellType rangeOfString:@"upsell" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
                    shouldStripCells = YES;
                }
            }
        }
        // Inline ad: adPayload is present on 2026.46.0 (verified in binary)
        if (REBool(kREFilterPromoted, YES) &&
            [node[@"adPayload"] isKindOfClass:NSDictionary.class]) {
            shouldStripCells = YES;
        }
        // Recommended / "similar posts" injection
        if (REBool(kREFilterRecommended, NO)) {
            NSDictionary *rc = node[@"recommendationContext"];
            if ([rc isKindOfClass:NSDictionary.class] &&
                ![rc[@"typeIdentifier"] isEqual:NSNull.null]) {
                shouldStripCells = YES;
            }
        }
        if (shouldStripCells) node[@"cells"] = @[];
    }

    // Top-level ad / recommendation containers.
    // 2026.46.0 changed some of these; we match generically by key name so the
    // filter keeps working when Reddit renames a specific field.
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
    if (depth > 16) return;   // guard against pathological nesting
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
// Hook NSURLSession (the only ObjC-visible network class in this binary)
// ---------------------------------------------------------------------------
static IMP gOriginalDataTask = NULL;
static _Thread_local BOOL gREInFilter = NO;   // recursion guard, per-thread

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
// Secondary universal interception: NSJSONSerialization.
// 2026.46.0 also uses Swift `URLSession.data(for:delegate:)` (async/await)
// which bypasses the completion-handler hook above. Every GraphQL payload is
// eventually deserialized through NSJSONSerialization, so hooking it catches
// those requests too. We force mutable containers so REWalkJSON can filter.
// ---------------------------------------------------------------------------
static IMP gOriginalJSONObject = NULL;

typedef id (*REJSONObjectIMP)(id, SEL, NSData *, NSJSONReadingOptions, NSError **);

static id REHookedJSONObject(id self, SEL _cmd, NSData *data,
                             NSJSONReadingOptions options, NSError **error) {
    // Only touch payloads that look like a Reddit GraphQL response. This keeps
    // the global hook cheap and avoids altering analytics/SDK JSON.
    BOOL looksLikeFeed = NO;
    if (data && data.length >= 8) {
        // Use NSData range search: data.bytes is NOT guaranteed NUL-terminated.
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

    // Force mutable containers so REWalkJSON can filter in place. Returning a
    // mutable object where an immutable one was expected is safe (subclass).
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
// Self-contained settings UI (native iOS switches) + floating entry button
// ---------------------------------------------------------------------------
@interface RESettingsViewController : UITableViewController
@end

static NSArray<NSString *> *RESettingKeys(void) {
    return @[kREFilterPromoted, kREFilterRecommended, kREFilterNSFW,
             kREHideAwards, kREHideScores, kRECollapseAutoMod, kREHidePremium];
}

static NSArray<NSString *> *RESettingTitles(void) {
    return @[@"Remove Ads / Promoted", @"Hide Recommended Posts", @"Block NSFW Content",
             @"Hide Awards", @"Hide Vote Scores", @"Auto-collapse AutoMod",
             @"Hide Premium Upsells"];
}

static NSArray<NSString *> *RESettingSubtitles(void) {
    return @[@"Strip promoted posts, ads and sponsored cells",
             @"Remove suggested / similar post injections",
             @"Hide NSFW posts from your feeds",
             @"Remove award badges from posts and comments",
             @"Hide upvote/downvote counts",
             @"Fold AutoMod comments automatically",
             @"Remove Reddit Premium banners and prompts"];
}

static BOOL REDefaultForIndex(NSInteger i) {
    return (i == 0); // only ad removal is on by default
}

@interface REUIHelper : NSObject
+ (void)openSettings;
+ (void)entryTapped:(id)sender;
+ (void)entryPanned:(UIPanGestureRecognizer *)gesture;
@end

@implementation RESettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Reddit Enhancer";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                       target:self
                                                       action:@selector(re_done)];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"RECell"];
}

- (void)re_done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return RESettingKeys().count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RECell" forIndexPath:indexPath];
    NSInteger row = indexPath.row;
    cell.textLabel.text = RESettingTitles()[row];
    cell.detailTextLabel.text = RESettingSubtitles()[row];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.textColor = [UIColor respondsToSelector:@selector(secondaryLabelColor)]
        ? UIColor.secondaryLabelColor : [UIColor darkGrayColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = REBool(RESettingKeys()[row], REDefaultForIndex(row));
    sw.tag = row;
    [sw addTarget:self action:@selector(re_toggle:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Toggles apply instantly to feed requests — no restart needed.\nReddit Enhancer for Reddit 2026.46.0 (TrollStore).";
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
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
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

+ (void)entryTapped:(id)sender { [self openSettings]; }

+ (void)entryPanned:(UIPanGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    UIWindow *window = [self re_keyWindow];
    CGPoint delta = [gesture translationInView:window];
    CGPoint center = view.center;
    center.x += delta.x;
    center.y += delta.y;
    CGFloat m = 28.0;
    center.x = MAX(m, MIN(window.bounds.size.width - m, center.x));
    center.y = MAX(m, MIN(window.bounds.size.height - m, center.y));
    view.center = center;
    [gesture setTranslation:CGPointZero inView:window];
}

+ (void)installEntry {
    UIWindow *window = [self re_keyWindow];
    if (!window || [window viewWithTag:0x5245]) return;   // 0x5245 = "RE"
    CGFloat size = 46.0;
    UIButton *button = [[UIButton alloc] initWithFrame:CGRectMake(window.bounds.size.width - size - 18,
                                                                  window.bounds.size.height * 0.32,
                                                                  size, size)];
    button.tag = 0x5245;
    button.layer.cornerRadius = size / 2;
    button.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.82];
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.35;
    button.layer.shadowRadius = 6;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    [button setTitle:@"RE" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [button addTarget:self action:@selector(entryTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(entryPanned:)];
    [button addGestureRecognizer:pan];
    [window addSubview:button];
}

@end

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------
__attribute__((constructor)) static void REInitialize(void) {
    @autoreleasepool {
        // register defaults
        NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
        NSArray *keys = RESettingKeys();
        for (NSUInteger i = 0; i < keys.count; i++) defaults[keys[i]] = @(REDefaultForIndex(i));
        [NSUserDefaults.standardUserDefaults registerDefaults:defaults];

        REInstallNetworkHook();
        REInstallJSONHook();

        // Observer token kept alive for the app's lifetime so it is never
        // deallocated. __unused silences the -Werror unused-but-set warning.
        __unused static id reActiveObserver = nil;
        void (^install)(void) = ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [REUIHelper installEntry];
            });
        };
        reActiveObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { install(); }];
        install();
    }
}
