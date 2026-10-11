#pragma once

namespace ll::android::poc {

/// @brief P2 绑定机制真机 PoC。
///
/// 依次验证：模块定位（libminecraftpe.so 基址/.text）、导出锚点按名解析、
/// 字节签名扫描、导入槽（GOT）绑定、ARM64 inline hook + origin 链。
/// 仅在 Android mod 的 enable() 生命周期内调用。
void run();

} // namespace ll::android::poc