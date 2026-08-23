//! OS-neutral saved port-forward profile model and deterministic merge policy.
//! Desktop/mobile adapters own secure storage; Linux can bind this module to
//! Secret Service without changing the E2EE envelope.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const PORT_FORWARD_PROFILE_MARKER: &str = "orbit_port_forwards";
pub const PORT_FORWARD_PROFILE_VERSION: u32 = 1;
pub const MAXIMUM_PORT_FORWARD_PROFILES: usize = 256;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PortForwardProfileEnvelope {
    pub kind: String,
    pub version: u32,
    pub updated_at_unix: i64,
    pub profiles: Vec<PortForwardProfile>,
    pub tombstones: Vec<PortForwardProfileTombstone>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PortForwardProfile {
    pub id: String,
    pub asset_id: String,
    pub name: String,
    pub mode: String,
    pub bind_host: String,
    pub bind_port: u16,
    pub destination_host: String,
    pub destination_port: u16,
    pub created_at_unix: i64,
    pub updated_at_unix: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PortForwardProfileTombstone {
    pub id: String,
    pub deleted_at_unix: i64,
}

/// Merges two already-validated account envelopes. A tombstone is authoritative
/// when its timestamp is at least as new as the active record. Missing records
/// never imply deletion, which protects freshly installed clients.
pub fn merge_port_forward_profile_envelopes(
    local: &PortForwardProfileEnvelope,
    remote: &PortForwardProfileEnvelope,
) -> Option<PortForwardProfileEnvelope> {
    if !valid_header(local) || !valid_header(remote) {
        return None;
    }
    let mut profiles: BTreeMap<String, PortForwardProfile> = BTreeMap::new();
    for profile in local.profiles.iter().chain(remote.profiles.iter()) {
        if profile.updated_at_unix < profile.created_at_unix || profile.created_at_unix <= 0 {
            return None;
        }
        match profiles.get(&profile.id) {
            Some(current) if current.updated_at_unix > profile.updated_at_unix => {}
            _ => {
                profiles.insert(profile.id.clone(), profile.clone());
            }
        }
    }
    let mut tombstones: BTreeMap<String, i64> = BTreeMap::new();
    for tombstone in local.tombstones.iter().chain(remote.tombstones.iter()) {
        if tombstone.deleted_at_unix <= 0 {
            return None;
        }
        let value = tombstones.entry(tombstone.id.clone()).or_default();
        *value = (*value).max(tombstone.deleted_at_unix);
    }
    profiles.retain(|id, profile| {
        tombstones.get(id).copied().unwrap_or_default() < profile.updated_at_unix
    });
    if profiles.len() > MAXIMUM_PORT_FORWARD_PROFILES
        || tombstones.len() > MAXIMUM_PORT_FORWARD_PROFILES * 4
    {
        return None;
    }
    Some(PortForwardProfileEnvelope {
        kind: PORT_FORWARD_PROFILE_MARKER.to_owned(),
        version: PORT_FORWARD_PROFILE_VERSION,
        updated_at_unix: local.updated_at_unix.max(remote.updated_at_unix),
        profiles: profiles.into_values().collect(),
        tombstones: tombstones
            .into_iter()
            .map(|(id, deleted_at_unix)| PortForwardProfileTombstone {
                id,
                deleted_at_unix,
            })
            .collect(),
    })
}

fn valid_header(value: &PortForwardProfileEnvelope) -> bool {
    value.kind == PORT_FORWARD_PROFILE_MARKER
        && value.version == PORT_FORWARD_PROFILE_VERSION
        && value.updated_at_unix > 0
        && value.profiles.len() <= MAXIMUM_PORT_FORWARD_PROFILES
        && value.tombstones.len() <= MAXIMUM_PORT_FORWARD_PROFILES * 4
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(updated: i64) -> PortForwardProfile {
        PortForwardProfile {
            id: "11111111-1111-1111-1111-111111111111".into(),
            asset_id: "22222222-2222-2222-2222-222222222222".into(),
            name: "数据库".into(),
            mode: "local".into(),
            bind_host: "127.0.0.1".into(),
            bind_port: 13306,
            destination_host: "127.0.0.1".into(),
            destination_port: 3306,
            created_at_unix: 10,
            updated_at_unix: updated,
        }
    }
    fn envelope(
        profiles: Vec<PortForwardProfile>,
        tombstones: Vec<PortForwardProfileTombstone>,
    ) -> PortForwardProfileEnvelope {
        PortForwardProfileEnvelope {
            kind: PORT_FORWARD_PROFILE_MARKER.into(),
            version: 1,
            updated_at_unix: 30,
            profiles,
            tombstones,
        }
    }

    #[test]
    fn tombstone_wins_over_older_profile() {
        let merged = merge_port_forward_profile_envelopes(
            &envelope(vec![profile(20)], vec![]),
            &envelope(
                vec![],
                vec![PortForwardProfileTombstone {
                    id: profile(20).id,
                    deleted_at_unix: 21,
                }],
            ),
        )
        .unwrap();
        assert!(merged.profiles.is_empty());
        assert_eq!(merged.tombstones.len(), 1);
    }

    #[test]
    fn later_recreation_wins_over_tombstone() {
        let merged = merge_port_forward_profile_envelopes(
            &envelope(
                vec![],
                vec![PortForwardProfileTombstone {
                    id: profile(20).id,
                    deleted_at_unix: 21,
                }],
            ),
            &envelope(vec![profile(22)], vec![]),
        )
        .unwrap();
        assert_eq!(merged.profiles[0].updated_at_unix, 22);
    }
}
