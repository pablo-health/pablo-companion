// Field matcher: scores candidate accessibility tree elements against expected SOAP fields.
//
// Used in two contexts:
// 1. Teach flow: after user demonstrates one field, infer the other three by scanning
//    the accessibility tree for sibling text inputs with matching labels.
// 2. Tier 2 recovery: when a deterministic selector breaks, find the best candidate.
//
// This module is pure logic — no platform-specific code. Platform layers (Swift/C#)
// serialize their accessibility tree nodes into AccessibilityNode structs and pass them here.

use crate::ehr::recipe::{Selectors, SoapSection};
use serde::{Deserialize, Serialize};

/// A platform-agnostic representation of an accessibility tree node.
/// Swift/C# code converts native AXUIElement / IUIAutomationElement into this.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccessibilityNode {
    /// Opaque identifier for this node (platform can use this to target the element).
    pub id: String,
    /// Accessibility role (e.g. "AXTextArea", "textbox", "edit").
    pub role: String,
    /// Accessibility label / title / description.
    pub label: String,
    /// Accessibility value (current text content, if any).
    pub value: String,
    /// Position relative to window: (x, y).
    pub position: (f64, f64),
    /// Size: (width, height).
    pub size: (f64, f64),
    /// Whether the element is currently editable / enabled.
    pub is_editable: bool,
}

/// A scored match: a candidate node and how well it matches a target section.
#[derive(Debug, Clone)]
pub struct ScoredMatch {
    pub node: AccessibilityNode,
    pub section: SoapSection,
    pub score: f64,
}

/// Common accessibility roles that represent text input fields.
const TEXT_INPUT_ROLES: &[&str] = &[
    "textbox",
    "textarea",
    "textfield",
    "text",
    "edit",
    "axtextarea",
    "axtextfield",
    "richtextarea",
];

/// Keywords associated with each SOAP section, used for label matching.
fn section_keywords(section: SoapSection) -> &'static [&'static str] {
    match section {
        SoapSection::Subjective => &["subjective", "subj", "s:", "patient report", "chief complaint"],
        SoapSection::Objective => &["objective", "obj", "o:", "clinical observation", "mental status"],
        SoapSection::Assessment => &["assessment", "assess", "a:", "diagnosis", "clinical impression"],
        SoapSection::Plan => &["plan", "p:", "treatment plan", "recommendations", "next steps"],
    }
}

/// Check if a role string represents a text input field.
fn is_text_input_role(role: &str) -> bool {
    let lower = role.to_lowercase();
    TEXT_INPUT_ROLES.iter().any(|r| lower.contains(r))
}

/// Score how well a node's label matches a SOAP section (0.0 = no match, 1.0 = exact match).
fn label_match_score(label: &str, section: SoapSection) -> f64 {
    let lower = label.to_lowercase();
    let keywords = section_keywords(section);

    // Exact match on primary keyword
    if lower == keywords[0] {
        return 1.0;
    }

    // Label contains the primary keyword
    if lower.contains(keywords[0]) {
        return 0.9;
    }

    // Label matches any secondary keyword
    for kw in &keywords[1..] {
        if lower.contains(kw) {
            return 0.7;
        }
    }

    0.0
}

/// Given a list of accessibility nodes from the same form/container, find the
/// best candidate for each missing SOAP section.
///
/// `known_node` is the node the user already identified (e.g. Subjective).
/// `known_section` is which section that node maps to.
/// `candidates` is all text-input-like nodes in the same container.
///
/// Returns scored matches for the remaining sections, sorted by score (best first).
pub fn infer_remaining_fields(
    known_node: &AccessibilityNode,
    known_section: SoapSection,
    candidates: &[AccessibilityNode],
) -> Vec<ScoredMatch> {
    let missing: Vec<SoapSection> = SoapSection::all()
        .iter()
        .filter(|s| **s != known_section)
        .copied()
        .collect();

    let mut matches = Vec::new();

    for section in missing {
        let mut best: Option<ScoredMatch> = None;

        for node in candidates {
            // Skip the known node
            if node.id == known_node.id {
                continue;
            }

            // Must be an editable text input
            if !node.is_editable || !is_text_input_role(&node.role) {
                continue;
            }

            let mut score = label_match_score(&node.label, section);

            // Proximity bonus: nodes closer to the known node get a small boost
            let distance = ((node.position.0 - known_node.position.0).powi(2)
                + (node.position.1 - known_node.position.1).powi(2))
            .sqrt();
            // Normalize: within 500px = full proximity bonus, decays beyond
            let proximity_bonus = (1.0 - (distance / 2000.0).min(1.0)) * 0.1;
            score += proximity_bonus;

            if score > 0.0 {
                if best.as_ref().map_or(true, |b| score > b.score) {
                    best = Some(ScoredMatch {
                        node: node.clone(),
                        section,
                        score,
                    });
                }
            }
        }

        if let Some(m) = best {
            matches.push(m);
        }
    }

    // Sort by score descending
    matches.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    matches
}

/// Build Selectors from an AccessibilityNode (used when recording a teach flow).
pub fn selectors_from_node(node: &AccessibilityNode) -> Selectors {
    Selectors {
        a11y_role: if node.role.is_empty() {
            None
        } else {
            Some(node.role.clone())
        },
        a11y_label: if node.label.is_empty() {
            None
        } else {
            Some(node.label.clone())
        },
        css_selector: None,
        xpath: None,
        position: Some(node.position),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_node(id: &str, label: &str, x: f64, y: f64) -> AccessibilityNode {
        AccessibilityNode {
            id: id.to_string(),
            role: "textbox".to_string(),
            label: label.to_string(),
            value: String::new(),
            position: (x, y),
            size: (400.0, 100.0),
            is_editable: true,
        }
    }

    #[test]
    fn infer_remaining_from_subjective() {
        let known = text_node("subj", "Subjective", 100.0, 100.0);
        let candidates = vec![
            known.clone(),
            text_node("obj", "Objective", 100.0, 220.0),
            text_node("assess", "Assessment", 100.0, 340.0),
            text_node("plan", "Plan", 100.0, 460.0),
            text_node("unrelated", "Notes", 100.0, 580.0), // should not match
        ];

        let matches = infer_remaining_fields(&known, SoapSection::Subjective, &candidates);

        assert_eq!(matches.len(), 3);
        let sections: Vec<SoapSection> = matches.iter().map(|m| m.section).collect();
        assert!(sections.contains(&SoapSection::Objective));
        assert!(sections.contains(&SoapSection::Assessment));
        assert!(sections.contains(&SoapSection::Plan));

        // All should have high scores (exact label match)
        for m in &matches {
            assert!(m.score > 0.9, "Expected high score for {}: got {}", m.section.display_name(), m.score);
        }
    }

    #[test]
    fn infer_with_partial_labels() {
        let known = text_node("subj", "Subjective Notes", 100.0, 100.0);
        let candidates = vec![
            known.clone(),
            text_node("obj", "Objective Findings", 100.0, 220.0),
            text_node("assess", "Clinical Assessment", 100.0, 340.0),
            text_node("plan", "Treatment Plan", 100.0, 460.0),
        ];

        let matches = infer_remaining_fields(&known, SoapSection::Subjective, &candidates);
        assert_eq!(matches.len(), 3);
        for m in &matches {
            assert!(m.score > 0.7, "Expected decent score for partial match: {}", m.score);
        }
    }

    #[test]
    fn skips_non_editable_nodes() {
        let known = text_node("subj", "Subjective", 100.0, 100.0);
        let mut obj_node = text_node("obj", "Objective", 100.0, 220.0);
        obj_node.is_editable = false;

        let candidates = vec![known.clone(), obj_node];
        let matches = infer_remaining_fields(&known, SoapSection::Subjective, &candidates);

        // Objective is not editable, so it shouldn't be suggested
        assert!(
            !matches.iter().any(|m| m.section == SoapSection::Objective),
            "Non-editable node should be excluded"
        );
    }

    #[test]
    fn selectors_from_node_captures_fields() {
        let node = text_node("subj", "Subjective", 200.0, 300.0);
        let selectors = selectors_from_node(&node);
        assert_eq!(selectors.a11y_role.as_deref(), Some("textbox"));
        assert_eq!(selectors.a11y_label.as_deref(), Some("Subjective"));
        assert_eq!(selectors.position, Some((200.0, 300.0)));
        assert!(selectors.css_selector.is_none());
    }

    #[test]
    fn label_scoring() {
        assert_eq!(label_match_score("Subjective", SoapSection::Subjective), 1.0);
        assert!(label_match_score("Subjective Notes", SoapSection::Subjective) > 0.8);
        assert!(label_match_score("Chief Complaint", SoapSection::Subjective) > 0.5);
        assert_eq!(label_match_score("Something Else", SoapSection::Subjective), 0.0);
    }
}
