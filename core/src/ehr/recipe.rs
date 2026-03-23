// Cross-platform recipe format for EHR SOAP note entry.
//
// A recipe describes how to fill S/O/A/P fields in a specific EHR system.
// Selectors are abstract (a11y role/label, CSS, XPath) — platform-native
// executors resolve them using AXUIElement (macOS) or UIA (Windows).

use serde::{Deserialize, Serialize};

/// Which SOAP section a field maps to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SoapSection {
    Subjective,
    Objective,
    Assessment,
    Plan,
}

impl SoapSection {
    /// All four sections in standard order.
    pub fn all() -> [SoapSection; 4] {
        [
            SoapSection::Subjective,
            SoapSection::Objective,
            SoapSection::Assessment,
            SoapSection::Plan,
        ]
    }

    /// Human-readable label for UI display.
    pub fn display_name(&self) -> &'static str {
        match self {
            SoapSection::Subjective => "Subjective",
            SoapSection::Objective => "Objective",
            SoapSection::Assessment => "Assessment",
            SoapSection::Plan => "Plan",
        }
    }
}

/// What to do with the target element.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FieldAction {
    /// Set the element's value directly (preferred — works with most text inputs).
    SetValue,
    /// Click the element, then type/paste the content (fallback for tricky controls).
    ClickAndType,
}

/// Abstract selectors for locating a UI element across platforms.
///
/// Resolution order: a11y_label + a11y_role first (most stable across UI updates),
/// then css_selector, then xpath as fallback.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Selectors {
    /// Accessibility role (e.g. "textbox", "textarea", "textfield").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub a11y_role: Option<String>,

    /// Accessibility label / description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub a11y_label: Option<String>,

    /// CSS selector (for browser-based EHRs).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub css_selector: Option<String>,

    /// XPath (fallback for browser-based EHRs).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub xpath: Option<String>,

    /// Window-relative position as (x, y) — last resort fallback.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<(f64, f64)>,
}

impl Selectors {
    /// True if at least one selector strategy is available.
    pub fn has_any(&self) -> bool {
        self.a11y_role.is_some()
            || self.a11y_label.is_some()
            || self.css_selector.is_some()
            || self.xpath.is_some()
            || self.position.is_some()
    }
}

/// A navigation step to reach the target field (e.g. clicking a tab first).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NavigationStep {
    /// What to do: "click", "wait", "scroll".
    pub action: String,
    /// Selectors for the element to interact with.
    pub selectors: Selectors,
    /// Optional delay in milliseconds after this step.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delay_ms: Option<u32>,
}

/// Mapping for a single SOAP field in the EHR.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FieldMapping {
    /// Which SOAP section this field is for.
    pub soap_section: SoapSection,
    /// Selectors to locate the target element.
    pub selectors: Selectors,
    /// How to fill the field.
    pub action: FieldAction,
    /// Steps to navigate to this field before filling (e.g. click a tab).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub navigation_steps: Vec<NavigationStep>,
}

/// Where the recipe came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecipeSource {
    /// User taught Pablo via the teach flow.
    UserTeach,
    /// Downloaded from Pablo backend (OTA).
    Server,
    /// Shipped with the app binary.
    BuiltIn,
}

/// A complete recipe for entering SOAP notes into a specific EHR.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Recipe {
    /// Schema version for forward compatibility.
    pub schema_version: u32,
    /// Machine-readable identifier (e.g. "simplepractice").
    pub ehr_id: String,
    /// Human-readable name (e.g. "SimplePractice").
    pub ehr_display_name: String,
    /// URL pattern to match (glob-style, e.g. "*.simplepractice.com/clients/*/progress_notes/*").
    /// None for native desktop EHR apps.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url_pattern: Option<String>,
    /// App bundle identifier (macOS) or executable name (Windows) for native EHR apps.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_identifier: Option<String>,
    /// Window title pattern (glob-style) for identifying the correct window.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_title_pattern: Option<String>,
    /// Where this recipe came from.
    pub source: RecipeSource,
    /// Field mappings for each SOAP section.
    pub fields: Vec<FieldMapping>,
    /// ISO 8601 timestamp when last verified working.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_verified: Option<String>,
    /// ISO 8601 timestamp when the recipe was created.
    pub created_at: String,
    /// ISO 8601 timestamp when last modified.
    pub updated_at: String,
}

impl Recipe {
    /// Current schema version.
    pub const CURRENT_SCHEMA_VERSION: u32 = 1;

    /// Get the field mapping for a specific SOAP section, if present.
    pub fn field_for_section(&self, section: SoapSection) -> Option<&FieldMapping> {
        self.fields.iter().find(|f| f.soap_section == section)
    }

    /// True if all four SOAP sections have mappings.
    pub fn is_complete(&self) -> bool {
        SoapSection::all()
            .iter()
            .all(|s| self.field_for_section(*s).is_some())
    }

    /// Sections that are missing from this recipe.
    pub fn missing_sections(&self) -> Vec<SoapSection> {
        SoapSection::all()
            .iter()
            .filter(|s| self.field_for_section(**s).is_none())
            .copied()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_recipe() -> Recipe {
        Recipe {
            schema_version: Recipe::CURRENT_SCHEMA_VERSION,
            ehr_id: "simplepractice".to_string(),
            ehr_display_name: "SimplePractice".to_string(),
            url_pattern: Some("*.simplepractice.com/clients/*/progress_notes/*".to_string()),
            app_identifier: None,
            window_title_pattern: None,
            source: RecipeSource::UserTeach,
            fields: vec![
                FieldMapping {
                    soap_section: SoapSection::Subjective,
                    selectors: Selectors {
                        a11y_role: Some("textbox".to_string()),
                        a11y_label: Some("Subjective".to_string()),
                        css_selector: Some("#note_subjective".to_string()),
                        ..Default::default()
                    },
                    action: FieldAction::SetValue,
                    navigation_steps: vec![],
                },
                FieldMapping {
                    soap_section: SoapSection::Objective,
                    selectors: Selectors {
                        a11y_role: Some("textbox".to_string()),
                        a11y_label: Some("Objective".to_string()),
                        ..Default::default()
                    },
                    action: FieldAction::SetValue,
                    navigation_steps: vec![],
                },
                FieldMapping {
                    soap_section: SoapSection::Assessment,
                    selectors: Selectors {
                        a11y_role: Some("textbox".to_string()),
                        a11y_label: Some("Assessment".to_string()),
                        ..Default::default()
                    },
                    action: FieldAction::SetValue,
                    navigation_steps: vec![],
                },
                FieldMapping {
                    soap_section: SoapSection::Plan,
                    selectors: Selectors {
                        a11y_role: Some("textbox".to_string()),
                        a11y_label: Some("Plan".to_string()),
                        ..Default::default()
                    },
                    action: FieldAction::SetValue,
                    navigation_steps: vec![],
                },
            ],
            last_verified: Some("2026-03-23T12:00:00Z".to_string()),
            created_at: "2026-03-23T10:00:00Z".to_string(),
            updated_at: "2026-03-23T12:00:00Z".to_string(),
        }
    }

    #[test]
    fn recipe_json_roundtrip() {
        let recipe = sample_recipe();
        let json = serde_json::to_string_pretty(&recipe).unwrap();
        let parsed: Recipe = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.ehr_id, "simplepractice");
        assert_eq!(parsed.schema_version, 1);
        assert_eq!(parsed.fields.len(), 4);
        assert_eq!(parsed.source, RecipeSource::UserTeach);
    }

    #[test]
    fn recipe_is_complete() {
        let recipe = sample_recipe();
        assert!(recipe.is_complete());
        assert!(recipe.missing_sections().is_empty());
    }

    #[test]
    fn recipe_missing_sections() {
        let mut recipe = sample_recipe();
        recipe.fields.retain(|f| f.soap_section != SoapSection::Plan);
        assert!(!recipe.is_complete());
        assert_eq!(recipe.missing_sections(), vec![SoapSection::Plan]);
    }

    #[test]
    fn field_for_section_lookup() {
        let recipe = sample_recipe();
        let subj = recipe.field_for_section(SoapSection::Subjective).unwrap();
        assert_eq!(
            subj.selectors.a11y_label.as_deref(),
            Some("Subjective")
        );
    }

    #[test]
    fn selectors_has_any() {
        let empty = Selectors::default();
        assert!(!empty.has_any());

        let with_label = Selectors {
            a11y_label: Some("Subjective".to_string()),
            ..Default::default()
        };
        assert!(with_label.has_any());
    }

    #[test]
    fn soap_section_display_names() {
        assert_eq!(SoapSection::Subjective.display_name(), "Subjective");
        assert_eq!(SoapSection::Objective.display_name(), "Objective");
        assert_eq!(SoapSection::Assessment.display_name(), "Assessment");
        assert_eq!(SoapSection::Plan.display_name(), "Plan");
    }
}
