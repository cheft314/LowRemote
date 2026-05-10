package com.lowremote.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lowremote.model.RemoteDevice
import com.lowremote.network.MdnsDiscovery

@Composable
fun DeviceListScreen(
    discovery: MdnsDiscovery,
    onConnect: (RemoteDevice, Int) -> Unit,
) {
    val devices by discovery.devices.collectAsState()
    var selectedFps by remember { mutableStateOf(60) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .padding(24.dp),
    ) {
        Text(
            text = "LowRemote",
            color = Color.White,
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(
            text = "自动发现局域网 Mac 设备",
            color = Color(0xFFB0B0B0),
            fontSize = 14.sp,
        )

        Spacer(Modifier.height(16.dp))

        // FPS picker
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("帧率：", color = Color.White)
            listOf(30, 60, 120).forEach { fps ->
                Button(
                    onClick = { selectedFps = fps },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (fps == selectedFps) Color(0xFF4A90E2) else Color(0xFF2D2D2D),
                        contentColor = Color.White,
                    )
                ) {
                    Text("${fps}fps")
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        if (devices.isEmpty()) {
            Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("正在搜索设备…", color = Color(0xFFB0B0B0))
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "请确认 Mac 端已启动 LowRemote，且手机和 Mac 在同一 Wi-Fi",
                        color = Color(0xFF808080),
                        fontSize = 12.sp,
                    )
                }
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(devices, key = { it.key }) { device ->
                    DeviceRow(device = device, onClick = { onConnect(device, selectedFps) })
                }
            }
        }
    }
}

@Composable
private fun DeviceRow(device: RemoteDevice, onClick: () -> Unit) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(8.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFF1E1E1E)),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(device.name, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Text(
                "${device.host} · TCP ${device.tcpPort} · UDP ${device.udpPort}",
                color = Color(0xFFB0B0B0),
                fontSize = 12.sp,
            )
        }
    }
}
