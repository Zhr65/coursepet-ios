package com.coursepet.app.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * 后端 API 客户端。与 iOS 端 AgentRemoteClient 对应，契约完全一致：
 *   - 登录 POST /auth/login -> {access_token, refresh_token, pet_name}
 *   - 认证头 Authorization: Bearer <access_token>
 *   - 账本 GET/POST /ledger, DELETE /ledger/{id}
 *
 * 服务器地址由用户填写（与 iOS 端 agent.serverURL 一致），默认留空。
 */
class ApiClient(private val baseUrl: String) {

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private val jsonMedia = "application/json; charset=utf-8".toMediaType()

    data class AuthResult(
        val accessToken: String,
        val refreshToken: String?,
        val petName: String,
        val isAdmin: Boolean = false,
    )

    data class LedgerEntry(
        val id: Long,
        val amount: Double,
        val category: String,
        val note: String?,
        val date: String,
    )

    /** 登录，返回 token。抛异常表示失败（网络/凭证错）。 */
    suspend fun login(username: String, password: String): AuthResult =
        withContext(Dispatchers.IO) {
            val body = JSONObject()
                .put("username", username)
                .put("password", password)
                .toString()
            val req = Request.Builder()
                .url("$baseUrl/auth/login")
                .post(body.toRequestBody(jsonMedia))
                .build()
            client.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    throw ApiException(parseError(text) ?: "登录失败(${resp.code})")
                }
                val obj = JSONObject(text)
                AuthResult(
                    accessToken = obj.getString("access_token"),
                    refreshToken = obj.optString("refresh_token").ifEmpty { null },
                    petName = obj.optString("pet_name", ""),
                    isAdmin = obj.optBoolean("is_admin", false),
                )
            }
        }

    /** 注册。需要邀请码（除非服务端 REGISTER_OPEN=true）。成功后 token 落本地等同登录。 */
    suspend fun register(
        username: String,
        password: String,
        invite: String,
        petName: String = "小狼",
    ): AuthResult = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("username", username)
            .put("password", password)
            .put("pet_name", petName)
            .put("invite", invite.trim().uppercase())
            .toString()
        val req = Request.Builder()
            .url("$baseUrl/auth/register")
            .post(body.toRequestBody(jsonMedia))
            .build()
        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                throw ApiException(parseError(text) ?: "注册失败(${resp.code})")
            }
            val obj = JSONObject(text)
            AuthResult(
                accessToken = obj.getString("access_token"),
                refreshToken = obj.optString("refresh_token").ifEmpty { null },
                petName = obj.optString("pet_name", ""),
                isAdmin = obj.optBoolean("is_admin", false),
            )
        }
    }

    /** 拉取当前用户全部账目（服务端已按时间倒序）。 */
    suspend fun listLedger(token: String): List<LedgerEntry> =
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url("$baseUrl/ledger")
                .header("Authorization", "Bearer $token")
                .get()
                .build()
            client.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    throw ApiException(parseError(text) ?: "拉取账本失败(${resp.code})")
                }
                val arr = JSONObject(text).getJSONArray("entries")
                buildList {
                    for (i in 0 until arr.length()) {
                        val o = arr.getJSONObject(i)
                        add(
                            LedgerEntry(
                                id = o.getLong("id"),
                                amount = o.getDouble("amount"),
                                category = o.optString("category", "其他"),
                                note = o.optString("note").ifEmpty { null },
                                date = o.getString("date"),
                            )
                        )
                    }
                }
            }
        }

    /** 记一笔账。amount 支出为正数；date 为 ISO8601 可空。 */
    suspend fun addLedger(
        token: String,
        amount: Double,
        category: String,
        note: String?,
        date: String?,
    ): LedgerEntry = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("amount", amount)
            .put("category", category)
        if (note != null) body.put("note", note)
        if (date != null) body.put("date", date)
        val req = Request.Builder()
            .url("$baseUrl/ledger")
            .header("Authorization", "Bearer $token")
            .post(body.toString().toRequestBody(jsonMedia))
            .build()
        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                throw ApiException(parseError(text) ?: "记账失败(${resp.code})")
            }
            val o = JSONObject(text)
            LedgerEntry(
                id = o.getLong("id"),
                amount = o.getDouble("amount"),
                category = o.optString("category", "其他"),
                note = o.optString("note").ifEmpty { null },
                date = o.getString("date"),
            )
        }
    }

    /** 删一笔账（仅限本人）。 */
    suspend fun deleteLedger(token: String, id: Long): Boolean =
        withContext(Dispatchers.IO) {
            val req = Request.Builder()
                .url("$baseUrl/ledger/$id")
                .header("Authorization", "Bearer $token")
                .delete()
                .build()
            client.newCall(req).execute().use { resp ->
                if (resp.code == 404) return@withContext false
                if (!resp.isSuccessful) {
                    val text = resp.body?.string().orEmpty()
                    throw ApiException(parseError(text) ?: "删除失败(${resp.code})")
                }
                true
            }
        }

    private fun parseError(text: String): String? {
        return try {
            val obj = JSONObject(text)
            obj.optString("detail")
        } catch (_: Exception) {
            null
        }
    }
}

class ApiException(message: String) : Exception(message)
