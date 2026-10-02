// AODBright —— 锁屏后压暗保持 10 秒再熄灭（完全独立，不依赖 LastLook）
//
// 目标行为：
//   按电源键锁屏 → 屏幕不立即熄灭，背光压到 15% → 保持 10 秒 → 完全熄灭
//
// 实现依据（来自 LastLook.dylib 的符号 dump：AODDim/tools/all.txt）：
//   LastLook 在 iOS 16 上真正引用的 SBBacklightController 选择器是
//     -setBacklightState:source:animated:completion:
//     -_factorToPublishForBacklightState:
//     -_animateBacklightToFactor:duration:source:silently:completion:
//     -shouldTurnOnScreenForBacklightSource:
//     -allowIdleSleep / -screenIsDim / -screenIsOn / -lastBacklightChangeSource
//   而 **没有** -setBacklightFactor:source: —— AODDim 那几版 hook 名字猜错，
//   装上没反应，这是原因之一（另一部分是 dylib 根本没被加载）。
//
// 三处 hook 的分工：
//   ① _factorToPublishForBacklightState:  —— 核心。
//      系统问「这个状态该发布多少背光」，熄灭态本来返回 0；保持期内我们改答 0.15，
//      屏幕于是不灭、只是被压暗。只改返回值、不拦截任何调用，最安全。
//   ② setBacklightState:source:animated:completion:  —— 触发点。
//      拿它传来的 state 反查 ①（调原始实现），factor≈0 的那个 state 就是「熄灭态」，
//      自动标定，完全不需要猜枚举值。
//   ③ _animateBacklightToFactor:duration:source:silently:completion:  —— 兜底。
//      淡出动画直接要 factor=0 时改写成 0.15；10 秒到点又用同一个方法把 factor 拉到 0。
//
// 所有 hook 都先确认方法存在，参数/返回类型再从 method_getTypeEncoding 里读出来
// 决定挂哪个变体 —— 签名猜错会直接搞坏 SpringBoard，这一步不能省。
// 刻意不使用 Logos 宏：纯 ObjC + method_setImplementation，任何编译器都能编，
// 本地就能做语法自检。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <stdarg.h>
#import <limits.h>
#import <pthread.h>
#import <AudioToolbox/AudioToolbox.h>

// ---------------------------------------------------------------------------
// 参数
// ---------------------------------------------------------------------------
static const double    kDimFactor   = 0.15;   // 保持期的背光比例因子（15%）
static const double    kHoldSeconds = 10.0;   // 保持时长
static const long long kOurSource   = 0x414F4442LL;  // 'AODB'，标记我们自己的调用

// ---------------------------------------------------------------------------
// 日志：NSLog + 直接写文件（三条路径，哪条可写由实机决定）
// ---------------------------------------------------------------------------
static int gLogCount = 0;

// 日志落点。顺序即优先级。
//   /var/jb/aodbright_logs/  —— 由 postinst 以 root 建好（0777）并预建文件（0666），
//                                这是本机唯一被证明写得进去的地方（见 AODDim v0.3.5 注释）
//   后三条是历史候选路径，AODDim 实测全被 SpringBoard 的沙箱拦掉，留作兜底并记录 access 结果
static const char *kLogPaths[] = {
    "/var/jb/aodbright_logs/aodbright.log",
    "/var/jb/aodbright.log",
    "/var/mobile/Library/Preferences/aodbright.log",
    "/tmp/aodbright.log",
    NULL
};

// 纯 C 面包屑：不碰任何 ObjC。
// 它跑到了 => dylib 被 dyld 加载且构造函数执行了。与「ObjC 是否可用」严格分开。
static void rawBreadcrumb(const char *what) {
    size_t n = strlen(what);
    for (int i = 0; kLogPaths[i]; i++) {
        int fd = open(kLogPaths[i], O_WRONLY | O_CREAT | O_APPEND, 0666);
        if (fd < 0) continue;
        if (write(fd, what, n) >= 0) write(fd, "\n", 1);
        close(fd);
    }
}

// 通道 B：CFPreferences 面包屑。
// 走 cfprefsd 落盘，真正写文件的是 cfprefsd，不受本进程沙箱限制 ——
// 这是所有越狱插件存偏好的方式，也是绕开前面那个沙箱坑的第二条通道。
// 结果出现在 /var/mobile/Library/Preferences/com.zone.aodbright.plist，Filza 直接可读。
static void prefsBreadcrumb(const char *prog, int pid) {
    CFStringRef key = CFSTR("loadedAt");
    CFStringRef s = CFStringCreateWithFormat(NULL, NULL,
                        CFSTR("AODBright v0.1.1 pid=%d prog=%s"), pid, prog);
    CFPreferencesSetAppValue(key, s, CFSTR("com.zone.aodbright"));
    CFPreferencesSetAppValue(CFSTR("loadedBy"),
        CFStringCreateWithCString(NULL, prog, kCFStringEncodingUTF8),
        CFSTR("com.zone.aodbright"));
    CFPreferencesAppSynchronize(CFSTR("com.zone.aodbright"));
    CFRelease(s);
}

// 通道 C：震动信标。完全不依赖文件系统，也不依赖 ObjC —— 只要加载了就能感觉到。
//   震 1 下 = 已在 SpringBoard 里加载（找到了 SBBacklightController）
//   震 2 下 = 加载了但不在 SpringBoard（只会在设置 App 里出现）
static void *buzzThread(void *arg) {
    int times = (int)(long)arg;
    for (int i = 0; i < times; i++) {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        usleep(400000);
    }
    return NULL;
}

static void buzz(int times) {
    pthread_t t;
    if (pthread_create(&t, NULL, buzzThread, (void *)(long)times) == 0)
        pthread_detach(t);
}

static void blog(NSString *fmt, ...) {
    if (gLogCount > 400) return;
    gLogCount++;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AODBright] %@", s);

    NSString *line = [s stringByAppendingString:@"\n"];
    const char *p = line.UTF8String;
    size_t n = strlen(p);
    for (int i = 0; kLogPaths[i]; i++) {
        int fd = open(kLogPaths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) continue;
        ssize_t w = write(fd, p, n);
        (void)w;
        close(fd);
    }
}

// ---------------------------------------------------------------------------
// 运行状态
// ---------------------------------------------------------------------------
static BOOL            gHolding       = NO;   // 是否处于「压暗保持」中
static BOOL            gInQuery       = NO;   // 我们自己在调原始实现，别被自己的 hook 影响
static BOOL            gOffStateKnown = NO;
static long long       gOffState      = LLONG_MIN;  // 自动标定出的「熄灭态」
static BOOL            gOverrideLogged = NO;
static id              gCtrl          = nil;  // SBBacklightController 实例（从 hook 里拿）
static dispatch_block_t gEndBlock     = nil;  // 10 秒后熄灭的定时块

// ---------------------------------------------------------------------------
// selector / 原始 IMP
// ---------------------------------------------------------------------------
static SEL sel_state;
static SEL sel_factor;
static SEL sel_anim;

static void (*orig_state)(id, SEL, long long, long long, BOOL, id) = NULL;

static double (*orig_factor_d)(id, SEL, long long) = NULL;   // 真实返回 double
static float  (*orig_factor_f)(id, SEL, long long) = NULL;   // 真实返回 float

static void (*orig_anim_dd)(id, SEL, double, double, long long, BOOL, id) = NULL;
static void (*orig_anim_df)(id, SEL, double, float,  long long, BOOL, id) = NULL;
static void (*orig_anim_fd)(id, SEL, float,  double, long long, BOOL, id) = NULL;
static void (*orig_anim_ff)(id, SEL, float,  float,  long long, BOOL, id) = NULL;

static void   beginHold(void);
static void   cancelHold(void);
static void   animCall(double factor, double duration);
static double factorDecide(double orig, long long state);

// ---------------------------------------------------------------------------
// ① 背光因子的核心决策
// ---------------------------------------------------------------------------
static double factorDecide(double orig, long long state) {
    if (orig <= 0.001) {
        // 这个 state 对应的亮度是 0 —— 就是「熄灭态」
        if (!gOffStateKnown || gOffState != state) {
            gOffState = state;
            gOffStateKnown = YES;
            blog(@"标定熄灭态：state=%lld（原始 factor=%.3f）", state, orig);
        }
        if (gHolding && !gInQuery) {
            if (!gOverrideLogged) {
                gOverrideLogged = YES;
                blog(@"覆盖背光：熄灭态 factor 0 → %.2f", kDimFactor);
            }
            return kDimFactor;
        }
    }
    return orig;
}

#define DEFINE_FACTOR_HOOK(SUF, RT)                                       \
    static RT my_factor_##SUF(id self, SEL _cmd, long long state) {       \
        gCtrl = self;                                                     \
        RT o = orig_factor_##SUF(self, _cmd, state);                      \
        return (RT)factorDecide((double)o, state);                        \
    }

DEFINE_FACTOR_HOOK(d, double)
DEFINE_FACTOR_HOOK(f, float)

// 反查某个 state 对应多亮（走原始实现，绕过自己的 hook）
static double factorForState(id ctrl, long long state) {
    if (!sel_factor) return -1.0;
    gInQuery = YES;
    double v = -1.0;
    if (orig_factor_d)      v = orig_factor_d(ctrl, sel_factor, state);
    else if (orig_factor_f) v = (double)orig_factor_f(ctrl, sel_factor, state);
    gInQuery = NO;
    return v;
}

// ---------------------------------------------------------------------------
// ② 状态机入口：既是触发点，也是「屏幕回亮」的取消点
// ---------------------------------------------------------------------------
static void my_state(id self, SEL _cmd, long long state, long long source,
                     BOOL animated, id completion) {
    if (source == kOurSource) {
        orig_state(self, _cmd, state, source, animated, completion);
        return;
    }
    gCtrl = self;

    double f = factorForState(self, state);
    blog(@"state=%lld source=%lld animated=%d → factor=%.3f",
         state, source, (int)animated, f);

    if (f >= 0.0 && f <= 0.001) {
        if (!gHolding) beginHold();
    } else if (gHolding) {
        blog(@"屏幕回亮（state=%lld）→ 取消保持", state);
        cancelHold();
    }

    orig_state(self, _cmd, state, source, animated, completion);
}

// ---------------------------------------------------------------------------
// ③ 淡出动画：兜底拦截 + 10 秒后真正熄屏
// ---------------------------------------------------------------------------
static void animCall(double factor, double duration) {
    if (!gCtrl || !sel_anim) return;
    if (orig_anim_dd)      orig_anim_dd(gCtrl, sel_anim, factor, duration,
                                        kOurSource, YES, nil);
    else if (orig_anim_df) orig_anim_df(gCtrl, sel_anim, factor, (float)duration,
                                        kOurSource, YES, nil);
    else if (orig_anim_fd) orig_anim_fd(gCtrl, sel_anim, (float)factor, duration,
                                        kOurSource, YES, nil);
    else if (orig_anim_ff) orig_anim_ff(gCtrl, sel_anim, (float)factor, (float)duration,
                                        kOurSource, YES, nil);
}

#define DEFINE_ANIM_HOOK(SUF, FT, DT)                                          \
    static void my_anim_##SUF(id self, SEL _cmd, FT factor, DT duration,       \
                              long long source, BOOL silently, id completion) {\
        gCtrl = self;                                                          \
        if (source == kOurSource) {                                            \
            orig_anim_##SUF(self, _cmd, factor, duration, source, silently, completion); \
            return;                                                            \
        }                                                                      \
        if ((double)factor <= 0.001) {                                         \
            blog(@"淡出请求：factor=%.3f source=%lld", (double)factor, source); \
            if (!gHolding) beginHold();                                        \
            if (gHolding) {                                                    \
                orig_anim_##SUF(self, _cmd, (FT)kDimFactor, duration,          \
                                kOurSource, silently, completion);             \
                return;                                                        \
            }                                                                  \
        } else if (gHolding) {                                                 \
            blog(@"屏幕回亮（factor=%.3f）→ 取消保持", (double)factor);          \
            cancelHold();                                                      \
        }                                                                      \
        orig_anim_##SUF(self, _cmd, factor, duration, source, silently, completion); \
    }

DEFINE_ANIM_HOOK(dd, double, double)
DEFINE_ANIM_HOOK(df, double, float)
DEFINE_ANIM_HOOK(fd, float,  double)
DEFINE_ANIM_HOOK(ff, float,  float)

// ---------------------------------------------------------------------------
// 保持期控制
// ---------------------------------------------------------------------------
static void cancelHold(void) {
    if (gEndBlock) {
        dispatch_block_cancel(gEndBlock);
        gEndBlock = nil;
    }
    gHolding = NO;
    gOverrideLogged = NO;
}

static void beginHold(void) {
    if (gHolding) return;
    gHolding = YES;
    gOverrideLogged = NO;
    blog(@"★★ 进入保持：%.0f 秒内把背光压到 %.0f%%", kHoldSeconds, kDimFactor * 100.0);

    dispatch_block_t b = dispatch_block_create(0, ^{
        gEndBlock = nil;
        if (!gHolding) return;
        gHolding = NO;
        gOverrideLogged = NO;
        blog(@"保持结束 → 真正熄灭");

        // 先把这个 state 重新下发一次，让系统重新发布背光（这次不再被我们改写）
        if (gOffStateKnown && orig_state && gCtrl)
            orig_state(gCtrl, sel_state, gOffState, kOurSource, NO, nil);

        // 再兜底：直接把背光淡到 0
        animCall(0.0, 0.25);
    });
    gEndBlock = b;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHoldSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), b);
}

// ---------------------------------------------------------------------------
// 安装
// ---------------------------------------------------------------------------
static void *swizzle(Class cls, SEL sel, void *replacement) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, (IMP)replacement);
    return (void *)orig;
}

// 从 type encoding 里找出前两个数值参数的类型（'f' 或 'd'）
static void parseAnimEncoding(const char *e, char *a, char *b) {
    *a = 0;
    *b = 0;
    const char *q = strstr(e, "@:");
    if (!q) return;
    for (const char *p = q + 2; *p; p++) {
        if (*p == 'd' || *p == 'f') {
            if (!*a) *a = *p;
            else if (!*b) { *b = *p; return; }
        }
    }
}

__attribute__((constructor)) static void AODBrightInit(void) {
    // 第一条：纯 C 面包屑，先于任何 ObjC。它落盘就证明 dylib 被 dyld 加载了。
    rawBreadcrumb("=== AODBright v0.1.1 构造函数已执行 ===");

    int pid = (int)getpid();
    const char *prog = getprogname();

    Class cls = objc_getClass("SBBacklightController");

    // 通道 C：震动信标。1 下 = 在 SpringBoard 里，2 下 = 在别的进程（设置 App）。
    buzz(cls ? 1 : 2);

    // 通道 B：CFPreferences 面包屑（不受沙箱限制的那条）。
    prefsBreadcrumb(prog, pid);

    blog(@"=== AODBright v0.1.1 已加载 pid=%d prog=%s ===", pid, prog);
    blog(@"探针：SBBacklightController=%s  LastLookManager=%s（后者有=LastLook 也在跑，会互相干扰）",
         cls ? "有" : "无",
         objc_getClass("LastLookManager") ? "有" : "无");
    blog(@"access(W_OK): logs=%d jb根=%d prefs=%d tmp=%d",
         access("/var/jb/aodbright_logs", W_OK),
         access("/var/jb", W_OK),
         access("/var/mobile/Library/Preferences", W_OK),
         access("/tmp", W_OK));

    if (!cls) {
        blog(@"本进程没有 SBBacklightController（不是 SpringBoard？），不做事");
        return;
    }

    sel_state  = sel_registerName("setBacklightState:source:animated:completion:");
    sel_factor = sel_registerName("_factorToPublishForBacklightState:");
    sel_anim   = sel_registerName("_animateBacklightToFactor:duration:source:silently:completion:");

    // ① 核心：背光因子
    Method fm = class_getInstanceMethod(cls, sel_factor);
    if (fm) {
        const char *fe = method_getTypeEncoding(fm);
        blog(@"_factorToPublishForBacklightState: enc=%s", fe ? fe : "(null)");
        if (fe && fe[0] == 'd') {
            orig_factor_d = (void *)method_getImplementation(fm);
            method_setImplementation(fm, (IMP)my_factor_d);
            blog(@"✓ 已挂因子 hook（double 版）");
        } else if (fe && fe[0] == 'f') {
            orig_factor_f = (void *)method_getImplementation(fm);
            method_setImplementation(fm, (IMP)my_factor_f);
            blog(@"✓ 已挂因子 hook（float 版）");
        } else {
            blog(@"✗ 因子方法返回类型既不是 float 也不是 double，跳过");
        }
    } else {
        blog(@"✗ 没有 _factorToPublishForBacklightState:（本机 iOS 版本可能不同）");
    }

    // ② 触发点：状态机
    void *so = swizzle(cls, sel_state, (void *)my_state);
    if (so) {
        orig_state = (void (*)(id, SEL, long long, long long, BOOL, id))so;
        Method sm = class_getInstanceMethod(cls, sel_state);
        blog(@"✓ 已挂 state hook enc=%s", method_getTypeEncoding(sm));
    } else {
        blog(@"✗ 没有 setBacklightState:source:animated:completion:");
    }

    // ③ 兜底：淡出动画
    Method am = class_getInstanceMethod(cls, sel_anim);
    if (am) {
        const char *ae = method_getTypeEncoding(am);
        blog(@"_animateBacklightToFactor:... enc=%s", ae ? ae : "(null)");
        char a = 0, b = 0;
        parseAnimEncoding(ae ? ae : "", &a, &b);
        IMP orig = method_getImplementation(am);
        IMP hook = NULL;
        if (a == 'd' && b == 'd')      { orig_anim_dd = (void *)orig; hook = (IMP)my_anim_dd; }
        else if (a == 'd' && b == 'f') { orig_anim_df = (void *)orig; hook = (IMP)my_anim_df; }
        else if (a == 'f' && b == 'd') { orig_anim_fd = (void *)orig; hook = (IMP)my_anim_fd; }
        else if (a == 'f' && b == 'f') { orig_anim_ff = (void *)orig; hook = (IMP)my_anim_ff; }
        if (hook) {
            method_setImplementation(am, hook);
            blog(@"✓ 已挂动画 hook（%c%c 版）", a, b);
        } else {
            blog(@"✗ 动画方法参数类型解析失败（a=%c b=%c），跳过", a ? a : '?', b ? b : '?');
        }
    } else {
        blog(@"✗ 没有 _animateBacklightToFactor:duration:source:silently:completion:");
    }

    blog(@"=== 安装完成：%.0f%% × %.0f 秒 ===", kDimFactor * 100.0, kHoldSeconds);
}