use orbit_linux_domain::{AssetValidationError, ServerAsset};
use thiserror::Error;
use uuid::Uuid;

pub trait AssetRepository {
    fn load(&self) -> Result<Vec<ServerAsset>, RepositoryError>;
    fn save(&self, assets: &[ServerAsset]) -> Result<(), RepositoryError>;
}

#[derive(Debug, Error)]
pub enum RepositoryError {
    #[error("资产存储不可用：{0}")]
    Unavailable(String),
    #[error("资产数据无效：{0}")]
    Invalid(String),
}

pub struct AssetCatalog<R: AssetRepository> {
    repository: R,
    assets: Vec<ServerAsset>,
}

impl<R: AssetRepository> AssetCatalog<R> {
    pub fn open(repository: R) -> Result<Self, CatalogError> {
        let assets = repository.load()?;
        for asset in &assets {
            asset.validate()?;
        }
        Ok(Self { repository, assets })
    }

    pub fn assets(&self) -> &[ServerAsset] {
        &self.assets
    }

    pub fn filtered(&self, query: &str) -> Vec<&ServerAsset> {
        self.assets
            .iter()
            .filter(|asset| asset.matches(query))
            .collect()
    }

    pub fn upsert(&mut self, asset: ServerAsset) -> Result<(), CatalogError> {
        asset.validate()?;
        let previous = self.assets.clone();
        if let Some(existing) = self.assets.iter_mut().find(|item| item.id == asset.id) {
            *existing = asset;
        } else {
            self.assets.push(asset);
        }
        self.assets.sort_by_cached_key(|item| {
            (item.group.to_lowercase(), item.name.to_lowercase(), item.id)
        });
        if let Err(error) = self.repository.save(&self.assets) {
            self.assets = previous;
            return Err(error.into());
        }
        Ok(())
    }

    pub fn remove(&mut self, id: Uuid) -> Result<Option<ServerAsset>, CatalogError> {
        let Some(index) = self.assets.iter().position(|asset| asset.id == id) else {
            return Ok(None);
        };
        let removed = self.assets.remove(index);
        if let Err(error) = self.repository.save(&self.assets) {
            self.assets.insert(index, removed);
            return Err(error.into());
        }
        Ok(Some(removed))
    }

    pub fn remove_many(
        &mut self,
        ids: &std::collections::HashSet<Uuid>,
    ) -> Result<Vec<ServerAsset>, CatalogError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let previous = self.assets.clone();
        let mut removed = Vec::new();
        self.assets.retain(|asset| {
            if ids.contains(&asset.id) {
                removed.push(asset.clone());
                false
            } else {
                true
            }
        });
        if let Err(error) = self.repository.save(&self.assets) {
            self.assets = previous;
            return Err(error.into());
        }
        Ok(removed)
    }
}

#[derive(Debug, Error)]
pub enum CatalogError {
    #[error(transparent)]
    Validation(#[from] AssetValidationError),
    #[error(transparent)]
    Repository(#[from] RepositoryError),
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    #[derive(Default, Clone)]
    struct MemoryRepository(Rc<RefCell<Vec<ServerAsset>>>);

    impl AssetRepository for MemoryRepository {
        fn load(&self) -> Result<Vec<ServerAsset>, RepositoryError> {
            Ok(self.0.borrow().clone())
        }

        fn save(&self, assets: &[ServerAsset]) -> Result<(), RepositoryError> {
            *self.0.borrow_mut() = assets.to_vec();
            Ok(())
        }
    }

    #[derive(Clone)]
    struct FailingRepository(Vec<ServerAsset>);

    impl AssetRepository for FailingRepository {
        fn load(&self) -> Result<Vec<ServerAsset>, RepositoryError> {
            Ok(self.0.clone())
        }

        fn save(&self, _assets: &[ServerAsset]) -> Result<(), RepositoryError> {
            Err(RepositoryError::Unavailable("fixture".into()))
        }
    }

    #[test]
    fn upsert_validates_sorts_and_persists() {
        let repository = MemoryRepository::default();
        let persisted = repository.0.clone();
        let mut catalog = AssetCatalog::open(repository).expect("catalog opens");
        catalog
            .upsert(ServerAsset::new("Zulu", "z.example", "ops"))
            .expect("first asset");
        catalog
            .upsert(ServerAsset::new("Alpha", "a.example", "ops"))
            .expect("second asset");
        assert_eq!(catalog.assets()[0].name, "Alpha");
        assert_eq!(persisted.borrow().len(), 2);
    }

    #[test]
    fn failed_upsert_restores_in_memory_catalog() {
        let original = ServerAsset::new("原始", "old.example", "ops");
        let mut replacement = original.clone();
        replacement.name = "替换".into();
        let mut catalog = AssetCatalog::open(FailingRepository(vec![original.clone()])).unwrap();
        assert!(catalog.upsert(replacement).is_err());
        assert_eq!(catalog.assets(), std::slice::from_ref(&original));
    }

    #[test]
    fn remove_many_persists_as_one_transaction() {
        let repository = MemoryRepository::default();
        let mut catalog = AssetCatalog::open(repository).unwrap();
        let first = ServerAsset::new("一", "one.example", "ops");
        let second = ServerAsset::new("二", "two.example", "ops");
        let third = ServerAsset::new("三", "three.example", "ops");
        catalog.upsert(first.clone()).unwrap();
        catalog.upsert(second.clone()).unwrap();
        catalog.upsert(third.clone()).unwrap();
        let ids = std::collections::HashSet::from([first.id, third.id]);
        let removed = catalog.remove_many(&ids).unwrap();
        assert_eq!(removed.len(), 2);
        assert_eq!(catalog.assets(), std::slice::from_ref(&second));
    }
}
