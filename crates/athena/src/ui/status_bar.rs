use iced::Element;
use iced::Length;
use iced::widget::{container, row, text};
use rust_i18n::t;

use crate::app::Message;
use crate::project::ProjectState;

pub fn view<'a>(project: &Option<ProjectState>) -> Element<'a, Message> {
    let status = match project {
        Some(proj) => format!(
            "{} - {} ({})",
            proj.manifest.name,
            proj.manifest.device,
            proj.project_dir.display()
        ),
        None => t!("status.ready").to_string(),
    };

    container(row![text(status).size(12)])
        .width(Length::Fill)
        .padding([2, 8])
        .into()
}
