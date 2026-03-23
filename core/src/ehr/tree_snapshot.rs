// Accessibility tree snapshot: platform-agnostic representation of a window's UI elements.
//
// Swift/C# code walks the native a11y tree (AXUIElement / IUIAutomationElement) and
// serializes it into AccessibilityNode structs. This module converts those snapshots
// into the format the model prompt expects.

use crate::ehr::field_matcher::AccessibilityNode;
use serde::{Deserialize, Serialize};

/// A snapshot of the accessibility tree for a single window.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TreeSnapshot {
    /// App bundle ID (macOS) or executable name (Windows).
    pub app_identifier: String,
    /// App display name.
    pub app_name: String,
    /// Window title.
    pub window_title: String,
    /// URL if this is a browser window.
    pub url: Option<String>,
    /// All text-input-like elements found in the tree.
    pub text_inputs: Vec<AccessibilityNode>,
    /// All elements (for context — labels, headings, etc.)
    pub all_elements: Vec<AccessibilityNode>,
}

impl TreeSnapshot {
    /// Filter to only editable text input elements.
    pub fn editable_text_inputs(&self) -> Vec<&AccessibilityNode> {
        self.text_inputs.iter().filter(|n| n.is_editable).collect()
    }

    /// Serialize the text inputs into the numbered list format the model expects.
    ///
    /// Output:
    /// ```text
    /// [0] role=AXTextArea label="Subjective" path=window>group>textarea[0] size=400x100
    /// [1] role=AXTextArea label="Objective" path=window>group>textarea[1] size=400x100
    /// ```
    pub fn to_prompt_element_list(&self) -> String {
        let mut lines = Vec::new();
        for (i, node) in self.text_inputs.iter().enumerate() {
            let label_display = if node.label.is_empty() {
                "(unlabeled)".to_string()
            } else {
                format!("\"{}\"", truncate(&node.label, 80))
            };

            let value_hint = if node.value.is_empty() {
                String::new()
            } else {
                format!(" value=\"{}\"", truncate(&node.value, 40))
            };

            lines.push(format!(
                "[{i}] role={} label={}{} pos=({:.0},{:.0}) size=({:.0}x{:.0})",
                node.role,
                label_display,
                value_hint,
                node.position.0,
                node.position.1,
                node.size.0,
                node.size.1,
            ));
        }
        lines.join("\n")
    }

    /// Also include nearby non-input elements (labels, headings) for context.
    /// This helps the model when input labels are empty but nearby text says "Subjective:".
    pub fn to_prompt_with_context(&self) -> String {
        let mut lines = Vec::new();

        lines.push("## Text input elements:".to_string());
        lines.push(self.to_prompt_element_list());

        // Include labels/headings that are close to text inputs
        let context_elements: Vec<&AccessibilityNode> = self
            .all_elements
            .iter()
            .filter(|n| {
                !n.is_editable
                    && !n.label.is_empty()
                    && is_label_or_heading(&n.role)
            })
            .collect();

        if !context_elements.is_empty() {
            lines.push(String::new());
            lines.push("## Nearby labels and headings:".to_string());
            for node in context_elements.iter().take(30) {
                lines.push(format!(
                    "- \"{}\" (role={}, pos=({:.0},{:.0}))",
                    truncate(&node.label, 60),
                    node.role,
                    node.position.0,
                    node.position.1,
                ));
            }
        }

        lines.join("\n")
    }
}

fn truncate(s: &str, max_len: usize) -> String {
    if s.len() <= max_len {
        s.to_string()
    } else {
        format!("{}...", &s[..max_len])
    }
}

fn is_label_or_heading(role: &str) -> bool {
    let lower = role.to_lowercase();
    lower.contains("statictext")
        || lower.contains("label")
        || lower.contains("heading")
        || lower.contains("title")
        || lower.contains("axstatictext")
        || lower.contains("text")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ehr::field_matcher::AccessibilityNode;

    fn make_snapshot() -> TreeSnapshot {
        TreeSnapshot {
            app_identifier: "com.google.Chrome".to_string(),
            app_name: "Google Chrome".to_string(),
            window_title: "Progress Note — Jane Smith".to_string(),
            url: Some("https://secure.simplepractice.com/clients/123/progress_notes/456".to_string()),
            text_inputs: vec![
                AccessibilityNode {
                    id: "0".to_string(),
                    role: "AXTextArea".to_string(),
                    label: "Subjective".to_string(),
                    value: String::new(),
                    position: (120.0, 200.0),
                    size: (400.0, 100.0),
                    is_editable: true,
                },
                AccessibilityNode {
                    id: "1".to_string(),
                    role: "AXTextArea".to_string(),
                    label: "Objective".to_string(),
                    value: String::new(),
                    position: (120.0, 320.0),
                    size: (400.0, 100.0),
                    is_editable: true,
                },
                AccessibilityNode {
                    id: "2".to_string(),
                    role: "AXTextArea".to_string(),
                    label: "Assessment".to_string(),
                    value: String::new(),
                    position: (120.0, 440.0),
                    size: (400.0, 100.0),
                    is_editable: true,
                },
                AccessibilityNode {
                    id: "3".to_string(),
                    role: "AXTextArea".to_string(),
                    label: "Plan".to_string(),
                    value: String::new(),
                    position: (120.0, 560.0),
                    size: (400.0, 100.0),
                    is_editable: true,
                },
            ],
            all_elements: vec![
                AccessibilityNode {
                    id: "h1".to_string(),
                    role: "AXHeading".to_string(),
                    label: "Progress Note".to_string(),
                    value: String::new(),
                    position: (120.0, 100.0),
                    size: (300.0, 30.0),
                    is_editable: false,
                },
            ],
        }
    }

    #[test]
    fn prompt_element_list_format() {
        let snapshot = make_snapshot();
        let prompt = snapshot.to_prompt_element_list();
        assert!(prompt.contains("[0] role=AXTextArea label=\"Subjective\""));
        assert!(prompt.contains("[1] role=AXTextArea label=\"Objective\""));
        assert!(prompt.contains("[2] role=AXTextArea label=\"Assessment\""));
        assert!(prompt.contains("[3] role=AXTextArea label=\"Plan\""));
    }

    #[test]
    fn prompt_with_context_includes_headings() {
        let snapshot = make_snapshot();
        let prompt = snapshot.to_prompt_with_context();
        assert!(prompt.contains("## Text input elements:"));
        assert!(prompt.contains("## Nearby labels and headings:"));
        assert!(prompt.contains("\"Progress Note\""));
    }

    #[test]
    fn editable_filter() {
        let mut snapshot = make_snapshot();
        snapshot.text_inputs[1].is_editable = false;
        let editable = snapshot.editable_text_inputs();
        assert_eq!(editable.len(), 3);
    }
}
