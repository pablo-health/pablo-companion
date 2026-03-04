// uniffi-bindgen binary — generates Swift (and future Windows C#) bindings.
//
// Usage (from repo root):
//   cargo build --manifest-path core/Cargo.toml
//   cargo run --manifest-path core/Cargo.toml --bin uniffi-bindgen generate \
//     --library core/target/debug/libpablo_core.dylib \
//     --language swift \
//     --out-dir mac/PabloCompanion/Generated/
fn main() {
    uniffi::uniffi_bindgen_main()
}
