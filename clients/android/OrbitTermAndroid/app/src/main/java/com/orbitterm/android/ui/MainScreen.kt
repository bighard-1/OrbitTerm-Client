package com.orbitterm.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CloudSync
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.orbitterm.android.data.ServerAsset

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen() {
    val assets = remember {
        mutableStateListOf(
            ServerAsset(
                id = "demo",
                credentialID = "demo",
                name = "Orbit Demo",
                group = "Lab",
                host = "192.0.2.10",
                port = 22,
                username = "root",
                authMethod = "key",
                transport = "ssh",
                networkDeviceProfile = "auto",
                allowPasswordFallback = false,
                createdAtUnix = 0
            )
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("OrbitTerm") },
                actions = {
                    IconButton(onClick = { }) { Icon(Icons.Rounded.CloudSync, contentDescription = "同步") }
                    IconButton(onClick = { }) { Icon(Icons.Rounded.Add, contentDescription = "添加资产") }
                }
            )
        },
        bottomBar = {
            NavigationBar {
                NavigationBarItem(selected = true, onClick = {}, icon = { Icon(Icons.Rounded.Dns, null) }, label = { Text("资产") })
                NavigationBarItem(selected = false, onClick = {}, icon = { Icon(Icons.Rounded.Terminal, null) }, label = { Text("会话") })
            }
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .padding(padding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("服务器", style = MaterialTheme.typography.headlineLarge)
            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(assets) { asset -> AssetCard(asset) }
            }
        }
    }
}

@Composable
private fun AssetCard(asset: ServerAsset) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        shape = RoundedCornerShape(22.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(asset.name, style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(4.dp))
                Text("${asset.username}@${asset.host}:${asset.port}", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Button(onClick = { }) { Text("连接") }
        }
    }
}
