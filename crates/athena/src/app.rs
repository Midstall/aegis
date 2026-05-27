use std::path::PathBuf;
use std::sync::Mutex;

use iced::widget::{column, container, row, rule};
use iced::{Element, Length, Size, Subscription, Task, Theme};
use rust_i18n::t;

use crate::config::AppConfig;
use crate::data_packs::DataPackManager;
use crate::editor::EditorTabs;
use crate::project::{ProjectManifest, ProjectState};
use crate::ui::new_project::NewProjectForm;
use crate::ui::settings::SettingsSection;
use crate::{first_run, ui};

static STARTUP_ACTION: Mutex<Option<StartupAction>> = Mutex::new(None);

enum StartupAction {
    OpenProject(PathBuf),
    NewProject {
        path: PathBuf,
        device: String,
        top_module: String,
    },
}

#[derive(Debug, Clone)]
pub enum Message {
    // Project
    NewProject,
    NewProjectName(String),
    NewProjectDevice(String),
    NewProjectTopModule(String),
    NewProjectBrowse,
    CreateProject,
    CancelNewProject,
    OpenProject,
    OpenProjectPath(std::path::PathBuf),
    ProjectError(String),
    SelectSource(usize),
    OpenManifest,
    NewSourceFile,
    AddExistingFile,
    CloseProject,
    // Editor / Tabs
    EditorEvent(iced_code_editor::Message),
    SwitchTab(usize),
    CloseTab(usize),
    SaveFile,
    // Tools
    Synthesize,
    PlaceRoute,
    GenerateBitstream,
    Simulate,
    ToolchainDone(Vec<crate::toolchain::ToolchainResult>),
    ClearConsole,
    ConsoleAction(iced::widget::text_editor::Action),
    ConsoleResize(f32),
    // Settings
    OpenSettings,
    CloseSettings,
    SettingsSection(SettingsSection),
    // App
    ShowAbout,
    CloseAbout,
    Quit,
    SetLanguage(String),
    FinishFirstRun,
    ShowDataPacks,
    HideDataPacks,
    Noop,
}

enum View {
    FirstRun,
    Main,
    DataPacks,
    NewProject,
    Settings,
    About,
}

pub struct Athena {
    config: AppConfig,
    project: Option<ProjectState>,
    data_packs: DataPackManager,
    view: View,
    system_theme: Theme,
    new_project_form: NewProjectForm,
    editor: EditorTabs,
    settings_section: SettingsSection,
    toolchain_log: Vec<crate::toolchain::ToolchainResult>,
    console_content: iced::widget::text_editor::Content,
    console_height: f32,
    error: Option<String>,
}

impl Athena {
    fn set_console_log(&mut self, log: Vec<crate::toolchain::ToolchainResult>) {
        self.toolchain_log = log;
        self.rebuild_console();
    }

    fn rebuild_console(&mut self) {
        if self.toolchain_log.is_empty() {
            self.console_content = iced::widget::text_editor::Content::new();
        } else {
            let text: String = self
                .toolchain_log
                .iter()
                .map(|r| {
                    let status = if r.success { "OK" } else { "FAIL" };
                    format!("[{}] {}\n{}", status, r.stage, r.log)
                })
                .collect::<Vec<_>>()
                .join("\n\n");
            self.console_content = iced::widget::text_editor::Content::with_text(&text);
        }
    }
}

fn boot() -> (Athena, Task<Message>) {
    let mut config = AppConfig::load();
    rust_i18n::set_locale(&config.language);
    let data_packs = DataPackManager::scan(&config.data_pack_dir);
    let system_theme = crate::theme::detect();

    let view = if config.first_run_complete {
        View::Main
    } else {
        View::FirstRun
    };

    // Handle startup action (CLI subcommand) or auto-open last project
    let startup = STARTUP_ACTION.lock().unwrap().take();
    let project = match startup {
        Some(StartupAction::OpenProject(path)) => ProjectState::open(&path, &data_packs).ok(),
        Some(StartupAction::NewProject {
            path,
            device,
            top_module,
        }) => {
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "untitled".to_string());
            let manifest = ProjectManifest {
                name,
                device,
                sources: Vec::new(),
                constraints: None,
                top_module: Some(top_module),
            };
            ProjectState::create(&path, manifest, &data_packs).ok()
        }
        None => config
            .last_project
            .as_ref()
            .and_then(|path| ProjectState::open(path, &data_packs).ok()),
    };

    if let Some(ref proj) = project {
        config.add_recent_project(proj.project_dir.clone());
        let _ = config.save();
    }

    (
        Athena {
            config,
            project,
            data_packs,
            view,
            system_theme,
            new_project_form: NewProjectForm::default(),
            editor: EditorTabs::new(),
            settings_section: SettingsSection::default(),
            toolchain_log: Vec::new(),
            console_content: iced::widget::text_editor::Content::new(),
            console_height: 200.0,
            error: None,
        },
        Task::none(),
    )
}

fn update(state: &mut Athena, message: Message) -> Task<Message> {
    state.error = None;

    match message {
        // New project form
        Message::NewProject => {
            state.new_project_form = NewProjectForm::default();
            state.view = View::NewProject;
            Task::none()
        }
        Message::NewProjectName(name) => {
            state.new_project_form.name = name;
            Task::none()
        }
        Message::NewProjectDevice(device) => {
            state.new_project_form.device = Some(device);
            Task::none()
        }
        Message::NewProjectTopModule(module) => {
            state.new_project_form.top_module = module;
            Task::none()
        }
        Message::NewProjectBrowse => {
            if let Some(dir) = rfd::FileDialog::new().pick_folder() {
                state.new_project_form.directory = Some(dir);
            }
            Task::none()
        }
        Message::CreateProject => {
            let form = &state.new_project_form;
            if let (Some(device), Some(dir)) = (&form.device, &form.directory) {
                let manifest = ProjectManifest {
                    name: form.name.clone(),
                    device: device.clone(),
                    sources: Vec::new(),
                    constraints: None,
                    top_module: if form.top_module.is_empty() {
                        None
                    } else {
                        Some(form.top_module.clone())
                    },
                };
                let project_dir = dir.join(&form.name);
                match ProjectState::create(&project_dir, manifest, &state.data_packs) {
                    Ok(proj) => {
                        state.config.add_recent_project(proj.project_dir.clone());
                        let _ = state.config.save();
                        state.project = Some(proj);
                        state.view = View::Main;
                    }
                    Err(e) => {
                        state.error = Some(e);
                    }
                }
            }
            Task::none()
        }
        Message::CancelNewProject => {
            state.view = View::Main;
            Task::none()
        }

        // Open project
        Message::OpenProject => {
            if let Some(dir) = rfd::FileDialog::new().pick_folder() {
                match ProjectState::open(&dir, &state.data_packs) {
                    Ok(proj) => {
                        state.config.add_recent_project(proj.project_dir.clone());
                        let _ = state.config.save();
                        state.project = Some(proj);
                    }
                    Err(e) => {
                        state.error = Some(e);
                    }
                }
            }
            Task::none()
        }
        Message::OpenProjectPath(dir) => {
            match ProjectState::open(&dir, &state.data_packs) {
                Ok(proj) => {
                    state.config.add_recent_project(proj.project_dir.clone());
                    let _ = state.config.save();
                    state.project = Some(proj);
                }
                Err(e) => {
                    state.error = Some(e);
                }
            }
            Task::none()
        }
        Message::ProjectError(e) => {
            state.error = Some(e);
            Task::none()
        }
        Message::SelectSource(idx) => {
            if let Some(ref mut proj) = state.project {
                proj.selected_source = Some(idx);
                proj.manifest_open = false;
                let source = &proj.manifest.sources[idx];
                let path = proj.project_dir.join(source);
                if let Err(e) = state.editor.open(&path) {
                    state.error = Some(e);
                }
            }
            Task::none()
        }
        Message::OpenManifest => {
            if let Some(ref mut proj) = state.project {
                proj.selected_source = None;
                proj.manifest_open = true;
                let path = proj.project_dir.join("athena.toml");
                if let Err(e) = state.editor.open(&path) {
                    state.error = Some(e);
                }
            }
            Task::none()
        }
        Message::NewSourceFile => {
            if let Some(ref mut proj) = state.project {
                if let Some(path) = rfd::FileDialog::new()
                    .set_directory(&proj.project_dir)
                    .add_filter("Verilog", &["v", "vh"])
                    .save_file()
                {
                    // Create the empty file
                    let _ = std::fs::write(&path, "");

                    let relative = path
                        .strip_prefix(&proj.project_dir)
                        .map(|p| p.to_string_lossy().to_string())
                        .unwrap_or_else(|_| path.to_string_lossy().to_string());

                    if !proj.manifest.sources.contains(&relative) {
                        proj.manifest.sources.push(relative.clone());
                        let _ = proj.save();
                    }

                    // Open the new file in the editor
                    let idx = proj.manifest.sources.iter().position(|s| s == &relative);
                    proj.selected_source = idx;
                    proj.manifest_open = false;
                    if let Err(e) = state.editor.open(&path) {
                        state.error = Some(e);
                    }
                }
            }
            Task::none()
        }
        Message::AddExistingFile => {
            if let Some(ref mut proj) = state.project {
                if let Some(path) = rfd::FileDialog::new()
                    .set_directory(&proj.project_dir)
                    .add_filter("Verilog", &["v", "vh"])
                    .add_filter("All files", &["*"])
                    .pick_file()
                {
                    let relative = path
                        .strip_prefix(&proj.project_dir)
                        .map(|p| p.to_string_lossy().to_string())
                        .unwrap_or_else(|_| path.to_string_lossy().to_string());

                    if !proj.manifest.sources.contains(&relative) {
                        proj.manifest.sources.push(relative);
                        let _ = proj.save();
                    }
                }
            }
            Task::none()
        }
        Message::EditorEvent(event) => {
            let is_edit = matches!(
                event,
                iced_code_editor::Message::CharacterInput(_)
                    | iced_code_editor::Message::Backspace
                    | iced_code_editor::Message::Delete
                    | iced_code_editor::Message::DeleteSelection
                    | iced_code_editor::Message::Enter
                    | iced_code_editor::Message::Tab
                    | iced_code_editor::Message::Paste(_)
                    | iced_code_editor::Message::Undo
                    | iced_code_editor::Message::Redo
                    | iced_code_editor::Message::ReplaceNext
                    | iced_code_editor::Message::ReplaceAll
            );
            if let Some(tab) = state.editor.active_tab_mut() {
                let task = tab.editor.update(&event);
                if is_edit {
                    tab.dirty = true;
                }
                return task.map(Message::EditorEvent);
            }
            Task::none()
        }
        Message::SwitchTab(idx) => {
            state.editor.active = Some(idx);
            Task::none()
        }
        Message::CloseTab(idx) => {
            state.editor.close(idx);
            Task::none()
        }
        Message::SaveFile => {
            if let Err(e) = state.editor.save_active() {
                state.error = Some(e);
            }
            Task::none()
        }
        Message::CloseProject => {
            state.project = None;
            state.config.last_project = None;
            let _ = state.config.save();
            Task::none()
        }

        // Tools
        Message::Synthesize => {
            if let Some(ref proj) = state.project {
                let result = crate::toolchain::synthesize(proj);
                state.set_console_log(vec![result]);
            }
            Task::none()
        }
        Message::PlaceRoute => {
            if let Some(ref proj) = state.project {
                let result = crate::toolchain::place_route(proj);
                state.set_console_log(vec![result]);
            }
            Task::none()
        }
        Message::GenerateBitstream => {
            if let Some(ref proj) = state.project {
                let results = crate::toolchain::generate_bitstream(proj);
                state.set_console_log(results);
            }
            Task::none()
        }
        Message::Simulate => {
            if let Some(ref proj) = state.project {
                let result = crate::toolchain::simulate(proj, 1000);
                state.set_console_log(vec![result]);
            }
            Task::none()
        }
        Message::ToolchainDone(results) => {
            state.set_console_log(results);
            Task::none()
        }
        Message::ConsoleAction(action) => {
            // Allow selection and navigation but ignore edits
            if !action.is_edit() {
                state.console_content.perform(action);
            }
            Task::none()
        }
        Message::ClearConsole => {
            state.set_console_log(Vec::new());
            Task::none()
        }
        Message::ConsoleResize(delta) => {
            state.console_height = (state.console_height - delta).clamp(80.0, 600.0);
            Task::none()
        }

        // App
        Message::ShowAbout => {
            state.view = View::About;
            Task::none()
        }
        Message::CloseAbout => {
            state.view = View::Main;
            Task::none()
        }
        Message::Quit => {
            std::process::exit(0);
        }
        Message::SetLanguage(code) => {
            state.config.language = code.clone();
            rust_i18n::set_locale(&code);
            Task::none()
        }
        Message::FinishFirstRun => {
            state.config.first_run_complete = true;
            let _ = state.config.save();
            state.view = View::Main;
            Task::none()
        }
        Message::ShowDataPacks => {
            state.settings_section = SettingsSection::DataPacks;
            state.view = View::Settings;
            Task::none()
        }
        Message::Noop => Task::none(),
        Message::HideDataPacks => {
            state.data_packs = DataPackManager::scan(&state.config.data_pack_dir);
            state.view = View::Main;
            Task::none()
        }
        Message::OpenSettings => {
            state.settings_section = SettingsSection::General;
            state.view = View::Settings;
            Task::none()
        }
        Message::CloseSettings => {
            state.data_packs = DataPackManager::scan(&state.config.data_pack_dir);
            state.view = View::Main;
            Task::none()
        }
        Message::SettingsSection(section) => {
            state.settings_section = section;
            Task::none()
        }
    }
}

fn view(state: &Athena) -> Element<'_, Message> {
    match state.view {
        View::FirstRun => first_run::view(&state.config.language),
        View::DataPacks => ui::data_pack_view::view(&state.data_packs),
        View::NewProject => {
            ui::new_project::view(&state.new_project_form, state.data_packs.device_names())
        }
        View::Settings => {
            ui::settings::view(state.settings_section, &state.config, &state.data_packs)
        }
        View::About => ui::about::view(),
        View::Main => view_main(state),
    }
}

fn view_main(state: &Athena) -> Element<'_, Message> {
    let menu_bar = ui::menu_bar::view(state.project.is_some());

    let body: Element<'_, Message> = if state.project.is_some() {
        let sidebar = ui::sidebar::view(&state.project);
        let content = ui::content::view(&state.project, &state.editor);
        let console = ui::console::view(&state.console_content, state.console_height);
        let status_bar = ui::status_bar::view(&state.project);

        let main_area = row![sidebar, container(content).width(Length::Fill),];

        column![
            main_area,
            rule::horizontal(1),
            console,
            rule::horizontal(1),
            status_bar,
        ]
        .into()
    } else {
        ui::home::view(&state.config.recent_projects)
    };

    column![menu_bar, rule::horizontal(1), body,].into()
}

fn theme(state: &Athena) -> Theme {
    state.system_theme.clone()
}

fn title(_state: &Athena) -> String {
    t!("app.title").to_string()
}

const MIN_WINDOW_SIZE: Size = Size::new(800.0, 600.0);

fn subscription(_state: &Athena) -> Subscription<Message> {
    Subscription::none()
}

pub fn run() -> iced::Result {
    iced::application(boot, update, view)
        .subscription(subscription)
        .title(title)
        .theme(theme)
        .window_size(Size::new(1200.0, 800.0))
        .window(iced::window::Settings {
            min_size: Some(MIN_WINDOW_SIZE),
            ..Default::default()
        })
        .centered()
        .run()
}

pub fn run_with_project(path: PathBuf) -> iced::Result {
    *STARTUP_ACTION.lock().unwrap() = Some(StartupAction::OpenProject(path));
    run()
}

pub fn run_new_project(path: PathBuf, device: String, top_module: String) -> iced::Result {
    *STARTUP_ACTION.lock().unwrap() = Some(StartupAction::NewProject {
        path,
        device,
        top_module,
    });
    run()
}
