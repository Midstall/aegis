use iced::widget::{button, column, container, row, rule, scrollable, text};
use iced::{Center, Element, Fill, Length};
use rust_i18n::t;

use crate::app::Message;
use std::path::PathBuf;

pub fn view<'a>(recent_projects: &[PathBuf]) -> Element<'a, Message> {
    let mut content = column![
        text(t!("home.welcome").to_string()).size(28),
        text(t!("home.subtitle").to_string()).size(14),
        row![
            button(text(t!("menu.new_project").to_string()).size(14))
                .on_press(Message::NewProject)
                .padding([8, 16]),
            button(text(t!("menu.open_project").to_string()).size(14))
                .on_press(Message::OpenProject)
                .padding([8, 16]),
        ]
        .spacing(8),
    ]
    .spacing(12)
    .align_x(Center);

    if !recent_projects.is_empty() {
        content = content.push(rule::horizontal(1));
        content = content.push(text(t!("home.recent_projects").to_string()).size(18));

        let items: Vec<Element<'a, Message>> = recent_projects
            .iter()
            .map(|path| {
                let dir_name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| path.display().to_string());
                let full_path = path.display().to_string();

                button(column![text(dir_name).size(14), text(full_path).size(11),].spacing(2))
                    .on_press(Message::OpenProjectPath(path.clone()))
                    .width(Length::Fill)
                    .padding([8, 12])
                    .into()
            })
            .collect();

        content = content.push(scrollable(column(items).spacing(4)).height(Length::Fill));
    }

    container(content.max_width(600))
        .width(Fill)
        .height(Fill)
        .center(Fill)
        .padding(32)
        .into()
}
