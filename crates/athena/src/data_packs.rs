use aegis_ip::AegisFpgaDeviceDescriptor;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct DataPack {
    pub name: String,
    pub path: PathBuf,
    pub descriptor: AegisFpgaDeviceDescriptor,
}

#[derive(Debug, Default)]
pub struct DataPackManager {
    pub packs: Vec<DataPack>,
}

impl DataPackManager {
    /// Scan both the user data pack directory and the bundled system directory.
    /// User packs take precedence over bundled packs with the same name.
    pub fn scan(user_dir: &Path) -> Self {
        let mut packs_by_name: HashMap<String, DataPack> = HashMap::new();

        // Bundled data packs (next to the binary: ../share/athena/data-packs/)
        if let Some(bundled_dir) = bundled_data_pack_dir() {
            for pack in scan_dir(&bundled_dir) {
                packs_by_name.insert(pack.name.clone(), pack);
            }
        }

        // User data packs override bundled ones
        for pack in scan_dir(user_dir) {
            packs_by_name.insert(pack.name.clone(), pack);
        }

        let mut packs: Vec<DataPack> = packs_by_name.into_values().collect();
        packs.sort_by(|a, b| a.name.cmp(&b.name));
        Self { packs }
    }

    pub fn find_device(&self, name: &str) -> Option<&DataPack> {
        self.packs.iter().find(|p| p.name == name)
    }

    pub fn device_names(&self) -> Vec<String> {
        self.packs.iter().map(|p| p.name.clone()).collect()
    }
}

fn bundled_data_pack_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    // exe is at <prefix>/bin/athena, data packs at <prefix>/share/athena/data-packs/
    let prefix = exe.parent()?.parent()?;
    let dir = prefix.join("share").join("athena").join("data-packs");
    dir.exists().then_some(dir)
}

fn scan_dir(dir: &Path) -> Vec<DataPack> {
    let mut packs = Vec::new();

    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "json") {
                if let Some(pack) = load_pack(&path) {
                    packs.push(pack);
                }
            }
        }
    }

    packs
}

fn load_pack(path: &Path) -> Option<DataPack> {
    let contents = std::fs::read_to_string(path).ok()?;
    let descriptor: AegisFpgaDeviceDescriptor = serde_json::from_str(&contents).ok()?;
    let name = descriptor.device.clone();
    Some(DataPack {
        name,
        path: path.to_path_buf(),
        descriptor,
    })
}
