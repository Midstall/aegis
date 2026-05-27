use iced::widget::{button, center, column, container, row, rule, scrollable, text};
use iced::{Element, Length};
use rust_i18n::t;

use crate::app::Message;
use crate::editor::EditorTabs;
use crate::project::ProjectState;

fn tab_bar<'a>(editor: &EditorTabs) -> Element<'a, Message> {
    let tabs: Vec<Element<'a, Message>> = editor
        .tabs
        .iter()
        .enumerate()
        .map(|(i, tab)| {
            let is_active = editor.active == Some(i);
            let label = tab.label();

            let tab_btn = button(text(label).size(12)).padding([4, 8]);
            let tab_btn = if is_active {
                tab_btn
            } else {
                tab_btn.on_press(Message::SwitchTab(i))
            };

            let close_btn = button(text("x").size(10))
                .on_press(Message::CloseTab(i))
                .padding([2, 6]);

            row![tab_btn, close_btn].spacing(2).into()
        })
        .collect();

    container(
        scrollable(row(tabs).spacing(4)).direction(scrollable::Direction::Horizontal(
            scrollable::Scrollbar::default(),
        )),
    )
    .padding([4, 4])
    .width(Length::Fill)
    .into()
}

pub fn view<'a>(project: &Option<ProjectState>, editor: &'a EditorTabs) -> Element<'a, Message> {
    match project {
        Some(proj) if !editor.tabs.is_empty() => {
            let tabs = tab_bar(editor);

            let content: Element<'a, Message> = match editor.active_tab() {
                Some(tab) => tab.editor.view().map(Message::EditorEvent),
                None => center(text("")).into(),
            };

            column![tabs, rule::horizontal(1), content].into()
        }
        Some(proj) => {
            let name = proj.manifest.name.clone();
            let device = format!("{}: {}", t!("project.device_label"), &proj.manifest.device);
            let source_count = format!("{} source file(s)", proj.manifest.sources.len());
            column![text(name).size(20), text(device), text(source_count),]
                .spacing(8)
                .padding(16)
                .into()
        }
        None => center(text(t!("content.get_started").to_string())).into(),
    }
}
