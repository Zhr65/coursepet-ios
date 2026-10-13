package com.coursepet.app.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.coursepet.app.data.ApiClient
import com.coursepet.app.data.ApiException
import com.coursepet.app.data.Store
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * 主界面：账本页。展示后端 /ledger 数据，支持记账与删除。
 * 数据以服务器为准，登录后拉取；增删即时同步。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LedgerScreen(store: Store, onLogout: () -> Unit) {
    val scope = rememberCoroutineScope()
    val client = remember { ApiClient(store.serverUrl) }

    var entries by remember { mutableStateOf<List<ApiClient.LedgerEntry>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    // 记账弹窗状态
    var showAdd by remember { mutableStateOf(false) }

    fun refresh() {
        scope.launch {
            loading = true
            error = null
            try {
                entries = client.listLedger(store.accessToken)
            } catch (e: Exception) {
                error = when (e) {
                    is ApiException -> e.message
                    else -> "网络错误：${e.message ?: "无法连接"}"
                }
            } finally {
                loading = false
            }
        }
    }

    LaunchedEffect(Unit) { refresh() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("账本") },
                actions = {
                    IconButton(onClick = { onLogout() }) {
                        Icon(Icons.AutoMirrored.Filled.Logout, contentDescription = "退出登录")
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showAdd = true }) {
                Icon(Icons.Filled.Add, contentDescription = "记账")
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            // 顶部汇总
            SummaryBar(entries)

            when {
                loading -> Box(
                    Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator() }

                error != null -> Box(
                    Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(error.orEmpty(), color = MaterialTheme.colorScheme.error)
                        Spacer(Modifier.height(12.dp))
                        Button(onClick = { refresh() }) { Text("重试") }
                    }
                }

                entries.isEmpty() -> Box(
                    Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("还没有账单，点右下角 + 记一笔", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }

                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(entries, key = { it.id }) { entry ->
                        EntryRow(
                            entry = entry,
                            onDelete = {
                                scope.launch {
                                    try {
                                        client.deleteLedger(store.accessToken, entry.id)
                                        entries = entries.filterNot { it.id == entry.id }
                                    } catch (e: Exception) {
                                        error = e.message ?: "删除失败"
                                    }
                                }
                            },
                        )
                        HorizontalDivider()
                    }
                }
            }
        }
    }

    if (showAdd) {
        AddLedgerDialog(
            onDismiss = { showAdd = false },
            onConfirm = { amount, category, note ->
                scope.launch {
                    try {
                        client.addLedger(
                            token = store.accessToken,
                            amount = amount,
                            category = category,
                            note = note,
                            date = null,
                        )
                        showAdd = false
                        refresh()
                    } catch (e: Exception) {
                        error = e.message ?: "记账失败"
                    }
                }
            },
        )
    }
}

@Composable
private fun SummaryBar(entries: List<ApiClient.LedgerEntry>) {
    val total = entries.sumOf { it.amount }
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.primaryContainer,
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                "本月支出",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
            Text(
                "¥ %.2f".format(total),
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
            Text(
                "共 ${entries.size} 笔",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
        }
    }
}

@Composable
private fun EntryRow(entry: ApiClient.LedgerEntry, onDelete: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                entry.category,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Medium,
            )
            entry.note?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(
                formatDate(entry.date),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            "¥ %.2f".format(entry.amount),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.width(8.dp))
        IconButton(onClick = onDelete) {
            Icon(Icons.Filled.Delete, contentDescription = "删除", tint = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun AddLedgerDialog(
    onDismiss: () -> Unit,
    onConfirm: (amount: Double, category: String, note: String?) -> Unit,
) {
    var amount by remember { mutableStateOf("") }
    var category by remember { mutableStateOf("餐饮") }
    var note by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("记一笔") },
        text = {
            Column {
                OutlinedTextField(
                    value = amount,
                    onValueChange = { amount = it },
                    label = { Text("金额") },
                    placeholder = { Text("如 12.5") },
                    singleLine = true,
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = category,
                    onValueChange = { category = it },
                    label = { Text("分类") },
                    singleLine = true,
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = note,
                    onValueChange = { note = it },
                    label = { Text("备注（可选）") },
                    singleLine = true,
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    val amt = amount.toDoubleOrNull()
                    if (amt == null || amt <= 0) return@TextButton
                    onConfirm(amt, category.ifBlank { "其他" }, note.ifBlank { "" }.ifEmpty { null })
                },
            ) { Text("确定") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        },
    )
}

private fun formatDate(iso: String): String {
    return try {
        val parsed = java.time.Instant.parse(iso)
        SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault())
            .format(java.util.Date.from(parsed))
    } catch (_: Exception) {
        iso
    }
}
