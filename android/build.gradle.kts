// 根构建脚本：声明插件版本（apply false，子模块按需 apply）
// Kotlin 1.9.x 用 composeOptions 配 Compose 编译器，无需单独的 compose 插件
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
