package com.example.p2wlan_flutter_client

import org.json.JSONObject
import java.io.File

internal object RoomProfilePaths {
    private val roomId = Regex("room-[a-f0-9]{32}")
    private val profileId = Regex("[a-f0-9]{64}")

    fun isRoom(request: JSONObject): Boolean = request.optString("network_id").startsWith("room-")

    fun configPath(filesDir: File, request: JSONObject): File {
        val root = File(filesDir, "p2wlan")
        if (!isRoom(request)) return File(root, "p2wlan-config.json")
        require(roomId.matches(request.optString("network_id"))) { "Invalid room identity" }
        val profile = request.optString("profile_id")
        require(profileId.matches(profile)) { "Room profile identity is required" }
        require(!request.optBoolean("manual_mode", false)) { "Rooms require managed networking" }
        return File(File(File(root, "rooms"), profile), "p2wlan-config.json")
    }

    fun validateAddress(request: JSONObject) {
        if (!isRoom(request)) return
        val cidr = request.optString("overlay_cidr").split("/")
        require(cidr.size == 2 && cidr[1] == "24") { "Room subnet must be /24" }
        val network = ipv4(cidr[0])
        val address = ipv4(request.optString("virtual_ip"))
        require(network[0] == 10 && network[1] == 21 && network[3] == 0) { "Invalid room subnet" }
        require(address.take(3) == network.take(3) && address[3] in 1..254) { "Room address must be registered before VPN creation" }
    }

    private fun ipv4(value: String): List<Int> {
        val parts = value.split(".")
        require(parts.size == 4) { "Invalid room IPv4 address" }
        val bytes = parts.map { it.toIntOrNull() ?: -1 }
        require(bytes.all { it in 0..255 } && bytes.joinToString(".") == value) { "Invalid room IPv4 address" }
        return bytes
    }
}
