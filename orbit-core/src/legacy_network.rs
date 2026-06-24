use std::fmt;

use thiserror::Error;

pub(crate) const LEGACY_NETWORK_DISABLED_CODE: &str = "legacy_network_disabled";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LegacyNetworkPolicy {
    AllowedInternal,
    DisabledInPublicRelease,
}

impl LegacyNetworkPolicy {
    pub(crate) const fn current() -> Self {
        if cfg!(feature = "legacy-network-internal") {
            Self::AllowedInternal
        } else {
            Self::DisabledInPublicRelease
        }
    }

    pub(crate) const fn allows_legacy_network(self) -> bool {
        matches!(self, Self::AllowedInternal)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Error)]
#[error("legacy_network_disabled")]
pub(crate) struct LegacyNetworkDisabled;

impl LegacyNetworkDisabled {
    pub(crate) const fn error_code(self) -> &'static str {
        LEGACY_NETWORK_DISABLED_CODE
    }
}

impl fmt::Debug for LegacyNetworkDisabled {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("LegacyNetworkDisabled")
    }
}

pub(crate) struct LegacyNetworkGate;

impl LegacyNetworkGate {
    pub(crate) const fn require_current() -> Result<(), LegacyNetworkDisabled> {
        Self::require(LegacyNetworkPolicy::current())
    }

    pub(crate) const fn require(policy: LegacyNetworkPolicy) -> Result<(), LegacyNetworkDisabled> {
        if policy.allows_legacy_network() {
            Ok(())
        } else {
            Err(LegacyNetworkDisabled)
        }
    }
}
