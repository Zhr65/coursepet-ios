package com.coursepet.app.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * xllite 校园数据集成客户端（与 iOS XlliteClient.swift 对齐）。
 *
 * 同校同学做的"新理 Lite"项目（xllite.sayqz.com）反向协议，证据等级 L2
 * （来自 libapp.so 字符串扫描 + /api/v1/openapi.json + /api/v1/features/detail）。
 *
 * 流程：
 *   1. App 直发 xllite 服务器拿 accessToken（学号+密码只进 EncryptedSharedPrefs）
 *   2. App 用 accessToken 调 /api/v1/run 取 jw.schedule
 *   3. App 解析 JSON 转 CoursePet 课表模型
 *   4. App 推 CoursePet 后端 /campus/sync 入库
 *
 * 后端永远碰不到学号+密码 —— 风险全在 xllite.sayqz.com（已公开）。
 */
class XlliteApi {

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private val jsonMedia = "application/json; charset=utf-8".toMediaType()

    class XlliteException(val code: Int, message: String) : RuntimeException("xllite HTTP $code: $message")

    data class XlliteCourse(
        val day: String,
        val slot: String,
        val title: String,
        val teacher: String?,
        val weeks: String?,
        val sections: String?,
        val location: String?,
    )

    data class XlliteSchedule(
        val term: String,
        val termLabel: String?,
        val courses: List<XlliteCourse>,
    )

    /**
     * 登录拿 accessToken。baseURL 形如 "https://xllite.sayqz.com"（末尾不带 /）。
     */
    suspend fun login(baseUrl: String, username: String, password: String): String =
        withContext(Dispatchers.IO) {
            val body = JSONObject()
                .put("username", username)
                .put("password", password)
                .put("remember", false)
                .toString()
            val req = Request.Builder()
                .url("$baseUrl/api/v1/auth/login")
                .post(body.toRequestBody(jsonMedia))
                .build()
            client.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    if (resp.code == 401 || resp.code == 403) {
                        throw XlliteException(resp.code, "学号或CAS密码错")
                    }
                    throw XlliteException(resp.code, text)
                }
                val obj = JSONObject(text)
                obj.getString("accessToken")
            }
        }

    /**
     * 拉课表。调 /api/v1/run {accessToken, feature:"jw.schedule", params:{term?}}
     * term 形如 "2026-2027-1"；null = 教务默认当前学期
     */
    suspend fun fetchSchedule(baseUrl: String, token: String, term: String? = null): XlliteSchedule =
        withContext(Dispatchers.IO) {
            val params = JSONObject()
            if (!term.isNullOrEmpty()) params.put("term", term)
            val body = JSONObject()
                .put("accessToken", token)
                .put("feature", "jw.schedule")
                .put("params", params)
                .toString()
            val req = Request.Builder()
                .url("$baseUrl/api/v1/run")
                .post(body.toRequestBody(jsonMedia))
                .header("Authorization", "Bearer $token")
                .build()
            client.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    throw XlliteException(resp.code, text)
                }
                val obj = JSONObject(text)
                val data = obj.optJSONObject("data") ?: throw XlliteException(500, "响应缺 data 字段")
                val termResp = data.getString("term")
                val termLabel = data.optString("termLabel").ifEmpty { null }
                val coursesArr = data.getJSONArray("courses")
                val courses = buildList {
                    for (i in 0 until coursesArr.length()) {
                        val c = coursesArr.getJSONObject(i)
                        add(
                            XlliteCourse(
                                day = c.getString("day"),
                                slot = c.getString("slot"),
                                title = c.getString("title"),
                                teacher = c.optString("teacher").ifEmpty { null },
                                weeks = c.optString("weeks").ifEmpty { null },
                                sections = c.optString("sections").ifEmpty { null },
                                location = c.optString("location").ifEmpty { null },
                            )
                        )
                    }
                }
                XlliteSchedule(term = termResp, termLabel = termLabel, courses = courses)
            }
        }

    /**
     * 推 CoursePet 后端 /campus/sync（入校园库）。
     * - coursepetBaseURL: 形如 "https://api.coursepet.app"
     * - coursepetToken: 用户在 CoursePet 的 JWT（现有登录态）
     * - studentId: xllite 返的学号
     * 返回推入的课表条数。
     */
    suspend fun pushToCoursePet(
        coursepetBaseUrl: String,
        coursepetToken: String,
        studentId: String,
        schedule: XlliteSchedule,
    ): Int = withContext(Dispatchers.IO) {
        val courses = JSONArray()
        for (c in schedule.courses) {
            val o = JSONObject()
                .put("student_id", studentId)
                .put("term", schedule.term)
                .put("day", c.day)
                .put("slot", c.slot)
                .put("title", c.title)
            c.teacher?.takeIf { it.isNotEmpty() }?.let { o.put("teacher", it) }
            c.weeks?.takeIf { it.isNotEmpty() }?.let { o.put("weeks", it) }
            c.sections?.takeIf { it.isNotEmpty() }?.let { o.put("sections", it) }
            c.location?.takeIf { it.isNotEmpty() }?.let { o.put("location", it) }
            courses.put(o)
        }
        val body = JSONObject()
            .put("student_id", studentId)
            .put("term", schedule.term)
            .put("courses", courses)
            .toString()
        val req = Request.Builder()
            .url("$coursepetBaseUrl/campus/sync")
            .post(body.toRequestBody(jsonMedia))
            .header("Authorization", "Bearer $coursepetToken")
            .build()
        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                throw XlliteException(resp.code, text)
            }
            val obj = JSONObject(text)
            obj.optInt("inserted", 0)
        }
    }

    /**
     * 拉 CoursePet 后端已存课表（多端同步用）
     */
    suspend fun listCoursePetCampus(
        coursepetBaseUrl: String,
        coursepetToken: String,
        term: String? = null,
    ): JSONArray = withContext(Dispatchers.IO) {
        val url = if (term.isNullOrEmpty()) {
            "$coursepetBaseUrl/campus/courses"
        } else {
            val encoded = java.net.URLEncoder.encode(term, "UTF-8")
            "$coursepetBaseUrl/campus/courses?term=$encoded"
        }
        val req = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $coursepetToken")
            .get()
            .build()
        client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                throw XlliteException(resp.code, text)
            }
            // 响应是 JSONArray（不像 ledger 包了 .entries）
            JSONArray(text)
        }
    }
}
