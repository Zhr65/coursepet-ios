package com.coursepet.app.data

import android.content.Context
import android.content.SharedPreferences

/**
 * 本地配置存储：服务器地址 + 登录态。与 iOS 端 UserDefaults/Keychain 对应。
 * 服务器地址让用户自己填（与 iOS 端 agent.serverURL 一致），不硬编码。
 */
class Store(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("coursepet", Context.MODE_PRIVATE)

    // 服务器地址
    var serverUrl: String
        get() = prefs.getString(KEY_SERVER, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_SERVER, value).apply()

    // 登录态
    var accessToken: String
        get() = prefs.getString(KEY_TOKEN, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_TOKEN, value).apply()

    var refreshToken: String
        get() = prefs.getString(KEY_REFRESH, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_REFRESH, value).apply()

    var username: String
        get() = prefs.getString(KEY_USER, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_USER, value).apply()

    var petName: String
        get() = prefs.getString(KEY_PET, "").orEmpty()
        set(value) = prefs.edit().putString(KEY_PET, value).apply()

    // 是否管理员：决定设置页是否显示「邀请码管理」入口
    var isAdmin: Boolean
        get() = prefs.getBoolean(KEY_IS_ADMIN, false)
        set(value) = prefs.edit().putBoolean(KEY_IS_ADMIN, value).apply()

    val isLoggedIn: Boolean
        get() = serverUrl.isNotBlank() && accessToken.isNotBlank()

    fun logout() {
        prefs.edit()
            .remove(KEY_TOKEN)
            .remove(KEY_REFRESH)
            .remove(KEY_PET)
            .remove(KEY_IS_ADMIN)
            .apply()
        // 保留 serverUrl 和 username，方便下次登录少填一次
    }

    companion object {
        private const val KEY_SERVER = "serverUrl"
        private const val KEY_TOKEN = "accessToken"
        private const val KEY_REFRESH = "refreshToken"
        private const val KEY_USER = "username"
        private const val KEY_PET = "petName"
        private const val KEY_IS_ADMIN = "isAdmin"
    }
}
