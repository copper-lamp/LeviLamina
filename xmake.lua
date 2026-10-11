add_rules("mode.release", "mode.debug")

set_xmakever("3.0.0")

add_repositories("levimc-repo " .. (get_config("levimc_repo") or "https://github.com/LiteLDev/xmake-repo.git"))

local is_windows  = is_plat("windows")
local is_linux    = is_plat("linux")
local is_android  = is_plat("android")

local is_server = is_config("target_type", "server")

-- Dependencies from xmake-repo.
if is_android then
-- Android 目标（P1 空转 mod）当前只需 fmt；
-- 其余依赖均为 Windows/Linux 形状，待平台层移植时再逐个补齐。
add_requires("fmt 11.2.0")
else
add_requires("ctre 3.8.1")
add_requires("entt v4.0.0")
add_requires("expected-lite v0.8.0")
add_requires("fmt 11.2.0")
add_requires("gsl v4.2.0")
add_requires("glm 1.0.1")
add_requires("leveldb 1.23")
add_requires("magic_enum v0.9.7")
add_requires("nlohmann_json v3.12.0")
add_requires("rapidjson 2025.02.05")
add_requires("type_safe v0.2.4")
add_requires("mimalloc v3.5.0")
add_requires("cpr[ssl=y] 1.11.1")
add_requires("parallel-hashmap v2.0.0")
add_requires("concurrentqueue v1.0.4")
add_requires("stb 2025.03.14")
add_requires("zlib v1.3.2")

-- Dependencies from levimc-repo.
add_requires("pcg_cpp v1.0.0")
add_requires("pfr 2.1.1")
add_requires("demangler v17.0.7")
add_requires("levibuildscript 0.6.1")
add_requires("preloader v1.16.2")
add_requires("symbolprovider v1.3.0")
add_requires("trampoline 2024.11.7")
end

if is_windows then
add_requires("libhat 0.4.0")
set_toolchains("clang-cl")
end

if is_linux then
set_toolchains("clang")
end

if is_android then
set_toolchains("ndk")
end

if has_config("tests") then
    add_requires("gtest")
end

if is_server then
    if is_windows then
        add_requires("bedrockdata v26.51.1-server.10")
    end
else
    if is_windows then
        add_requires("bedrockdata v26.51.1-client.10")
    end
end

option("levimc_repo")
    set_default("https://github.com/LiteLDev/xmake-repo.git")
    set_showmenu(true)
    set_description("Set the levimc-repo path or url")
option_end()

option("publish")
    set_default(false)
    set_showmenu(true)
option_end()

option("tests")
    set_default(false)
    set_showmenu(true)
    set_description("Enable tests")
option_end()

option("target_type")
    set_default("server")
    set_showmenu(true)
    set_values("server", "client")
option_end()

option("preloader_android_root")
    set_default("")
    set_showmenu(true)
    set_description("Path to the LiteLDev/preloader-android checkout (android target only)")
option_end()

if is_android then
    set_defaultarchs("android|arm64-v8a")
    set_allowedarchs("android|arm64-v8a")
elseif is_server then
    set_defaultarchs("windows|x64")
    set_allowedarchs("windows|x64", "linux|x86_64")
else
    set_defaultarchs("windows|x64")
    set_allowedarchs("windows|x64")
end

if is_windows and not has_config("vs_runtime") then
    set_runtimes("MD")
end

if is_linux then
    set_runtimes("c++_shared")
end

if is_android then
    -- Android (arm64-v8a) 分支：P1 阶段只产出可被 LeviLaunchroid 加载的空转 mod，
    -- 用于验证 preload-native 加载契约与 NDK 工具链。
    -- 完整客户端适配方案见 D:\LL\docs\安卓客户端适配.md。
    -- 主目标 LeviLamina 目前尚不支持 android，故整体跳过。
    local preloaderAndroidRoot = get_config("preloader_android_root")
    if not preloaderAndroidRoot or preloaderAndroidRoot == "" then
        preloaderAndroidRoot = os.getenv("PRELOADER_ANDROID_ROOT")
    end
    if not preloaderAndroidRoot or preloaderAndroidRoot == "" then
        preloaderAndroidRoot = "$(projectdir)/../libs/preloader-android"
    end

    target("LeviLaminaAndroidStub")
        set_kind("shared")
        set_basename("levilamina_stub")
        set_languages("c++20")
        set_symbols("debug")
        add_files("src-android/**.cpp")
        -- /src 用于引入 SDK 私有的 pl/Gloss.h（GlossHook 的 C 接口，非安装头）。
        add_includedirs("src-android", preloaderAndroidRoot .. "/include", preloaderAndroidRoot .. "/src")
        add_packages("fmt")
        add_defines("LL_PLAT_C")
        add_cxflags(
            "-Wall",
            "-Wextra",
            "-fvisibility=hidden",
            "-fvisibility-inlines-hidden",
            "-Wno-unused-command-line-argument"
        )
        -- 必须与 Launcher 内置的 libpreloader.so 建立 DT_NEEDED 关系：
        -- ModNativeLoader 先 System.load(mod)（RTLD_LOCAL），preloader 的导出符号
        -- （如 pl::mod::NativeMod::current()）对 mod 不可见；只有 DT_NEEDED 才能让
        -- 动态链接器在 dlopen(mod) 时一并加载并绑定 preloader。官方 examples/full-cpp-mod
        -- 亦是通过 link preloader target 达到同样效果。
        add_linkdirs(preloaderAndroidRoot .. "/prebuilt/arm64-v8a")
        add_shflags(
            "-Wl,--no-as-needed",
            "-lpreloader",
            "-Wl,--unresolved-symbols=ignore-all",
            {force = true}
        )
        on_config(function (target)
            -- NDK toolchain 的 C++ STL 由**全局** config "runtimes" 决定
            -- （xmake/toolchains/ndk/load.lua: `config.get("runtimes") or ...`，缺省为 c++_static），
            -- 而 target 级 set_runtimes 对它无效、xmake.lua 也改不了全局 config，
            -- 只能靠命令行开关。MCBE 自身链接 libc++_shared.so，必须对齐，
            -- 否则同进程内会出现两份 C++ 运行时。此处强制校验，避免静默产出错误产物。
            if get_config("runtimes") ~= "c++_shared" then
                raise("LeviLamina android: 需以 --runtimes=c++_shared 配置（当前为 " ..
                      tostring(get_config("runtimes")) .. "）")
            end
        end)
        after_build(function (target)
            os.cp("src-android/manifest.json", target:targetdir())
        end)
else
target("LeviLamina")
    add_rules("@levibuildscript/linkrule")
    set_languages("c++20")
    set_kind("shared")
    set_symbols("debug")
    add_files("src/**.cpp")
    add_files("src/**.rc")
    set_configdir("$(builddir)/config")
    set_configvar("LL_WORKSPACE_FOLDER", "$(projectdir)")
    add_configfiles("src/(ll/core/Version.h.in)")
    add_headerfiles("src/(ll/api/**.h)", "src/(mc/**.h)")
    add_includedirs("src", "$(builddir)/config")
    set_pcxxheader("src/ll/api/Global.h")
    add_packages("demangler", "mimalloc", "ctre", "cpr", "trampoline", "preloader")
    add_packages(
        "entt",
        "expected-lite",
        "fmt",
        "gsl",
        "glm",
        "leveldb",
        "magic_enum",
        "nlohmann_json",
        "rapidjson",
        "type_safe",
        "pcg_cpp",
        "pfr",
        "symbolprovider",
        "bedrockdata",
        "parallel-hashmap",
        "concurrentqueue",
        "stb",
        "zlib",
        {public = true}
    )
    add_defines("LL_EXPORT")
    add_defines(
        "FMT_USE_FULL_CACHE_DRAGONBOX=1",
        "ENTT_PACKED_PAGE=128",
        "ENTT_SPARSE_PAGE=4096",
        {public = true}
    )

    if not is_windows then
        add_cxxflags("clang::-Wno-invalid-offsetof")
        add_defines(
            "__GCC_DESTRUCTIVE_SIZE=64",
            "__GCC_CONSTRUCTIVE_SIZE=64",
            {tools = {"clang"}}
        )
    end

    -- work around to enable c++23

    if is_windows then
        -- msstl
        add_defines("_HAS_CXX23=1")
    else
        -- libc++
        add_cxxflags("clang::-stdlib=libc++")
        add_defines("_LIBCPP_STD_VER=23")
    end

    if is_windows then
        add_packages("libhat")
        add_syslinks("Version", "DbgHelp", "dwrite")
        add_defines(
            "_AMD64_",
            "NOMINMAX",
            "UNICODE",
            "WIN32_LEAN_AND_MEAN"
        )
        set_exceptions("none")
        add_cxflags(
            "/utf-8",
            "/permissive-",
            "/EHa",
            "/W4",
            "/w44265",
            "/w44289",
            "/w44296",
            "/w45263",
            "/w44738"
        )
        add_cxflags(
            "/EHs",
            "-Wno-microsoft-cast",
            "-Wno-invalid-offsetof",
            "-Wno-c++2b-extensions",
            "-Wno-microsoft-include",
            "-Wno-overloaded-virtual",
            "-Wno-ignored-qualifiers",
            "-Wno-missing-field-initializers",
            "-Wno-potentially-evaluated-expression",
            "-Wno-pragma-system-header-outside-header",
            {tools = {"clang_cl"}}
        )
    end

    if is_server then
        add_headerfiles("src-server/(ll/api/**.h)", "src-server/(mc/**.h)")
        add_includedirs("src-server")
        add_files("src-server/**.cpp")
        add_defines("LL_PLAT_S")
    else
        if is_windows then
            add_syslinks("dxgi", "runtimeobject", "gdi32")
        end
        add_headerfiles("src-client/(ll/api/**.h)", "src-client/(mc/**.h)")
        add_includedirs("src-client")
        add_defines("LL_PLAT_C")
        add_files("src-client/**.cpp")
        add_cxflags("/wd4273")
        add_shflags("/IGNORE:4217")
    end

    if has_config("tests") then
        add_defines("LL_DEBUG")
        add_packages("gtest")
            add_includedirs("src-test/common/")
            add_files("src-test/common/**.cpp")
        if is_server then
            add_includedirs("src-test/server/")
            add_files("src-test/server/**.cpp")
        else
            add_includedirs("src-test/client/")
            add_files("src-test/client/**.cpp")
        end
        before_build(function (target)
            headers = ""
            for _,x in ipairs(os.files("src/**.h")) do
                headers = headers.."#include \""..path.relative(x, "src/").."\"\n"
            end
            file = io.open("src-test/common/include_all.cpp", "w")
            file:write(headers)
            file:close()
        if is_server then
            headers = ""
            for _,x in ipairs(os.files("src-server/**.h")) do
                headers = headers.."#include \""..path.relative(x, "src-server/").."\"\n"
            end
            file = io.open("src-test/server/include_all.cpp", "w")
            file:write(headers)
            file:close()
        else
            headers = ""
            for _,x in ipairs(os.files("src-client/**.h")) do
                headers = headers.."#include \""..path.relative(x, "src-client/").."\"\n"
            end
            file = io.open("src-test/client/include_all.cpp", "w")
            file:write(headers)
            file:close()
        end
        end)
        after_build(function (target)
            io.writefile("src-test/common/include_all.cpp", "// auto gen when build test\n")
            if is_server then
                io.writefile("src-test/server/include_all.cpp", "// auto gen when build test\n")
            else
                io.writefile("src-test/client/include_all.cpp", "// auto gen when build test\n")
            end
        end)
    end

    if has_config("publish") then
        add_defines("LL_VERSION_PUBLISH")
    end

    if is_mode("debug") then
        add_defines("LL_DEBUG")
    end

    if not is_windows then
        remove_files("./**/*_win.*")
        remove_files("./**/*_windows.*")
        remove_files("./**/win/**.*")
        remove_headerfiles("./**/win/**.*")
    end
    if not is_linux then
        remove_files("./**/*_linux.*")
        remove_files("./**/linux/**.*")
        remove_headerfiles("./**/linux/**.*")
    end

    on_config(function (target)
        -- vs_runtime can not be set to MDd or MTd.
        if has_config("vs_runtime") and (get_config("vs_runtime"):endswith("d")) then
            raise("LeviLamina: vs_runtime can not be set to MDd or MTd")
        end
    end)

    on_load(function (target)
        import("core.base.json")
        local tag = os.iorun("git describe --tags --abbrev=0 --always")
        local major, minor, patch, suffix = tag:match("v(%d+)%.(%d+)%.(%d+)(.*)")
        if not major then
            print("Failed to parse version tag, using version from tooth.json")
            tag = json.loadfile("tooth.json")["version"]
            major, minor, patch, suffix = tag:match("(%d+)%.(%d+)%.(%d+)(.*)")
        end
        local versionStr =  major.."."..minor.."."..patch
        if suffix then
            prerelease = suffix:match("-(.*)")
            if prerelease then
                prerelease = prerelease:gsub("\n", "")
            end
            if prerelease then
                target:set("configvar", "LL_VERSION_PRERELEASE", prerelease)
                versionStr = versionStr.."-"..prerelease
            end
        end
        target:set("configvar", "LL_VERSION_MAJOR", major)
        target:set("configvar", "LL_VERSION_MINOR", minor)
        target:set("configvar", "LL_VERSION_PATCH", patch)

        if not has_config("publish") then
            local hash = os.iorun("git rev-parse --short HEAD")
            versionStr = versionStr.."+"..hash:gsub("\n", "")
        end

        target:add("rules", "@levibuildscript/modpacker",{
               modVersion = versionStr
           })
    end)
end
