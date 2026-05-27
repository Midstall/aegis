use iced::widget::{button, column, container, mouse_area, row, rule, text, text_editor};
use iced::{Element, Length};
use rust_i18n::t;

use crate::app::Message;

pub fn view<'a>(content: &'a text_editor::Content, height: f32) -> Element<'a, Message> {
    let header = row![
        text(t!("console.title").to_string()).size(12),
        iced::widget::space().width(Length::Fill),
        button(text(t!("console.clear").to_string()).size(11))
            .on_press(Message::ClearConsole)
            .padding([2, 8]),
    ]
    .align_y(iced::Center);

    let editor = text_editor(content)
        .on_action(Message::ConsoleAction)
        .size(11)
        .height(Length::Fill);

    let resize_handle = mouse_area(
        container(rule::horizontal(2))
            .width(Length::Fill)
            .padding([2, 0]),
    )
    .on_scroll(|delta| {
        let y = match delta {
            iced::mouse::ScrollDelta::Lines { y, .. } => y * 20.0,
            iced::mouse::ScrollDelta::Pixels { y, .. } => y,
        };
        Message::ConsoleResize(y)
    });

    column![
        resize_handle,
        container(
            column![header, rule::horizontal(1), editor]
                .spacing(4)
                .padding(8),
        )
        .width(Length::Fill)
        .height(Length::Fixed(height)),
    ]
    .into()
}
