use orbit_linux_platform::{CredentialMaterial, CredentialVault};
use uuid::Uuid;

fn main() {
    glib::MainContext::default().block_on(async {
        let vault = CredentialVault;
        let id = Uuid::new_v4();
        let expected = "orbitterm-keyring-smoke";
        vault
            .store(
                id,
                "OrbitTerm keyring smoke",
                &CredentialMaterial::password(expected),
            )
            .await
            .expect("store temporary keyring item");
        let loaded = vault
            .lookup(id)
            .await
            .expect("lookup temporary keyring item")
            .expect("temporary keyring item exists");
        assert_eq!(loaded.password, expected);
        vault.clear(id).await.expect("clear temporary keyring item");
        assert!(vault
            .lookup(id)
            .await
            .expect("verify keyring cleanup")
            .is_none());
    });
}
