use iced::widget::{button, column, container, pick_list, row, text, text_input};
use iced::{Center, Element, Fill};
use rust_i18n::t;

use crate::app::Message;

pub struct NewProjectForm {
    pub name: String,
    pub device: Option<String>,
    pub top_module: String,
    pub directory: Option<std::path::PathBuf>,
}

impl Default for NewProjectForm {
    fn default() -> Self {
        Self {
            name: String::new(),
            device: None,
            top_module: "top".to_string(),
            directory: None,
        }
    }
}

impl NewProjectForm {
    pub fn is_valid(&self) -> bool {
        !self.name.is_empty() && self.device.is_some() && self.directory.is_some()
    }
}

pub fn view<'a>(form: &NewProjectForm, device_names: Vec<String>) -> Element<'a, Message> {
    let dir_label = match &form.directory {
        Some(p) => p.display().to_string(),
        None => t!("project.no_directory").to_string(),
    };

    let create_button = if form.is_valid() {
        button(text(t!("project.create").to_string())).on_press(Message::CreateProject)
    } else {
        button(text(t!("project.create").to_string()))
    };

    let content = column![
        text(t!("project.new_title").to_string()).size(24),
        text(t!("project.name_label").to_string()).size(14),
        text_input("", &form.name).on_input(Message::NewProjectName),
        text(t!("project.device_label").to_string()).size(14),
        pick_list(device_names, form.device.clone(), Message::NewProjectDevice),
        text(t!("project.top_module_label").to_string()).size(14),
        text_input("top", &form.top_module).on_input(Message::NewProjectTopModule),
        text(t!("project.directory_label").to_string()).size(14),
        row![
            text(dir_label),
            button(text(t!("project.browse").to_string())).on_press(Message::NewProjectBrowse),
        ]
        .spacing(8),
        row![
            create_button,
            button(text(t!("project.cancel").to_string())).on_press(Message::CancelNewProject),
        ]
        .spacing(8),
    ]
    .spacing(8)
    .align_x(Center)
    .max_width(500);

    container(content)
        .width(Fill)
        .height(Fill)
        .center(Fill)
        .into()
}
