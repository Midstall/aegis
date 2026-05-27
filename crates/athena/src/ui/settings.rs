use iced::widget::{button, column, container, row, rule, scrollable, text};
use iced::{Element, Length};
use rust_i18n::t;

use crate::app::Message;
use crate::config::AppConfig;
use crate::data_packs::DataPackManager;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingsSection {
    General,
    DataPacks,
}

impl Default for SettingsSection {
    fn default() -> Self {
        Self::General
    }
}

fn section_button<'a>(
    label: String,
    section: SettingsSection,
    current: SettingsSection,
) -> Element<'a, Message> {
    let btn = button(text(label).size(13))
        .width(Length::Fill)
        .padding([6, 12]);
    if section == current {
        btn.into()
    } else {
        btn.on_press(Message::SettingsSection(section)).into()
    }
}

pub fn view<'a>(
    section: SettingsSection,
    config: &AppConfig,
    data_packs: &'a DataPackManager,
) -> Element<'a, Message> {
    let sidebar = container(
        column![
            text(t!("settings.title").to_string()).size(20),
            rule::horizontal(1),
            section_button(
                t!("settings.general").to_string(),
                SettingsSection::General,
                section,
            ),
            section_button(
                t!("settings.toolchain_data_packs").to_string(),
                SettingsSection::DataPacks,
                section,
            ),
        ]
        .spacing(4)
        .padding(12),
    )
    .width(Length::Fixed(220.0))
    .height(Length::Fill);

    let content: Element<'a, Message> = match section {
        SettingsSection::General => view_general(config),
        SettingsSection::DataPacks => view_data_packs(data_packs),
    };

    let main = row![
        sidebar,
        rule::vertical(1),
        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .padding(16),
    ];

    column![
        main,
        rule::horizontal(1),
        container(
            row![
                iced::widget::space().width(Length::Fill),
                button(text(t!("settings.close").to_string()).size(13))
                    .on_press(Message::CloseSettings)
                    .padding([6, 16]),
            ]
            .padding(8),
        ),
    ]
    .into()
}

fn view_general<'a>(config: &AppConfig) -> Element<'a, Message> {
    column![
        text(t!("settings.general").to_string()).size(18),
        text(format!("{}: {}", t!("settings.language"), &config.language)).size(14),
        text(format!(
            "{}: {}",
            t!("settings.data_pack_dir"),
            config.data_pack_dir.display()
        ))
        .size(14),
    ]
    .spacing(8)
    .into()
}

fn view_data_packs<'a>(manager: &'a DataPackManager) -> Element<'a, Message> {
    let header = text(t!("settings.toolchain_data_packs").to_string()).size(18);

    let pack_list: Element<'a, Message> = if manager.packs.is_empty() {
        text(t!("data_packs.empty").to_string()).into()
    } else {
        let items: Vec<Element<'a, Message>> = manager
            .packs
            .iter()
            .map(|pack| {
                let device = &pack.name;
                let path = pack.path.display().to_string();
                column![text(device).size(14), text(path).size(11),]
                    .spacing(2)
                    .padding(6)
                    .into()
            })
            .collect();

        scrollable(column(items).spacing(4)).into()
    };

    column![header, rule::horizontal(1), pack_list]
        .spacing(8)
        .into()
}
