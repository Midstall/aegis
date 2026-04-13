use iced::widget::{button, column, container, pick_list, text};
use iced::{Center, Element, Fill};
use rust_i18n::t;

use crate::app::Message;

const LANGUAGES: &[(&str, &str)] = &[
    ("en", "English"),
    ("de", "Deutsch"),
    ("es", "Espanol"),
    ("fr", "Francais"),
    ("ja", "Japanese"),
    ("zh-CN", "Chinese (Simplified)"),
];

pub fn view<'a>(selected_language: &str) -> Element<'a, Message> {
    let language_options: Vec<String> =
        LANGUAGES.iter().map(|(_, name)| name.to_string()).collect();

    let selected = LANGUAGES
        .iter()
        .find(|(code, _)| *code == selected_language)
        .map(|(_, name)| name.to_string());

    let content = column![
        text(t!("first_run.welcome").to_string()).size(28),
        text(t!("first_run.select_language").to_string()).size(16),
        pick_list(language_options, selected, |name| {
            let code = LANGUAGES
                .iter()
                .find(|(_, n)| *n == name)
                .map(|(c, _)| c.to_string())
                .unwrap_or_else(|| "en".to_string());
            Message::SetLanguage(code)
        }),
        button(text(t!("first_run.continue").to_string())).on_press(Message::FinishFirstRun),
    ]
    .spacing(16)
    .align_x(Center);

    container(content)
        .width(Fill)
        .height(Fill)
        .center(Fill)
        .into()
}
