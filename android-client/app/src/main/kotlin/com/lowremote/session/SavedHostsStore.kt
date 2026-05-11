package com.lowremote.session

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.lowremote.model.RemoteDevice
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

// ── DataStore singleton ───────────────────────────────────────────────────────
private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "lowremote_prefs")

// ── Serialisable host entry ───────────────────────────────────────────────────
@Serializable
data class SavedHost(
    val id: String,          // uuid-style unique key
    val label: String,       // user-facing name, e.g. "办公室 Mac"
    val host: String,        // IP or hostname
    val tcpPort: Int,
    val udpPort: Int,
)

fun SavedHost.toRemoteDevice() = RemoteDevice(
    name    = label,
    host    = host,
    tcpPort = tcpPort,
    udpPort = udpPort,
)

// ── Store ─────────────────────────────────────────────────────────────────────
class SavedHostsStore(private val context: Context) {

    companion object {
        private val KEY_HOSTS    = stringPreferencesKey("saved_hosts")
        private val KEY_SETTINGS = stringPreferencesKey("app_settings")
        private val json = Json { ignoreUnknownKeys = true }
    }

    // ── Hosts ─────────────────────────────────────────────────────────────────

    val hosts: Flow<List<SavedHost>> = context.dataStore.data.map { prefs ->
        val raw = prefs[KEY_HOSTS] ?: return@map emptyList()
        runCatching { json.decodeFromString<List<SavedHost>>(raw) }.getOrElse { emptyList() }
    }

    suspend fun addHost(host: SavedHost) {
        context.dataStore.edit { prefs ->
            val current = decode(prefs[KEY_HOSTS])
            val updated = current.filterNot { it.id == host.id } + host
            prefs[KEY_HOSTS] = json.encodeToString(updated)
        }
    }

    suspend fun removeHost(id: String) {
        context.dataStore.edit { prefs ->
            val current = decode(prefs[KEY_HOSTS])
            prefs[KEY_HOSTS] = json.encodeToString(current.filterNot { it.id == id })
        }
    }

    private fun decode(raw: String?): List<SavedHost> {
        raw ?: return emptyList()
        return runCatching { json.decodeFromString<List<SavedHost>>(raw) }.getOrElse { emptyList() }
    }

    // ── App settings ──────────────────────────────────────────────────────────

    @Serializable
    data class AppSettings(
        val lockPortrait: Boolean = false,
        val defaultFps:   Int     = 60,
    )

    val settings: Flow<AppSettings> = context.dataStore.data.map { prefs ->
        val raw = prefs[KEY_SETTINGS] ?: return@map AppSettings()
        runCatching { json.decodeFromString<AppSettings>(raw) }.getOrElse { AppSettings() }
    }

    suspend fun updateSettings(block: (AppSettings) -> AppSettings) {
        context.dataStore.edit { prefs ->
            val current = runCatching {
                json.decodeFromString<AppSettings>(prefs[KEY_SETTINGS] ?: "")
            }.getOrElse { AppSettings() }
            prefs[KEY_SETTINGS] = json.encodeToString(block(current))
        }
    }
}
