use std::collections::{HashMap, HashSet};
use std::net::Ipv4Addr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Debug)]
pub struct RoomAuthorization {
    enabled: bool,
    snapshot: Mutex<Option<RoomSnapshot>>,
}

#[derive(Debug)]
struct RoomSnapshot {
    local_ip: String,
    peers: HashMap<String, String>,
    expires_at: Instant,
}

impl RoomAuthorization {
    pub fn new(network_id: &str) -> Self {
        Self {
            enabled: network_id.starts_with("room-"),
            snapshot: Mutex::new(None),
        }
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn invalidate(&self) {
        if let Ok(mut snapshot) = self.snapshot.lock() {
            *snapshot = None;
        }
    }

    pub fn replace(
        &self,
        local_ip: &str,
        peers: impl IntoIterator<Item = (String, String)>,
        request_started: Instant,
        lease_seconds: u64,
    ) -> bool {
        if !self.enabled {
            return true;
        }
        let Some(local) = room_address(local_ip) else {
            self.invalidate();
            return false;
        };
        if !(1..=30).contains(&lease_seconds) {
            self.invalidate();
            return false;
        }
        let expires_at = request_started + Duration::from_secs(lease_seconds);
        if expires_at <= Instant::now() {
            self.invalidate();
            return false;
        }
        let mut addresses = HashSet::from([local]);
        let mut allowed = HashMap::new();
        for (id, ip) in peers {
            let Some(address) = room_address(&ip) else {
                self.invalidate();
                return false;
            };
            if id.is_empty()
                || address.octets()[..3] != local.octets()[..3]
                || !addresses.insert(address)
                || allowed.insert(id, ip).is_some()
            {
                self.invalidate();
                return false;
            }
        }
        let Ok(mut snapshot) = self.snapshot.lock() else {
            return false;
        };
        *snapshot = Some(RoomSnapshot {
            local_ip: local_ip.to_owned(),
            peers: allowed,
            expires_at,
        });
        true
    }

    pub fn allows(&self, peer_id: &str, peer_ip: &str, local_ip: &str) -> bool {
        self.allows_at(peer_id, peer_ip, local_ip, Instant::now())
    }

    fn allows_at(&self, peer_id: &str, peer_ip: &str, local_ip: &str, now: Instant) -> bool {
        if !self.enabled {
            return true;
        }
        let Ok(snapshot) = self.snapshot.lock() else {
            return false;
        };
        snapshot.as_ref().is_some_and(|snapshot| {
            snapshot.expires_at > now
                && snapshot.local_ip == local_ip
                && snapshot.peers.get(peer_id).is_some_and(|ip| ip == peer_ip)
        })
    }
}

fn room_address(value: &str) -> Option<Ipv4Addr> {
    let address = value.parse::<Ipv4Addr>().ok()?;
    let octets = address.octets();
    (octets[0] == 10 && octets[1] == 21 && (1..=254).contains(&octets[3])).then_some(address)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roster() -> Vec<(String, String)> {
        vec![("peer-b".into(), "10.21.1.3".into())]
    }

    #[test]
    fn personal_network_is_unchanged_but_room_starts_closed() {
        assert!(RoomAuthorization::new("default").allows("b", "10.20.0.3", "10.20.0.2"));
        assert!(!RoomAuthorization::new("room-a").allows("peer-b", "10.21.1.3", "10.21.1.2"));
    }

    #[test]
    fn room_lease_expires_without_control_loop_or_peer_cleanup() {
        let auth = RoomAuthorization::new("room-a");
        let now = Instant::now();
        assert!(auth.replace("10.21.1.2", roster(), now, 30));
        assert!(auth.allows_at("peer-b", "10.21.1.3", "10.21.1.2", now));
        assert!(!auth.allows_at(
            "peer-b",
            "10.21.1.3",
            "10.21.1.2",
            now + Duration::from_secs(30)
        ));
    }

    #[test]
    fn room_roster_removal_and_readdress_reject_cached_sessions() {
        let auth = RoomAuthorization::new("room-a");
        assert!(auth.replace("10.21.1.2", roster(), Instant::now(), 30));
        assert!(!auth.allows("peer-c", "10.21.1.3", "10.21.1.2"));
        assert!(!auth.allows("peer-b", "10.21.2.3", "10.21.1.2"));
        assert!(!auth.allows("peer-b", "10.21.1.3", "10.21.2.2"));
        assert!(auth.replace("10.21.1.2", Vec::new(), Instant::now(), 30));
        assert!(!auth.allows("peer-b", "10.21.1.3", "10.21.1.2"));
        assert!(auth.replace("10.21.1.40", roster(), Instant::now(), 30));
        assert!(!auth.allows("peer-b", "10.21.1.3", "10.21.1.2"));
        assert!(auth.allows("peer-b", "10.21.1.3", "10.21.1.40"));
        auth.invalidate();
        assert!(!auth.allows("peer-b", "10.21.1.3", "10.21.1.40"));
    }

    #[test]
    fn malformed_or_delayed_room_rosters_fail_closed() {
        let auth = RoomAuthorization::new("room-a");
        for seconds in [0, 31, u64::MAX] {
            assert!(!auth.replace("10.21.1.2", roster(), Instant::now(), seconds));
        }
        for ip in ["20.21.1.2", "10.21.1.0", "10.21.1.255", "::1", "bad"] {
            assert!(!auth.replace(ip, roster(), Instant::now(), 30));
        }
        assert!(!auth.replace(
            "10.21.1.2",
            roster(),
            Instant::now() - Duration::from_secs(31),
            30
        ));
        for peers in [
            vec![("peer-b".into(), "10.21.2.3".into())],
            vec![("peer-b".into(), "10.21.1.2".into())],
            vec![
                ("peer-b".into(), "10.21.1.3".into()),
                ("peer-c".into(), "10.21.1.3".into()),
            ],
            vec![
                ("peer-b".into(), "10.21.1.3".into()),
                ("peer-b".into(), "10.21.1.4".into()),
            ],
        ] {
            assert!(!auth.replace("10.21.1.2", peers, Instant::now(), 30));
        }
    }
}
