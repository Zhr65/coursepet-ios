# ── 保留 OKHttp / Okio 内部类 ───────────────────────
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-keep class okhttp3.** { *; }
-keep class okio.** { *; }

# ── 保留 Kotlin 协程 ─────────────────────────────
-keep class kotlin.coroutines.Continuation
-keep class kotlin.Metadata { *; }

# ── 保留 Compose 运行时 ──────────────────────────
-keepclassmembers class androidx.compose.runtime.** { *; }

# ── 保留签名/调试信息（崩溃栈可读）──────────────
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
