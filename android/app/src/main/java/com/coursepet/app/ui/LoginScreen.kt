package com.coursepet.app.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import kotlinx.coroutines.launch
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.coursepet.app.data.ApiClient
import com.coursepet.app.data.ApiException
import com.coursepet.app.data.Store

/**
 * 登录页：填服务器地址 + 账号密码，登录后进入主界面。
 * 服务器地址与 iOS 端 agent.serverURL 是同一个，两边账号数据互通。
 */
@Composable
fun LoginScreen(store: Store, onLoggedIn: () -> Unit) {
    var server by remember { mutableStateOf(store.serverUrl) }
    var username by remember { mutableStateOf(store.username) }
    var password by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(48.dp))
        Text("CoursePet", style = MaterialTheme.typography.headlineLarge)
        Text("课程表 · 电子宠物 · AI 管家", style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.height(32.dp))

        OutlinedTextField(
            value = server,
            onValueChange = { server = it },
            label = { Text("服务器地址") },
            placeholder = { Text("https://你的服务器域名") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = username,
            onValueChange = { username = it },
            label = { Text("用户名") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = password,
            onValueChange = { password = it },
            label = { Text("密码") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(24.dp))

        if (error != null) {
            Text(
                text = error.orEmpty(),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
            )
            Spacer(Modifier.height(12.dp))
        }

        Button(
            onClick = {
                val url = server.trim().trimEnd('/')
                if (url.isBlank() || username.isBlank() || password.isBlank()) {
                    error = "请填写服务器地址、用户名和密码"
                    return@Button
                }
                loading = true
                error = null
                scope.launch {
                    try {
                        val client = ApiClient(url)
                        val auth = client.login(username, password)
                        store.serverUrl = url
                        store.username = username
                        store.accessToken = auth.accessToken
                        auth.refreshToken?.let { store.refreshToken = it }
                        store.petName = auth.petName
                        onLoggedIn()
                    } catch (e: ApiException) {
                        error = e.message
                    } catch (e: Exception) {
                        error = "网络错误：${e.message ?: "无法连接服务器"}"
                    } finally {
                        loading = false
                    }
                }
            },
            enabled = !loading,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (loading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    strokeWidth = 2.dp,
                )
            } else {
                Text("登录")
            }
        }

        Spacer(Modifier.height(16.dp))
        Text(
            "与 iPhone 端同一账号，账本数据自动同步",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
