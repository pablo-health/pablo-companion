// A11y tree fingerprinting for selector cache invalidation.
//
// Computes a hash of the structural aspects of the accessibility tree
// (roles, labels, relative positions of text inputs) so we can detect
// when the EHR page layout has changed and the cache needs refreshing.

use crate::ehr::tree_snapshot::TreeSnapshot;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

/// A fingerprint of the accessibility tree structure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeFingerprint {
    /// Hash of the tree structure.
    pub hash: u64,
    /// Number of text input elements in the tree.
    pub input_count: usize,
    /// URL pattern (if browser), for grouping caches.
    pub url_pattern: Option<String>,
}

impl TreeFingerprint {
    /// Compute a fingerprint from a tree snapshot.
    pub fn from_snapshot(snapshot: &TreeSnapshot) -> Self {
        let mut hasher = DefaultHasher::new();

        // Hash app identifier
        snapshot.app_identifier.hash(&mut hasher);

        // Hash each text input's structural properties.
        // Deliberately excludes position — minor layout shifts shouldn't
        // invalidate the cache. Role + label + order + count is sufficient.
        for node in &snapshot.text_inputs {
            node.role.hash(&mut hasher);
            node.label.hash(&mut hasher);
        }

        // Number of inputs is part of the fingerprint
        snapshot.text_inputs.len().hash(&mut hasher);

        let url_pattern = snapshot.url.as_ref().map(|u| generalize_url(u));

        TreeFingerprint {
            hash: hasher.finish(),
            input_count: snapshot.text_inputs.len(),
            url_pattern,
        }
    }

    /// Check if two fingerprints match (same tree structure).
    pub fn matches(&self, other: &TreeFingerprint) -> bool {
        self.hash == other.hash
    }
}

/// Convert a specific URL to a glob pattern for matching.
/// e.g. "https://secure.simplepractice.com/clients/123/progress_notes/456"
///    → "*.simplepractice.com/clients/*/progress_notes/*"
fn generalize_url(url: &str) -> String {
    // Strip protocol
    let without_proto = url
        .trim_start_matches("https://")
        .trim_start_matches("http://");

    // Split into host and path
    let parts: Vec<&str> = without_proto.splitn(2, '/').collect();
    let host = parts.first().unwrap_or(&"");
    let path = parts.get(1).unwrap_or(&"");

    // Generalize host: strip subdomain, add wildcard
    let host_parts: Vec<&str> = host.split('.').collect();
    let generalized_host = if host_parts.len() > 2 {
        format!("*.{}", host_parts[host_parts.len() - 2..].join("."))
    } else {
        format!("*.{host}")
    };

    // Generalize path: replace UUID/numeric segments with *
    let generalized_path: Vec<String> = path
        .split('/')
        .map(|segment| {
            if segment.is_empty() {
                String::new()
            } else if looks_like_id(segment) {
                "*".to_string()
            } else {
                segment.to_string()
            }
        })
        .collect();

    format!("{}/{}", generalized_host, generalized_path.join("/"))
}

/// Check if a URL path segment looks like an ID (UUID, numeric, hex, etc.)
fn looks_like_id(segment: &str) -> bool {
    // Numeric
    if segment.chars().all(|c| c.is_ascii_digit()) {
        return true;
    }
    // UUID-like (contains hyphens, hex chars)
    if segment.len() >= 8 && segment.contains('-') && segment.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
        return true;
    }
    // Base64-like or hex (long alphanumeric)
    if segment.len() >= 20 && segment.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ehr::field_matcher::AccessibilityNode;

    fn make_node(role: &str, label: &str, x: f64, y: f64) -> AccessibilityNode {
        AccessibilityNode {
            id: "0".to_string(),
            role: role.to_string(),
            label: label.to_string(),
            value: String::new(),
            position: (x, y),
            size: (400.0, 100.0),
            is_editable: true,
        }
    }

    #[test]
    fn same_structure_same_fingerprint() {
        let snapshot1 = TreeSnapshot {
            app_identifier: "com.google.Chrome".to_string(),
            app_name: "Chrome".to_string(),
            window_title: "Note 1".to_string(),
            url: None,
            text_inputs: vec![
                make_node("AXTextArea", "Subjective", 100.0, 200.0),
                make_node("AXTextArea", "Objective", 100.0, 320.0),
            ],
            all_elements: vec![],
        };
        let snapshot2 = TreeSnapshot {
            app_identifier: "com.google.Chrome".to_string(),
            app_name: "Chrome".to_string(),
            window_title: "Note 2".to_string(), // different title, same structure
            url: None,
            text_inputs: vec![
                make_node("AXTextArea", "Subjective", 105.0, 198.0), // slightly different position
                make_node("AXTextArea", "Objective", 102.0, 322.0),
            ],
            all_elements: vec![],
        };

        let fp1 = TreeFingerprint::from_snapshot(&snapshot1);
        let fp2 = TreeFingerprint::from_snapshot(&snapshot2);
        assert!(fp1.matches(&fp2), "Same structure should produce same fingerprint");
    }

    #[test]
    fn different_structure_different_fingerprint() {
        let snapshot1 = TreeSnapshot {
            app_identifier: "com.google.Chrome".to_string(),
            app_name: "Chrome".to_string(),
            window_title: "Note".to_string(),
            url: None,
            text_inputs: vec![
                make_node("AXTextArea", "Subjective", 100.0, 200.0),
                make_node("AXTextArea", "Objective", 100.0, 320.0),
            ],
            all_elements: vec![],
        };
        let snapshot2 = TreeSnapshot {
            app_identifier: "com.google.Chrome".to_string(),
            app_name: "Chrome".to_string(),
            window_title: "Note".to_string(),
            url: None,
            text_inputs: vec![
                make_node("AXTextArea", "Subjective", 100.0, 200.0),
                make_node("AXTextArea", "Objective", 100.0, 320.0),
                make_node("AXTextArea", "New Field", 100.0, 440.0), // extra field
            ],
            all_elements: vec![],
        };

        let fp1 = TreeFingerprint::from_snapshot(&snapshot1);
        let fp2 = TreeFingerprint::from_snapshot(&snapshot2);
        assert!(!fp1.matches(&fp2), "Different structure should produce different fingerprint");
    }

    #[test]
    fn url_generalization() {
        assert_eq!(
            generalize_url("https://secure.simplepractice.com/clients/123/progress_notes/456"),
            "*.simplepractice.com/clients/*/progress_notes/*"
        );
        assert_eq!(
            generalize_url("https://app.therapynotes.com/patients/abc-def-123/notes/789"),
            "*.therapynotes.com/patients/*/notes/*"
        );
    }

    #[test]
    fn id_detection() {
        assert!(looks_like_id("123"));
        assert!(looks_like_id("a1b2c3d4-e5f6-7890-abcd-ef1234567890"));
        assert!(!looks_like_id("progress_notes"));
        assert!(!looks_like_id("clients"));
    }
}
