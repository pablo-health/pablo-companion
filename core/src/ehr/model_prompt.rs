// Model prompt construction and response parsing for SOAP field identification.
//
// Builds a structured prompt from an a11y tree snapshot, sends it to the local
// model (via platform-native llama.cpp bindings), and parses the JSON response
// into field identifications with confidence scores.

use crate::ehr::recipe::SoapSection;
use crate::ehr::tree_snapshot::TreeSnapshot;
use crate::PabloError;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// The model's identification of a single SOAP field.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FieldIdentification {
    /// Index into the TreeSnapshot's text_inputs array.
    pub element_index: usize,
    /// Model's confidence in this identification (0.0 - 1.0).
    pub confidence: f64,
}

/// The model's complete response: identification of all four SOAP fields.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelResponse {
    pub subjective: Option<FieldIdentification>,
    pub objective: Option<FieldIdentification>,
    pub assessment: Option<FieldIdentification>,
    pub plan: Option<FieldIdentification>,
}

impl ModelResponse {
    /// Get identification for a specific section.
    pub fn for_section(&self, section: SoapSection) -> Option<&FieldIdentification> {
        match section {
            SoapSection::Subjective => self.subjective.as_ref(),
            SoapSection::Objective => self.objective.as_ref(),
            SoapSection::Assessment => self.assessment.as_ref(),
            SoapSection::Plan => self.plan.as_ref(),
        }
    }

    /// Minimum confidence across all identified fields.
    pub fn min_confidence(&self) -> f64 {
        [&self.subjective, &self.objective, &self.assessment, &self.plan]
            .iter()
            .filter_map(|f| f.as_ref().map(|f| f.confidence))
            .fold(f64::MAX, f64::min)
    }

    /// True if all four fields are identified.
    pub fn is_complete(&self) -> bool {
        self.subjective.is_some()
            && self.objective.is_some()
            && self.assessment.is_some()
            && self.plan.is_some()
    }

    /// True if all fields identified with high confidence (>= threshold).
    pub fn is_high_confidence(&self, threshold: f64) -> bool {
        self.is_complete() && self.min_confidence() >= threshold
    }
}

/// Confidence threshold for auto-fill without user confirmation.
pub const AUTO_FILL_CONFIDENCE: f64 = 0.9;

/// Confidence threshold below which we ask the user to manually identify.
pub const LOW_CONFIDENCE: f64 = 0.5;

/// Build the model prompt from an a11y tree snapshot.
pub fn build_prompt(snapshot: &TreeSnapshot) -> String {
    let element_list = snapshot.to_prompt_with_context();
    let num_inputs = snapshot.text_inputs.len();

    format!(
        r#"You are identifying SOAP note fields in a healthcare EHR application.

The accessibility tree of the current window contains {num_inputs} text input elements.

{element_list}

For each SOAP section (Subjective, Objective, Assessment, Plan), identify which text input element (by index) is the correct target for that section's content.

Consider:
- Element labels (most reliable signal)
- Element position (SOAP fields are typically in S→O→A→P order, top to bottom)
- Nearby labels and headings that may indicate the field's purpose
- Field size (SOAP fields are usually large text areas, not small text fields)

If you cannot confidently identify a field, omit it from the response.

Respond with ONLY a JSON object, no explanation:
{{"subjective": {{"index": N, "confidence": 0.0-1.0}}, "objective": {{"index": N, "confidence": 0.0-1.0}}, "assessment": {{"index": N, "confidence": 0.0-1.0}}, "plan": {{"index": N, "confidence": 0.0-1.0}}}}"#
    )
}

/// Parse the model's JSON response into a structured ModelResponse.
pub fn parse_response(json_str: &str) -> Result<ModelResponse, PabloError> {
    // The model may wrap its response in markdown code blocks — strip them
    let cleaned = json_str
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();

    // Parse the raw JSON into a flexible HashMap first
    let raw: HashMap<String, serde_json::Value> =
        serde_json::from_str(cleaned).map_err(|e| PabloError::JsonParse {
            message: format!("Model response is not valid JSON: {e}\nRaw: {cleaned}"),
        })?;

    let parse_field = |key: &str| -> Option<FieldIdentification> {
        let obj = raw.get(key)?.as_object()?;
        let index = obj.get("index")?.as_u64()? as usize;
        let confidence = obj.get("confidence")?.as_f64()?;
        Some(FieldIdentification {
            element_index: index,
            confidence: confidence.clamp(0.0, 1.0),
        })
    };

    Ok(ModelResponse {
        subjective: parse_field("subjective"),
        objective: parse_field("objective"),
        assessment: parse_field("assessment"),
        plan: parse_field("plan"),
    })
}

/// Validate that all identified indices are within bounds of the snapshot.
pub fn validate_response(
    response: &ModelResponse,
    snapshot: &TreeSnapshot,
) -> Result<(), PabloError> {
    let max_index = snapshot.text_inputs.len();

    for section in SoapSection::all() {
        if let Some(id) = response.for_section(section) {
            if id.element_index >= max_index {
                return Err(PabloError::JsonParse {
                    message: format!(
                        "Model identified {} at index {}, but only {} elements exist",
                        section.display_name(),
                        id.element_index,
                        max_index
                    ),
                });
            }
        }
    }

    // Check for duplicate indices (two sections pointing to same element)
    let mut seen = HashMap::new();
    for section in SoapSection::all() {
        if let Some(id) = response.for_section(section) {
            if let Some(prev_section) = seen.insert(id.element_index, section) {
                return Err(PabloError::JsonParse {
                    message: format!(
                        "Model assigned element {} to both {} and {}",
                        id.element_index,
                        prev_section.display_name(),
                        section.display_name()
                    ),
                });
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ehr::field_matcher::AccessibilityNode;

    fn make_snapshot() -> TreeSnapshot {
        TreeSnapshot {
            app_identifier: "com.google.Chrome".to_string(),
            app_name: "Chrome".to_string(),
            window_title: "Progress Note".to_string(),
            url: None,
            text_inputs: vec![
                AccessibilityNode {
                    id: "0".to_string(),
                    role: "AXTextArea".to_string(),
                    label: "Subjective".to_string(),
                    value: String::new(),
                    position: (100.0, 200.0),
                    size: (400.0, 100.0),
                    is_editable: true,
                },
                AccessibilityNode {
                    id: "1".to_string(),
                    role: "AXTextArea".to_string(),
                    label: "Objective".to_string(),
                    value: String::new(),
                    position: (100.0, 320.0),
                    size: (400.0, 100.0),
                    is_editable: true,
                },
                AccessibilityNode {
                    id: "2".to_string(),
                    role: "AXTextArea".to_string(),
                    label: "Assessment".to_string(),
                    value: String::new(),
                    position: (100.0, 440.0),
                    size: (400.0, 100.0),
                    is_editable: true,
                },
                AccessibilityNode {
                    id: "3".to_string(),
                    role: "AXTextArea".to_string(),
                    label: "Plan".to_string(),
                    value: String::new(),
                    position: (100.0, 560.0),
                    size: (400.0, 100.0),
                    is_editable: true,
                },
            ],
            all_elements: vec![],
        }
    }

    #[test]
    fn build_prompt_includes_elements() {
        let snapshot = make_snapshot();
        let prompt = build_prompt(&snapshot);
        assert!(prompt.contains("4 text input elements"));
        assert!(prompt.contains("[0] role=AXTextArea label=\"Subjective\""));
        assert!(prompt.contains("Respond with ONLY a JSON object"));
    }

    #[test]
    fn parse_clean_response() {
        let json = r#"{"subjective": {"index": 0, "confidence": 0.98}, "objective": {"index": 1, "confidence": 0.95}, "assessment": {"index": 2, "confidence": 0.92}, "plan": {"index": 3, "confidence": 0.97}}"#;
        let response = parse_response(json).unwrap();
        assert!(response.is_complete());
        assert!(response.is_high_confidence(0.9));
        assert_eq!(response.subjective.unwrap().element_index, 0);
        assert_eq!(response.plan.unwrap().element_index, 3);
    }

    #[test]
    fn parse_response_with_code_block() {
        let json = "```json\n{\"subjective\": {\"index\": 0, \"confidence\": 0.9}, \"objective\": {\"index\": 1, \"confidence\": 0.8}}\n```";
        let response = parse_response(json).unwrap();
        assert!(response.subjective.is_some());
        assert!(response.objective.is_some());
        assert!(response.assessment.is_none()); // partial response is OK
    }

    #[test]
    fn parse_invalid_json_returns_error() {
        let result = parse_response("not json");
        assert!(result.is_err());
    }

    #[test]
    fn validate_catches_out_of_bounds() {
        let snapshot = make_snapshot();
        let response = ModelResponse {
            subjective: Some(FieldIdentification {
                element_index: 99,
                confidence: 0.9,
            }),
            objective: None,
            assessment: None,
            plan: None,
        };
        assert!(validate_response(&response, &snapshot).is_err());
    }

    #[test]
    fn validate_catches_duplicate_indices() {
        let snapshot = make_snapshot();
        let response = ModelResponse {
            subjective: Some(FieldIdentification {
                element_index: 0,
                confidence: 0.9,
            }),
            objective: Some(FieldIdentification {
                element_index: 0, // same as subjective!
                confidence: 0.8,
            }),
            assessment: None,
            plan: None,
        };
        assert!(validate_response(&response, &snapshot).is_err());
    }

    #[test]
    fn model_response_min_confidence() {
        let response = ModelResponse {
            subjective: Some(FieldIdentification {
                element_index: 0,
                confidence: 0.95,
            }),
            objective: Some(FieldIdentification {
                element_index: 1,
                confidence: 0.7,
            }),
            assessment: Some(FieldIdentification {
                element_index: 2,
                confidence: 0.85,
            }),
            plan: Some(FieldIdentification {
                element_index: 3,
                confidence: 0.9,
            }),
        };
        assert!((response.min_confidence() - 0.7).abs() < f64::EPSILON);
        assert!(!response.is_high_confidence(0.9));
        assert!(response.is_high_confidence(0.7));
    }
}
