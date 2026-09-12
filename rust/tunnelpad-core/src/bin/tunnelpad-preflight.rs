#[path = "../preflight/mod.rs"]
mod preflight;
fn main() {
    std::process::exit(preflight::main());
}
