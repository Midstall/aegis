use iced::widget::{button, text};
use iced::{Element, Length};
use rust_i18n::t;

use iced_aw::menu::{Item, Menu};
use iced_aw::{menu_bar, menu_items};

use crate::app::Message;

fn menu_button<'a>(label: String) -> Element<'a, Message> {
    button(text(label).size(13))
        .padding([4, 12])
        .width(Length::Fill)
        .into()
}

fn menu_action<'a>(label: String, message: Message) -> Element<'a, Message> {
    button(text(label).size(13))
        .on_press(message)
        .padding([4, 12])
        .width(Length::Fill)
        .into()
}

fn top_button<'a>(label: String) -> Element<'a, Message> {
    button(text(label).size(13)).padding([4, 10]).into()
}

pub fn view<'a>(has_project: bool) -> Element<'a, Message> {
    let menu_tpl = |items| Menu::new(items).width(220.0).offset(4.0);

    // File
    let file_menu = if has_project {
        menu_tpl(menu_items!(
            (menu_action(t!("menu.new_project").to_string(), Message::NewProject)),
            (menu_action(t!("menu.open_project").to_string(), Message::OpenProject)),
            (menu_action(t!("menu.save").to_string(), Message::SaveFile)),
            (menu_action(t!("menu.close_project").to_string(), Message::CloseProject)),
            (menu_action(t!("menu.settings").to_string(), Message::OpenSettings)),
            (menu_action(t!("menu.quit").to_string(), Message::Quit)),
        ))
    } else {
        menu_tpl(menu_items!(
            (menu_action(t!("menu.new_project").to_string(), Message::NewProject)),
            (menu_action(t!("menu.open_project").to_string(), Message::OpenProject)),
            (menu_action(t!("menu.settings").to_string(), Message::OpenSettings)),
            (menu_action(t!("menu.quit").to_string(), Message::Quit)),
        ))
    };

    // Edit
    let edit_menu = menu_tpl(menu_items!(
        (menu_button(t!("menu.undo").to_string())),
        (menu_button(t!("menu.redo").to_string())),
        (menu_button(t!("menu.cut").to_string())),
        (menu_button(t!("menu.copy").to_string())),
        (menu_button(t!("menu.paste").to_string())),
        (menu_button(t!("menu.find").to_string())),
    ));

    // Project
    let project_menu = if has_project {
        menu_tpl(menu_items!(
            (menu_action(t!("menu.new_file").to_string(), Message::NewSourceFile)),
            (menu_action(
                t!("menu.add_existing").to_string(),
                Message::AddExistingFile
            )),
            (menu_action(
                t!("menu.project_settings").to_string(),
                Message::OpenManifest
            )),
        ))
    } else {
        menu_tpl(menu_items!(
            (menu_button(t!("menu.new_file").to_string())),
            (menu_button(t!("menu.add_existing").to_string())),
            (menu_button(t!("menu.project_settings").to_string())),
        ))
    };

    // Tools
    let tools_menu = if has_project {
        menu_tpl(menu_items!(
            (menu_action(t!("menu.synthesize").to_string(), Message::Synthesize)),
            (menu_action(t!("menu.place_route").to_string(), Message::PlaceRoute)),
            (menu_action(
                t!("menu.generate_bitstream").to_string(),
                Message::GenerateBitstream
            )),
            (menu_action(t!("menu.simulate").to_string(), Message::Simulate)),
        ))
    } else {
        menu_tpl(menu_items!(
            (menu_button(t!("menu.synthesize").to_string())),
            (menu_button(t!("menu.place_route").to_string())),
            (menu_button(t!("menu.generate_bitstream").to_string())),
            (menu_button(t!("menu.simulate").to_string())),
        ))
    };

    // Help
    let help_menu = menu_tpl(menu_items!(
        (menu_action(t!("menu.about").to_string(), Message::ShowAbout)),
    ));

    menu_bar!(
        (top_button(t!("menu.file").to_string()), file_menu),
        (top_button(t!("menu.edit").to_string()), edit_menu),
        (top_button(t!("menu.project").to_string()), project_menu),
        (top_button(t!("menu.tools").to_string()), tools_menu),
        (top_button(t!("menu.help").to_string()), help_menu),
    )
    .into()
}
