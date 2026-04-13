use iced::widget::{button, column, container, rule, scrollable, text};
use iced::{Element, Length};
use rust_i18n::t;

use crate::app::Message;
use crate::project::ProjectState;

pub fn view<'a>(project: &'a Option<ProjectState>) -> Element<'a, Message> {
    let content: Element<'a, Message> = match project {
        Some(proj) => {
            let mut items: Vec<Element<'a, Message>> = vec![
                text(&proj.manifest.name).size(16).into(),
                text(&proj.manifest.device).size(12).into(),
                rule::horizontal(1).into(),
            ];

            // Project manifest
            let manifest_selected = proj.selected_source.is_none() && proj.manifest_open;
            let manifest_btn = if manifest_selected {
                button(text("athena.toml").size(13))
            } else {
                button(text("athena.toml").size(13)).on_press(Message::OpenManifest)
            };
            items.push(manifest_btn.into());

            // Source files header + add button
            if !proj.manifest.sources.is_empty() {
                items.push(text(t!("sidebar.sources").to_string()).size(12).into());
            }

            for (i, source) in proj.manifest.sources.iter().enumerate() {
                let label = source.clone();
                let is_selected = proj.selected_source == Some(i);
                let btn = if is_selected {
                    button(text(label).size(13))
                } else {
                    button(text(label).size(13)).on_press(Message::SelectSource(i))
                };
                items.push(btn.into());
            }

            items.push(rule::horizontal(1).into());

            // Add file button
            items.push(
                button(text(t!("sidebar.add_file").to_string()).size(12))
                    .on_press(Message::NewSourceFile)
                    .into(),
            );

            scrollable(column(items).spacing(4)).into()
        }
        None => text(t!("sidebar.no_project").to_string()).into(),
    };

    container(
        column![text(t!("sidebar.navigator").to_string()).size(14), content,]
            .spacing(8)
            .padding(8),
    )
    .width(Length::Fixed(200.0))
    .height(Length::Fill)
    .into()
}
