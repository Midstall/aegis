use iced::widget::{button, column, container, row, scrollable, text};
use iced::{Element, Length};
use rust_i18n::t;

use crate::app::Message;
use crate::data_packs::DataPackManager;

pub fn view<'a>(manager: &'a DataPackManager) -> Element<'a, Message> {
    let header = text(t!("data_packs.title").to_string()).size(20);

    let pack_list: Element<'a, Message> = if manager.packs.is_empty() {
        text(t!("data_packs.empty").to_string()).into()
    } else {
        let items: Vec<Element<'a, Message>> = manager
            .packs
            .iter()
            .map(|pack| {
                row![
                    text(&pack.name).width(Length::Fill),
                    text(pack.path.display().to_string()).size(11),
                ]
                .spacing(8)
                .padding(4)
                .into()
            })
            .collect();

        scrollable(column(items).spacing(4)).into()
    };

    let back_button =
        button(text(t!("data_packs.back").to_string())).on_press(Message::HideDataPacks);

    container(
        column![header, pack_list, back_button]
            .spacing(12)
            .padding(16),
    )
    .width(Length::Fill)
    .height(Length::Fill)
    .into()
}
