package com.coursepet.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import com.coursepet.app.data.Store
import com.coursepet.app.ui.LedgerScreen
import com.coursepet.app.ui.LoginScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val store = Store(applicationContext)

        setContent {
            CoursePetTheme {
                var loggedIn by remember { mutableStateOf(store.isLoggedIn) }

                if (loggedIn) {
                    LedgerScreen(
                        store = store,
                        onLogout = {
                            store.logout()
                            loggedIn = false
                        },
                    )
                } else {
                    LoginScreen(
                        store = store,
                        onLoggedIn = { loggedIn = true },
                    )
                }
            }
        }
    }
}

@Composable
fun CoursePetTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val colorScheme = if (darkTheme) {
        darkColorScheme(
            primary = Color(0xFF8AB4F8),
            primaryContainer = Color(0xFF1E3A5F),
        )
    } else {
        lightColorScheme(
            primary = Color(0xFF2D6CDF),
            primaryContainer = Color(0xFFD6E3FF),
        )
    }
    MaterialTheme(
        colorScheme = colorScheme,
        content = content,
    )
}
