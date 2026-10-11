#include <pl/Mod.hpp>

#include "BindingPoc.h"

namespace {

/// @brief P1 smoke-test mod: uses only the public preloader-android mod API, not LeviLamina core.
class AndroidStub {
public:
    static AndroidStub& instance() {
        static AndroidStub mod;
        return mod;
    }

    AndroidStub() : mSelf(*ll::mod::NativeMod::current()) {}

    [[nodiscard]] ll::mod::NativeMod& getSelf() const { return mSelf; }

    bool load() {
        auto& self = getSelf();
        self.getLogger().info(
            "LeviLamina Android stub: load() id={} name={} version={}",
            self.getId(),
            self.getName(),
            self.getVersion()
        );
        return true;
    }

    bool enable() {
        getSelf().getLogger().info("LeviLamina Android stub: enable()");
        ll::android::poc::run();
        return true;
    }

    bool disable() {
        getSelf().getLogger().info("LeviLamina Android stub: disable()");
        return true;
    }

    bool unload() {
        getSelf().getLogger().info("LeviLamina Android stub: unload()");
        return true;
    }

private:
    ll::mod::NativeMod& mSelf;
};

} // namespace

PL_REGISTER_MOD(AndroidStub, AndroidStub::instance())
