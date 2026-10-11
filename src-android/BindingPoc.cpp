#include "BindingPoc.h"

#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <string_view>
#include <sys/types.h>
#include <unistd.h>

#include "pl/Gloss.h"
#include "pl/Logger.hpp"
#include "pl/Mod.hpp"
#include "pl/memory/Hook.hpp"
#include "pl/memory/Signature.hpp"

namespace ll::android::poc {
namespace {

constexpr std::string_view kGameModule = "libminecraftpe.so";

// 目标版本 1.26.52.3 (arm64-v8a)：JNI_OnLoad 的 vaddr 见 docs 3.7；
// 该 .so 的 .text 段 vaddr 与文件偏移一致，故同一常量亦为文件偏移。
constexpr uintptr_t kJniOnLoadVaddr         = 0x0852e200UL;
constexpr uintptr_t kNativeResizeVaddr      = 0x0852e348UL;
// JNI_OnLoad 序言前 64 字节（2026-10-11 自 APK 直接提取），作为签名扫描靶子。
// 注意：该函数序言前 32 字节在本 .so 中出现 80 次，绝不唯一；取到 49 字节才唯一命中。
// 真实绑定表的每条签名都必须在目标 .so 上验证唯一性（count==1），否则会静默绑到错地址。
constexpr std::string_view kJniOnLoadSig =
    "FF 43 01 D1 FD 7B 03 A9 F4 4F 04 A9 FD C3 00 91 54 D0 3B D5 F3 03 00 AA 88 16 40 F9 A8 83 1F F8 "
    "87 C2 7D 95 E3 03 00 AA C1 F1 FC D0 21 E4 39 91 42 0B FD F0 42 54 0C 91 40 00 80 52 5D C2 7D 95";

pl::log::Logger& logger() { return pl::mod::NativeMod::current()->getLogger(); }

void report(std::string_view id, std::string_view text, bool ok) {
    logger().info("[P2-PoC] {} {} : {}", id, ok ? "OK  " : "FAIL", text);
}

// ---- M1：定位游戏模块与 .text ----
void checkModule() {
    uintptr_t bias     = GlossGetLibBias(kGameModule.data());
    size_t    textSize = 0;
    uintptr_t text     = GlossGetLibSection(kGameModule.data(), ".text", &textSize);
    logger().info(
        "[P2-PoC] M1 bias=0x{:x} .text=0x{:x} size=0x{:x}",
        bias,
        text,
        textSize
    );
    report("M1", "定位 libminecraftpe.so 基址与 .text", bias != 0 && text != 0 && textSize > 0);
}

// ---- M2：导出锚点按名解析并与已知偏移核对 ----
void checkExport() {
    GHandle   handle = GlossOpen(kGameModule.data());
    uintptr_t bias   = GlossGetLibBias(kGameModule.data());
    if (handle == nullptr || bias == 0) {
        report("M2", "GlossOpen/libbias 失败", false);
        return;
    }

    uintptr_t jniOnLoad = GlossSymbol(handle, "JNI_OnLoad", nullptr);
    uintptr_t resize    = GlossSymbol(handle, "Java_com_mojang_minecraftpe_MainActivity_nativeResize", nullptr);

    uintptr_t expectJni    = bias + kJniOnLoadVaddr;
    uintptr_t expectResize = bias + kNativeResizeVaddr;
    bool      ok           = jniOnLoad == expectJni && resize == expectResize;
    logger().info(
        "[P2-PoC] M2 JNI_OnLoad=0x{:x} (期望 0x{:x}) nativeResize=0x{:x} (期望 0x{:x})",
        jniOnLoad,
        expectJni,
        resize,
        expectResize
    );
    report("M2", "导出锚点按名解析且偏移正确", ok);
}

// ---- M3：字节签名扫描 ----
void checkSignature() {
    uintptr_t expect = GlossGetLibBias(kGameModule.data()) + kJniOnLoadVaddr;

    std::string compact;
    for (char c : kJniOnLoadSig) {
        if (c != ' ') compact.push_back(c);
    }
    std::string lower = compact;
    for (char& c : lower) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }

    struct Candidate {
        std::string_view name;
        std::string_view sig;
    };
    Candidate candidates[]{
        {"space-upper",   kJniOnLoadSig},
        {"compact-upper", compact       },
        {"compact-lower", lower         },
    };

    bool ok = false;
    for (auto const& candidate : candidates) {
        uintptr_t resolved = pl::memory::resolveSignature(candidate.sig, kGameModule);
        logger().info("[P2-PoC] M3 fmt={} -> 0x{:x}", candidate.name, resolved);
        if (resolved == expect) {
            ok = true;
            logger().info("[P2-PoC] M3 接受格式: {}", candidate.name);
            break;
        }
    }
    report("M3", "字节签名扫描命中 JNI_OnLoad", ok);
}

// ---- M4：导入槽（GOT）绑定 —— 实测受阻，降级为文档结论 ----
// 实测（v0.3.0/v0.4.0/v0.5.0）：仅调用 GlossGot(自身 handle) 即令进程 signal 6/11 崩溃，
// 与是否改写/调用无关；自身 handle 可由 GlossOpen(basename) 取得，但 GOT 枚举不可用。
// 因此本项不再实际执行，仅记录结论；GOT/PLT 绑定路线需另案排查（见 docs 3.10）。
void checkGotBinding() {
    std::string selfPath = pl::mod::NativeMod::current()->getLibraryPath().string();
    GHandle     selfHandle = GlossOpen(selfPath.c_str());
    if (selfHandle == nullptr) {
        selfHandle = GlossOpen("liblevilamina_stub.so");
    }
    logger().info("[P2-PoC] M4 自身模块 handle={}", static_cast<void*>(selfHandle));
    logger().info("[P2-PoC] M4 SKIP : GlossGot 实测在自身模块上崩溃(signal 6/11)，GOT 路线待另案排查");
}

// ---- M5：ARM64 inline hook + origin 链 ----
std::atomic<int> gGettidHits{0};
pid_t (*gOrigGettid)() = nullptr;

pid_t gettidDetour() {
    gGettidHits.fetch_add(1, std::memory_order_relaxed);
    return gOrigGettid();
}

void checkInlineHook() {
    int ret = pl::memory::hook(
        reinterpret_cast<void*>(&gettid),
        reinterpret_cast<void*>(&gettidDetour),
        reinterpret_cast<void**>(&gOrigGettid),
        pl::memory::HookPriority::Normal
    );

    bool ok = false;
    if (ret == 0 && gOrigGettid != nullptr) {
        pid_t value = gettid();
        ok          = gGettidHits.load() == 1 && value > 0;
        logger().info("[P2-PoC] M5 hook ret={} gettid()->{} hits={}", ret, static_cast<int>(value), gGettidHits.load());
        pl::memory::unhook(reinterpret_cast<void*>(&gettid), reinterpret_cast<void*>(&gettidDetour));
    } else {
        logger().info("[P2-PoC] M5 hook ret={} orig={}", ret, reinterpret_cast<void*>(gOrigGettid));
    }
    report("M5", "inline hook 生效且 origin 可调用", ok);
}

} // namespace

void run() {
    logger().info("[P2-PoC] ===== 开始 P2 绑定机制真机 PoC =====");
    GlossInit(true);
    checkModule();
    checkExport();
    checkSignature();
    checkGotBinding();
    checkInlineHook();
    logger().info("[P2-PoC] ===== P2 PoC 结束 =====");
}

} // namespace ll::android::poc