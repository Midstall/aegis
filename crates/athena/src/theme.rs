use iced::Theme;

/// Detect the system theme and return an appropriate iced Theme.
///
/// With the `cosmic` feature enabled, this checks if COSMIC is the active
/// desktop and reads its full theme config from disk. Otherwise, falls back
/// to basic dark/light detection via `dark-light`.
pub fn detect() -> Theme {
    #[cfg(feature = "cosmic")]
    if let Some(theme) = cosmic::detect() {
        return theme;
    }

    detect_fallback()
}

fn detect_fallback() -> Theme {
    match dark_light::detect() {
        Ok(dark_light::Mode::Light) => Theme::Light,
        _ => Theme::Dark,
    }
}

#[cfg(feature = "cosmic")]
mod cosmic {
    use iced::Theme;
    use serde::Deserialize;
    use std::path::PathBuf;

    /// RGBA color as stored in COSMIC config Ron files.
    #[derive(Debug, Clone, Deserialize)]
    struct Rgba {
        red: f32,
        green: f32,
        blue: f32,
        alpha: f32,
    }

    impl Rgba {
        fn to_iced(&self) -> iced::Color {
            iced::Color::from_rgba(self.red, self.green, self.blue, self.alpha)
        }
    }

    /// A COSMIC Component (interactive element with state colors).
    #[derive(Debug, Clone, Deserialize)]
    #[allow(dead_code)]
    struct Component {
        base: Rgba,
        hover: Rgba,
        pressed: Rgba,
        on: Rgba,
        selected: Rgba,
        focus: Rgba,
        disabled: Rgba,
        on_disabled: Rgba,
        divider: Rgba,
        selected_text: Rgba,
        border: Rgba,
        disabled_border: Rgba,
    }

    /// A COSMIC Container (background layer with component and text colors).
    #[derive(Debug, Clone, Deserialize)]
    #[allow(dead_code)]
    struct Container {
        base: Rgba,
        on: Rgba,
        component: Component,
        divider: Rgba,
        small_widget: Rgba,
    }

    fn cosmic_config_dir() -> Option<PathBuf> {
        dirs::config_dir().map(|d| d.join("cosmic"))
    }

    fn read_ron<T: for<'de> Deserialize<'de>>(path: &std::path::Path) -> Option<T> {
        let contents = std::fs::read_to_string(path).ok()?;
        ron::from_str(&contents).ok()
    }

    fn is_dark_mode() -> bool {
        let Some(config_dir) = cosmic_config_dir() else {
            return true;
        };
        let mode_file = config_dir
            .join("com.system76.CosmicTheme.Mode")
            .join("v1")
            .join("is_dark");
        match std::fs::read_to_string(&mode_file) {
            Ok(s) => s.trim() == "true",
            Err(_) => true, // default to dark
        }
    }

    pub fn detect() -> Option<Theme> {
        let desktop = std::env::var("XDG_CURRENT_DESKTOP").ok()?;
        if !desktop.split(':').any(|d| d == "COSMIC") {
            return None;
        }

        let config_dir = cosmic_config_dir()?;
        let is_dark = is_dark_mode();

        let theme_dir = if is_dark {
            config_dir.join("com.system76.CosmicTheme.Dark").join("v1")
        } else {
            config_dir.join("com.system76.CosmicTheme.Light").join("v1")
        };

        if !theme_dir.exists() {
            return None;
        }

        let accent: Component = read_ron(&theme_dir.join("accent"))?;
        let background: Container = read_ron(&theme_dir.join("background"))?;
        let success: Component = read_ron(&theme_dir.join("success"))?;
        let warning: Component = read_ron(&theme_dir.join("warning"))?;
        let destructive: Component = read_ron(&theme_dir.join("destructive"))?;

        let primary: Option<Container> = read_ron(&theme_dir.join("primary"));
        let secondary: Option<Container> = read_ron(&theme_dir.join("secondary"));

        let palette = iced::theme::Palette {
            background: background.base.to_iced(),
            text: background.on.to_iced(),
            primary: accent.base.to_iced(),
            success: success.base.to_iced(),
            warning: warning.base.to_iced(),
            danger: destructive.base.to_iced(),
        };

        let theme = Theme::custom_with_fn("COSMIC".to_string(), palette, move |palette| {
            use iced::theme::palette::{Background, Extended, Pair, Primary};

            let mut extended = Extended::generate(palette);

            let bg = background.base.to_iced();
            let bg_text = background.on.to_iced();

            if let Some(ref primary_c) = primary {
                extended.background = Background {
                    base: Pair {
                        color: bg,
                        text: bg_text,
                    },
                    weak: Pair {
                        color: primary_c.base.to_iced(),
                        text: primary_c.on.to_iced(),
                    },
                    strong: if let Some(ref secondary_c) = secondary {
                        Pair {
                            color: secondary_c.base.to_iced(),
                            text: secondary_c.on.to_iced(),
                        }
                    } else {
                        extended.background.strong
                    },
                    ..extended.background
                };
            }

            extended.primary = Primary {
                base: Pair {
                    color: accent.base.to_iced(),
                    text: accent.on.to_iced(),
                },
                weak: Pair {
                    color: accent.hover.to_iced(),
                    text: accent.on.to_iced(),
                },
                strong: Pair {
                    color: accent.pressed.to_iced(),
                    text: accent.on.to_iced(),
                },
            };

            extended.is_dark = is_dark;

            extended
        });

        Some(theme)
    }
}
