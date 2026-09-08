package com.example.p2wlan_flutter_client

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class RoomProfilePathsTest {
    private val root = File("/app/files")
    private val a = "a".repeat(64)
    private val b = "b".repeat(64)

    @Test
    fun personalAccountsDoNotShareIdentity() {
        val first = RoomProfilePaths.configPath(root, "default", a, false, true)
        val second = RoomProfilePaths.configPath(root, "default", b, false, true)
        assertNotEquals(first, second)
        assertEquals(File(root, "p2wlan/accounts/$a/p2wlan-config.json"), first)
        assertEquals(first, RoomProfilePaths.configPath(root, "default", a, false, true))
    }

    @Test
    fun roomAndPersonalProfilesUseDifferentDirectories() {
        val room = "room-" + "1".repeat(32)
        assertEquals(File(root, "p2wlan/rooms/$a/p2wlan-config.json"),
            RoomProfilePaths.configPath(root, room, a, false, true))
        assertEquals(File(root, "p2wlan/p2wlan-config.json"),
            RoomProfilePaths.configPath(root, "default", "", true, false))
    }

    @Test
    fun invalidOrMissingManagedProfilesFailClosed() {
        for (profile in listOf("", "../accounts", "a".repeat(63), "A".repeat(64))) {
            assertThrows(IllegalArgumentException::class.java) {
                RoomProfilePaths.configPath(root, "default", profile, false, true)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            RoomProfilePaths.configPath(root, "room-" + "1".repeat(32), a, false, false)
        }
    }
}
