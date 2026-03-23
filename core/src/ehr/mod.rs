// EHR integration module: model-powered SOAP note entry into EHR systems.
//
// Architecture: Model-first, cache as optimization.
// 1. Snapshot the a11y tree of the focused window
// 2. Check selector cache (fingerprint match → skip model, fast path)
// 3. Otherwise, model identifies S/O/A/P fields from the a11y tree
// 4. Fill the identified fields
// 5. Cache the result for next time

pub mod field_matcher;
pub mod model_prompt;
pub mod navigation;
pub mod recipe;
pub mod recipe_store;
pub mod tree_fingerprint;
pub mod tree_snapshot;

pub use field_matcher::*;
pub use model_prompt::*;
pub use navigation::*;
pub use recipe::*;
pub use recipe_store::*;
pub use tree_fingerprint::*;
pub use tree_snapshot::*;

// Key assumption: the therapist is already logged into their EHR.
// Pablo does NOT handle EHR authentication. The agent starts from
// whatever page is currently visible in the EHR (typically a dashboard
// or patient list) and navigates from there.
