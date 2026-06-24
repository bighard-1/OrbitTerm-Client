#![cfg(feature = "legacy-network-internal")]

//! Insecure host-key acceptance for explicit internal migration builds only.
//!
//! Public Debug and Release builds must not compile this module. Checked SSH
//! connections use `CheckedHostKeyHandler` and never reference this type.

use russh::client;

use crate::OrbitCoreError;

#[derive(Clone, Default)]
pub(crate) struct InsecureLegacyAcceptAllHostKeyHandler;

impl client::Handler for InsecureLegacyAcceptAllHostKeyHandler {
    type Error = OrbitCoreError;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::InsecureLegacyAcceptAllHostKeyHandler;

    #[test]
    fn internal_feature_exposes_a_distinct_legacy_handler_type() {
        fn assert_handler<T: russh::client::Handler + Default>() {}

        assert_handler::<InsecureLegacyAcceptAllHostKeyHandler>();
        assert!(
            std::any::type_name::<InsecureLegacyAcceptAllHostKeyHandler>()
                .contains("InsecureLegacyAcceptAllHostKeyHandler")
        );
    }
}
