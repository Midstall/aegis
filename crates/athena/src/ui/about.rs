use iced::widget::{button, column, container, rule, text};
use iced::{Center, Element, Fill};
use rust_i18n::t;

use crate::app::Message;

pub fn view<'a>() -> Element<'a, Message> {
    let content = column![
        text("Athena").size(32),
        text(format!("v{}", env!("CARGO_PKG_VERSION"))).size(14),
        rule::horizontal(1),
        text(t!("about.description").to_string()).size(14),
        text(t!("about.license").to_string()).size(12),
        text(t!("about.website").to_string()).size(12),
        rule::horizontal(1),
        button(text(t!("about.close").to_string()).size(13))
            .on_press(Message::CloseAbout)
            .padding([6, 16]),
    ]
    .spacing(12)
    .align_x(Center)
    .max_width(400);

    container(content)
        .width(Fill)
        .height(Fill)
        .center(Fill)
        .into()
}
