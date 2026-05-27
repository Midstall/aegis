use aegis_ip::AegisFpgaDeviceDescriptor;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::data_packs::DataPackManager;

const MANIFEST_FILE: &str = "athena.toml";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectManifest {
    pub name: String,
    pub device: String,
    #[serde(default)]
    pub sources: Vec<String>,
    #[serde(default)]
    pub constraints: Option<String>,
    #[serde(default)]
    pub top_module: Option<String>,
}

#[derive(Debug)]
pub struct ProjectState {
    pub manifest: ProjectManifest,
    pub project_dir: PathBuf,
    pub descriptor: AegisFpgaDeviceDescriptor,
    pub descriptor_path: Option<PathBuf>,
    pub selected_source: Option<usize>,
    pub manifest_open: bool,
}

impl ProjectState {
    pub fn create(
        dir: &Path,
        manifest: ProjectManifest,
        data_packs: &DataPackManager,
    ) -> Result<Self, String> {
        let pack = data_packs
            .find_device(&manifest.device)
            .ok_or_else(|| format!("Device '{}' not found in data packs", manifest.device))?;
        let descriptor = pack.descriptor.clone();
        let descriptor_path = Some(pack.path.clone());

        std::fs::create_dir_all(dir)
            .map_err(|e| format!("Failed to create project directory: {e}"))?;

        let manifest_path = dir.join(MANIFEST_FILE);
        let contents = toml::to_string_pretty(&manifest)
            .map_err(|e| format!("Failed to serialize manifest: {e}"))?;
        std::fs::write(&manifest_path, contents)
            .map_err(|e| format!("Failed to write manifest: {e}"))?;

        Ok(Self {
            manifest,
            project_dir: dir.to_path_buf(),
            descriptor,
            descriptor_path,
            selected_source: None,
            manifest_open: false,
        })
    }

    pub fn open(dir: &Path, data_packs: &DataPackManager) -> Result<Self, String> {
        let manifest_path = dir.join(MANIFEST_FILE);
        let contents = std::fs::read_to_string(&manifest_path)
            .map_err(|e| format!("Failed to read {MANIFEST_FILE}: {e}"))?;
        let manifest: ProjectManifest = toml::from_str(&contents)
            .map_err(|e| format!("Failed to parse {MANIFEST_FILE}: {e}"))?;

        let pack = data_packs
            .find_device(&manifest.device)
            .ok_or_else(|| format!("Device '{}' not found in data packs", manifest.device))?;
        let descriptor = pack.descriptor.clone();
        let descriptor_path = Some(pack.path.clone());

        Ok(Self {
            manifest,
            project_dir: dir.to_path_buf(),
            descriptor,
            descriptor_path,
            selected_source: None,
            manifest_open: false,
        })
    }

    pub fn save(&self) -> Result<(), String> {
        let manifest_path = self.project_dir.join(MANIFEST_FILE);
        let contents = toml::to_string_pretty(&self.manifest)
            .map_err(|e| format!("Failed to serialize manifest: {e}"))?;
        std::fs::write(&manifest_path, contents)
            .map_err(|e| format!("Failed to write manifest: {e}"))?;
        Ok(())
    }
}
