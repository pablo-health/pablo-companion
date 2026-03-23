// EHR navigation agent: multi-step agent loop that navigates to the correct
// patient + appointment in an EHR system before filling SOAP fields.
//
// The agent observes the a11y tree, decides what action to take (click, type,
// scroll), executes it, then observes again. This is the "agentic" part —
// it handles arbitrary EHR workflows, not just known form layouts.
//
// Pablo already knows the patient name and appointment date/time from the session
// data, so the agent has concrete targets to search for.

use crate::ehr::tree_snapshot::TreeSnapshot;
use crate::PabloError;
use serde::{Deserialize, Serialize};

/// Context the agent needs to navigate to the right place.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NavigationContext {
    /// Patient first name.
    pub patient_first_name: String,
    /// Patient last name.
    pub patient_last_name: String,
    /// Appointment date (e.g. "2026-03-23").
    pub appointment_date: String,
    /// Appointment time (e.g. "2:00 PM").
    pub appointment_time: String,
    /// EHR identifier (e.g. "simplepractice") — used for cached navigation plans.
    pub ehr_id: String,
    /// EHR display name (e.g. "SimplePractice") — for UI messages.
    pub ehr_display_name: String,
}

/// A single action the agent wants to take.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "action")]
pub enum AgentAction {
    /// Click an element by index in the current tree snapshot.
    #[serde(rename = "click")]
    Click { element_index: usize },
    /// Type text into the currently focused element.
    #[serde(rename = "type")]
    Type { text: String },
    /// Type text into a specific element.
    #[serde(rename = "type_into")]
    TypeInto { element_index: usize, text: String },
    /// Scroll down in the current view.
    #[serde(rename = "scroll_down")]
    ScrollDown,
    /// Wait for the page to update (after a click/navigation).
    #[serde(rename = "wait")]
    Wait { milliseconds: u32 },
    /// Agent believes it has reached the target page (ready to fill SOAP fields).
    #[serde(rename = "done")]
    Done,
    /// Agent is stuck and needs human help.
    #[serde(rename = "ask_human")]
    AskHuman { question: String },
}

/// The agent's response to an observation: what to do next and why.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentStep {
    /// What the agent wants to do.
    pub action: AgentAction,
    /// Brief explanation of why (for debugging / user transparency).
    pub reasoning: String,
    /// Agent's confidence that this is the right next step (0.0 - 1.0).
    pub confidence: f64,
}

/// Maximum steps before the agent gives up and asks for help.
pub const MAX_NAVIGATION_STEPS: usize = 20;

/// Build the navigation prompt for the model.
///
/// The model receives:
/// 1. The goal (find patient X, appointment on date Y)
/// 2. The current a11y tree snapshot
/// 3. History of previous actions (so it doesn't loop)
/// 4. Available actions
pub fn build_navigation_prompt(
    context: &NavigationContext,
    snapshot: &TreeSnapshot,
    history: &[AgentStep],
) -> String {
    let element_list = snapshot.to_prompt_with_context();
    let step_num = history.len() + 1;

    let history_text = if history.is_empty() {
        "No actions taken yet. This is the first step.".to_string()
    } else {
        let mut lines = Vec::new();
        for (i, step) in history.iter().enumerate() {
            lines.push(format!(
                "Step {}: {} — {}",
                i + 1,
                format_action(&step.action),
                step.reasoning
            ));
        }
        lines.join("\n")
    };

    format!(
        r#"You are a navigation agent helping a therapist enter SOAP notes into their EHR system.

## Goal
Navigate to the progress note entry page for this appointment:
- Patient: {first} {last}
- Date: {date}
- Time: {time}
- EHR: {ehr}

## Current State (Step {step_num} of max {max})

Window: "{window_title}" in {app_name}
{url_line}

### UI Elements:
{element_list}

### Action History:
{history_text}

## Available Actions
- click: Click an element by index (e.g. click a patient name, a date, a "New Note" button)
- type: Type text into the currently focused element (e.g. type patient name in a search box)
- type_into: Click an element and type text into it
- scroll_down: Scroll down to see more elements
- wait: Wait for the page to update (use after clicking a link/button)
- done: You have reached the note entry page (you can see SOAP text fields)
- ask_human: You are stuck and need the therapist's help

## Instructions
1. Look for the patient by name. If there's a search box, search for "{last}".
2. Once on the patient page, find the appointment for {date} at {time}.
3. Click to open/create the progress note for that appointment.
4. When you see SOAP text fields (Subjective, Objective, Assessment, Plan), respond with "done".
5. If you can't find what you need after several attempts, use "ask_human".

Respond with ONLY a JSON object:
{{"action": "click|type|type_into|scroll_down|wait|done|ask_human", "element_index": N, "text": "...", "milliseconds": N, "question": "...", "reasoning": "brief explanation", "confidence": 0.0-1.0}}"#,
        first = context.patient_first_name,
        last = context.patient_last_name,
        date = context.appointment_date,
        time = context.appointment_time,
        ehr = context.ehr_display_name,
        step_num = step_num,
        max = MAX_NAVIGATION_STEPS,
        window_title = snapshot.window_title,
        app_name = snapshot.app_name,
        url_line = snapshot
            .url
            .as_ref()
            .map(|u| format!("URL: {u}"))
            .unwrap_or_default(),
        element_list = element_list,
        history_text = history_text,
    )
}

/// Parse the model's navigation response.
pub fn parse_navigation_response(json_str: &str) -> Result<AgentStep, PabloError> {
    let cleaned = json_str
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();

    let raw: serde_json::Value =
        serde_json::from_str(cleaned).map_err(|e| PabloError::JsonParse {
            message: format!("Navigation response is not valid JSON: {e}\nRaw: {cleaned}"),
        })?;

    let obj = raw.as_object().ok_or(PabloError::JsonParse {
        message: "Navigation response is not a JSON object".to_string(),
    })?;

    let action_str = obj
        .get("action")
        .and_then(|v| v.as_str())
        .unwrap_or("ask_human");

    let reasoning = obj
        .get("reasoning")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let confidence = obj
        .get("confidence")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.5)
        .clamp(0.0, 1.0);

    let action = match action_str {
        "click" => {
            let idx = obj
                .get("element_index")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            AgentAction::Click {
                element_index: idx,
            }
        }
        "type" => {
            let text = obj
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            AgentAction::Type { text }
        }
        "type_into" => {
            let idx = obj
                .get("element_index")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as usize;
            let text = obj
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            AgentAction::TypeInto {
                element_index: idx,
                text,
            }
        }
        "scroll_down" => AgentAction::ScrollDown,
        "wait" => {
            let ms = obj
                .get("milliseconds")
                .and_then(|v| v.as_u64())
                .unwrap_or(1000) as u32;
            AgentAction::Wait {
                milliseconds: ms.min(5000),
            }
        }
        "done" => AgentAction::Done,
        _ => AgentAction::AskHuman {
            question: obj
                .get("question")
                .and_then(|v| v.as_str())
                .unwrap_or("I'm not sure what to do next. Can you help?")
                .to_string(),
        },
    };

    Ok(AgentStep {
        action,
        reasoning,
        confidence,
    })
}

fn format_action(action: &AgentAction) -> String {
    match action {
        AgentAction::Click { element_index } => format!("click element [{element_index}]"),
        AgentAction::Type { text } => format!("type \"{text}\""),
        AgentAction::TypeInto {
            element_index,
            text,
        } => format!("type \"{text}\" into element [{element_index}]"),
        AgentAction::ScrollDown => "scroll down".to_string(),
        AgentAction::Wait { milliseconds } => format!("wait {milliseconds}ms"),
        AgentAction::Done => "DONE — ready to fill SOAP fields".to_string(),
        AgentAction::AskHuman { question } => format!("ask human: \"{question}\""),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ehr::field_matcher::AccessibilityNode;

    fn sample_context() -> NavigationContext {
        NavigationContext {
            patient_first_name: "Jane".to_string(),
            patient_last_name: "Smith".to_string(),
            appointment_date: "2026-03-23".to_string(),
            appointment_time: "2:00 PM".to_string(),
            ehr_id: "simplepractice".to_string(),
            ehr_display_name: "SimplePractice".to_string(),
        }
    }

    fn sample_snapshot() -> TreeSnapshot {
        TreeSnapshot {
            app_identifier: "com.google.Chrome".to_string(),
            app_name: "Google Chrome".to_string(),
            window_title: "SimplePractice — Dashboard".to_string(),
            url: Some("https://secure.simplepractice.com/dashboard".to_string()),
            text_inputs: vec![AccessibilityNode {
                id: "0".to_string(),
                role: "AXTextField".to_string(),
                label: "Search clients".to_string(),
                value: String::new(),
                position: (200.0, 80.0),
                size: (300.0, 30.0),
                is_editable: true,
            }],
            all_elements: vec![
                AccessibilityNode {
                    id: "nav".to_string(),
                    role: "AXStaticText".to_string(),
                    label: "Clients".to_string(),
                    value: String::new(),
                    position: (50.0, 200.0),
                    size: (80.0, 20.0),
                    is_editable: false,
                },
                AccessibilityNode {
                    id: "nav2".to_string(),
                    role: "AXStaticText".to_string(),
                    label: "Calendar".to_string(),
                    value: String::new(),
                    position: (50.0, 230.0),
                    size: (80.0, 20.0),
                    is_editable: false,
                },
            ],
        }
    }

    #[test]
    fn navigation_prompt_includes_patient_info() {
        let prompt = build_navigation_prompt(&sample_context(), &sample_snapshot(), &[]);
        assert!(prompt.contains("Jane Smith"));
        assert!(prompt.contains("2026-03-23"));
        assert!(prompt.contains("2:00 PM"));
        assert!(prompt.contains("SimplePractice"));
        assert!(prompt.contains("Search clients"));
    }

    #[test]
    fn navigation_prompt_includes_history() {
        let history = vec![AgentStep {
            action: AgentAction::Click { element_index: 0 },
            reasoning: "Clicking the search box".to_string(),
            confidence: 0.9,
        }];
        let prompt = build_navigation_prompt(&sample_context(), &sample_snapshot(), &history);
        assert!(prompt.contains("Step 1: click element [0]"));
        assert!(prompt.contains("Clicking the search box"));
    }

    #[test]
    fn parse_click_response() {
        let json = r#"{"action": "click", "element_index": 3, "reasoning": "Click the patient name", "confidence": 0.95}"#;
        let step = parse_navigation_response(json).unwrap();
        assert!(matches!(step.action, AgentAction::Click { element_index: 3 }));
        assert!(step.confidence > 0.9);
    }

    #[test]
    fn parse_type_into_response() {
        let json = r#"{"action": "type_into", "element_index": 0, "text": "Smith", "reasoning": "Search for patient", "confidence": 0.9}"#;
        let step = parse_navigation_response(json).unwrap();
        if let AgentAction::TypeInto {
            element_index,
            text,
        } = &step.action
        {
            assert_eq!(*element_index, 0);
            assert_eq!(text, "Smith");
        } else {
            panic!("Expected TypeInto action");
        }
    }

    #[test]
    fn parse_done_response() {
        let json =
            r#"{"action": "done", "reasoning": "I can see SOAP fields", "confidence": 0.98}"#;
        let step = parse_navigation_response(json).unwrap();
        assert!(matches!(step.action, AgentAction::Done));
    }

    #[test]
    fn parse_ask_human_response() {
        let json = r#"{"action": "ask_human", "question": "I can't find the patient. Is the name correct?", "reasoning": "No search results", "confidence": 0.3}"#;
        let step = parse_navigation_response(json).unwrap();
        if let AgentAction::AskHuman { question } = &step.action {
            assert!(question.contains("find the patient"));
        } else {
            panic!("Expected AskHuman action");
        }
    }

    #[test]
    fn wait_caps_at_5_seconds() {
        let json = r#"{"action": "wait", "milliseconds": 99999, "reasoning": "Wait", "confidence": 0.5}"#;
        let step = parse_navigation_response(json).unwrap();
        if let AgentAction::Wait { milliseconds } = step.action {
            assert_eq!(milliseconds, 5000);
        } else {
            panic!("Expected Wait action");
        }
    }
}
