#[macro_use]
extern crate rust_i18n;

i18n!("locales", fallback = "en");

mod app;
mod config;
mod data_packs;
mod editor;
mod first_run;
mod project;
mod theme;
mod toolchain;
mod ui;

pub use app::{run, run_new_project, run_with_project};

pub fn build(path: std::path::PathBuf) {
    let config = config::AppConfig::load();
    let data_packs = data_packs::DataPackManager::scan(&config.data_pack_dir);

    match project::ProjectState::open(&path, &data_packs) {
        Ok(proj) => {
            eprintln!(
                "Building project '{}' for device '{}'...",
                proj.manifest.name, proj.manifest.device
            );
            let results = toolchain::generate_bitstream(&proj);
            for result in &results {
                if result.success {
                    eprintln!("[{}] OK", result.stage);
                } else {
                    eprintln!("[{}] FAILED", result.stage);
                }
                eprintln!("{}", result.log);
            }
            if results.iter().all(|r| r.success) {
                eprintln!("Build complete.");
            } else {
                std::process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("Error: {e}");
            std::process::exit(1);
        }
    }
}
