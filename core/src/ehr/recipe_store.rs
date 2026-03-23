// Local recipe storage: CRUD, import/export, and recipe resolution.
//
// Recipes are stored as individual JSON files in a directory, organized by EHR ID.
// Three sources with priority: custom (user-taught) > server (OTA) > built-in.

use crate::ehr::recipe::{Recipe, RecipeSource};
use crate::PabloError;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Manages local recipe storage and resolution.
pub struct RecipeStore {
    /// Root directory for recipe storage.
    base_dir: PathBuf,
}

impl RecipeStore {
    /// Create a new store rooted at the given directory.
    /// Creates subdirectories (custom/, server/, builtin/) if they don't exist.
    pub fn new(base_dir: impl Into<PathBuf>) -> Result<Self, PabloError> {
        let base_dir = base_dir.into();
        for sub in &["custom", "server", "builtin"] {
            let dir = base_dir.join(sub);
            std::fs::create_dir_all(&dir).map_err(|e| PabloError::NotFound {
                resource: format!("Could not create recipe directory {}: {e}", dir.display()),
            })?;
        }
        Ok(Self { base_dir })
    }

    /// Resolve the best recipe for a given EHR ID.
    /// Priority: custom > server > built-in.
    pub fn resolve(&self, ehr_id: &str) -> Result<Option<Recipe>, PabloError> {
        for source_dir in &["custom", "server", "builtin"] {
            let path = self.recipe_path(source_dir, ehr_id);
            if path.exists() {
                let recipe = self.read_recipe(&path)?;
                return Ok(Some(recipe));
            }
        }
        Ok(None)
    }

    /// List all known EHR IDs (de-duplicated, best source wins).
    pub fn list_ehr_ids(&self) -> Result<Vec<String>, PabloError> {
        let mut seen = HashMap::new();
        // Iterate in priority order so custom wins
        for source_dir in &["custom", "server", "builtin"] {
            let dir = self.base_dir.join(source_dir);
            if let Ok(entries) = std::fs::read_dir(&dir) {
                for entry in entries.flatten() {
                    if let Some(name) = entry.path().file_stem() {
                        let ehr_id = name.to_string_lossy().to_string();
                        seen.entry(ehr_id).or_insert(*source_dir);
                    }
                }
            }
        }
        let mut ids: Vec<String> = seen.into_keys().collect();
        ids.sort();
        Ok(ids)
    }

    /// List all recipes with their resolved source.
    pub fn list_all(&self) -> Result<Vec<Recipe>, PabloError> {
        let ids = self.list_ehr_ids()?;
        let mut recipes = Vec::new();
        for id in ids {
            if let Some(recipe) = self.resolve(&id)? {
                recipes.push(recipe);
            }
        }
        Ok(recipes)
    }

    /// Save a user-taught recipe.
    pub fn save_custom(&self, recipe: &Recipe) -> Result<(), PabloError> {
        self.write_recipe("custom", recipe)
    }

    /// Save a server-provided recipe (OTA update).
    pub fn save_server(&self, recipe: &Recipe) -> Result<(), PabloError> {
        self.write_recipe("server", recipe)
    }

    /// Save a built-in recipe (shipped with the app).
    pub fn save_builtin(&self, recipe: &Recipe) -> Result<(), PabloError> {
        self.write_recipe("builtin", recipe)
    }

    /// Delete a custom recipe, falling back to server/built-in.
    pub fn delete_custom(&self, ehr_id: &str) -> Result<bool, PabloError> {
        let path = self.recipe_path("custom", ehr_id);
        if path.exists() {
            std::fs::remove_file(&path).map_err(|e| PabloError::NotFound {
                resource: format!("Could not delete recipe: {e}"),
            })?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    /// Export a recipe as a JSON string (for sharing / upload to backend).
    /// Strips any user-specific data — selectors only.
    pub fn export_recipe(&self, ehr_id: &str) -> Result<Option<String>, PabloError> {
        if let Some(recipe) = self.resolve(ehr_id)? {
            let json = serde_json::to_string_pretty(&recipe).map_err(|e| {
                PabloError::JsonParse {
                    message: format!("Failed to serialize recipe: {e}"),
                }
            })?;
            Ok(Some(json))
        } else {
            Ok(None)
        }
    }

    /// Import a recipe from a JSON string.
    pub fn import_recipe(&self, json: &str) -> Result<Recipe, PabloError> {
        let recipe: Recipe = serde_json::from_str(json).map_err(|e| PabloError::JsonParse {
            message: format!("Failed to parse recipe JSON: {e}"),
        })?;
        // Save to the appropriate source directory
        match recipe.source {
            RecipeSource::UserTeach => self.save_custom(&recipe)?,
            RecipeSource::Server => self.save_server(&recipe)?,
            RecipeSource::BuiltIn => self.save_builtin(&recipe)?,
        }
        Ok(recipe)
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    fn recipe_path(&self, source_dir: &str, ehr_id: &str) -> PathBuf {
        self.base_dir.join(source_dir).join(format!("{ehr_id}.json"))
    }

    fn read_recipe(&self, path: &Path) -> Result<Recipe, PabloError> {
        let contents = std::fs::read_to_string(path).map_err(|e| PabloError::NotFound {
            resource: format!("Could not read recipe at {}: {e}", path.display()),
        })?;
        serde_json::from_str(&contents).map_err(|e| PabloError::JsonParse {
            message: format!("Invalid recipe JSON at {}: {e}", path.display()),
        })
    }

    fn write_recipe(&self, source_dir: &str, recipe: &Recipe) -> Result<(), PabloError> {
        let path = self.recipe_path(source_dir, &recipe.ehr_id);
        let json =
            serde_json::to_string_pretty(recipe).map_err(|e| PabloError::JsonParse {
                message: format!("Failed to serialize recipe: {e}"),
            })?;
        std::fs::write(&path, json).map_err(|e| PabloError::NotFound {
            resource: format!("Could not write recipe to {}: {e}", path.display()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ehr::recipe::*;

    fn make_recipe(ehr_id: &str, source: RecipeSource) -> Recipe {
        Recipe {
            schema_version: Recipe::CURRENT_SCHEMA_VERSION,
            ehr_id: ehr_id.to_string(),
            ehr_display_name: ehr_id.to_string(),
            url_pattern: Some(format!("*.{ehr_id}.com/*")),
            app_identifier: None,
            window_title_pattern: None,
            source,
            fields: vec![FieldMapping {
                soap_section: SoapSection::Subjective,
                selectors: Selectors {
                    a11y_label: Some("Subjective".to_string()),
                    ..Default::default()
                },
                action: FieldAction::SetValue,
                navigation_steps: vec![],
            }],
            last_verified: None,
            created_at: "2026-03-23T10:00:00Z".to_string(),
            updated_at: "2026-03-23T10:00:00Z".to_string(),
        }
    }

    #[test]
    fn store_save_and_resolve() {
        let dir = tempfile::tempdir().unwrap();
        let store = RecipeStore::new(dir.path()).unwrap();

        let recipe = make_recipe("simplepractice", RecipeSource::UserTeach);
        store.save_custom(&recipe).unwrap();

        let resolved = store.resolve("simplepractice").unwrap().unwrap();
        assert_eq!(resolved.ehr_id, "simplepractice");
        assert_eq!(resolved.source, RecipeSource::UserTeach);
    }

    #[test]
    fn custom_overrides_server() {
        let dir = tempfile::tempdir().unwrap();
        let store = RecipeStore::new(dir.path()).unwrap();

        let server = make_recipe("therapynotes", RecipeSource::Server);
        store.save_server(&server).unwrap();

        let custom = make_recipe("therapynotes", RecipeSource::UserTeach);
        store.save_custom(&custom).unwrap();

        let resolved = store.resolve("therapynotes").unwrap().unwrap();
        assert_eq!(resolved.source, RecipeSource::UserTeach);
    }

    #[test]
    fn falls_back_to_server_after_custom_delete() {
        let dir = tempfile::tempdir().unwrap();
        let store = RecipeStore::new(dir.path()).unwrap();

        let server = make_recipe("jane", RecipeSource::Server);
        store.save_server(&server).unwrap();

        let custom = make_recipe("jane", RecipeSource::UserTeach);
        store.save_custom(&custom).unwrap();

        assert_eq!(
            store.resolve("jane").unwrap().unwrap().source,
            RecipeSource::UserTeach
        );

        store.delete_custom("jane").unwrap();

        assert_eq!(
            store.resolve("jane").unwrap().unwrap().source,
            RecipeSource::Server
        );
    }

    #[test]
    fn list_ehr_ids_deduplicates() {
        let dir = tempfile::tempdir().unwrap();
        let store = RecipeStore::new(dir.path()).unwrap();

        store
            .save_server(&make_recipe("simplepractice", RecipeSource::Server))
            .unwrap();
        store
            .save_custom(&make_recipe("simplepractice", RecipeSource::UserTeach))
            .unwrap();
        store
            .save_server(&make_recipe("therapynotes", RecipeSource::Server))
            .unwrap();

        let ids = store.list_ehr_ids().unwrap();
        assert_eq!(ids.len(), 2);
        assert!(ids.contains(&"simplepractice".to_string()));
        assert!(ids.contains(&"therapynotes".to_string()));
    }

    #[test]
    fn export_import_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let store = RecipeStore::new(dir.path()).unwrap();

        let recipe = make_recipe("epic", RecipeSource::UserTeach);
        store.save_custom(&recipe).unwrap();

        let json = store.export_recipe("epic").unwrap().unwrap();
        assert!(json.contains("epic"));

        // Import into a fresh store
        let dir2 = tempfile::tempdir().unwrap();
        let store2 = RecipeStore::new(dir2.path()).unwrap();
        let imported = store2.import_recipe(&json).unwrap();
        assert_eq!(imported.ehr_id, "epic");

        // Verify it was persisted
        let resolved = store2.resolve("epic").unwrap().unwrap();
        assert_eq!(resolved.ehr_id, "epic");
    }

    #[test]
    fn resolve_nonexistent_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        let store = RecipeStore::new(dir.path()).unwrap();
        assert!(store.resolve("nonexistent").unwrap().is_none());
    }
}
