use iced_code_editor::CodeEditor;
use std::path::{Path, PathBuf};

pub struct Tab {
    pub editor: CodeEditor,
    pub file_path: PathBuf,
    pub dirty: bool,
}

impl Tab {
    fn open(path: &Path) -> Result<Self, String> {
        let contents =
            std::fs::read_to_string(path).map_err(|e| format!("Failed to read file: {e}"))?;
        let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("txt");

        Ok(Self {
            editor: CodeEditor::new(&contents, extension),
            file_path: path.to_path_buf(),
            dirty: false,
        })
    }

    pub fn save(&mut self) -> Result<(), String> {
        let text = self.editor.content();
        std::fs::write(&self.file_path, text).map_err(|e| format!("Failed to write file: {e}"))?;
        self.dirty = false;
        Ok(())
    }

    pub fn label(&self) -> String {
        let name = self
            .file_path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "untitled".to_string());
        if self.dirty {
            format!("{name} *")
        } else {
            name
        }
    }
}

pub struct EditorTabs {
    pub tabs: Vec<Tab>,
    pub active: Option<usize>,
}

impl EditorTabs {
    pub fn new() -> Self {
        Self {
            tabs: Vec::new(),
            active: None,
        }
    }

    pub fn open(&mut self, path: &Path) -> Result<(), String> {
        // If already open, just switch to it
        if let Some(idx) = self.tabs.iter().position(|t| t.file_path == path) {
            self.active = Some(idx);
            return Ok(());
        }

        let tab = Tab::open(path)?;
        self.tabs.push(tab);
        self.active = Some(self.tabs.len() - 1);
        Ok(())
    }

    pub fn close(&mut self, idx: usize) {
        if idx < self.tabs.len() {
            self.tabs.remove(idx);
            self.active = if self.tabs.is_empty() {
                None
            } else if let Some(active) = self.active {
                if active >= self.tabs.len() {
                    Some(self.tabs.len() - 1)
                } else if active > idx {
                    Some(active - 1)
                } else {
                    Some(active)
                }
            } else {
                None
            };
        }
    }

    pub fn active_tab(&self) -> Option<&Tab> {
        self.active.and_then(|i| self.tabs.get(i))
    }

    pub fn active_tab_mut(&mut self) -> Option<&mut Tab> {
        self.active.and_then(|i| self.tabs.get_mut(i))
    }

    pub fn save_active(&mut self) -> Result<(), String> {
        match self.active_tab_mut() {
            Some(tab) => tab.save(),
            None => Ok(()),
        }
    }
}
