use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "athena", about = "Graphical EDA IDE for Aegis FPGAs")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Create a new Athena project
    New {
        /// Project directory path
        path: PathBuf,
        /// Target device name
        #[arg(short, long)]
        device: String,
        /// Top module name
        #[arg(short, long, default_value = "top")]
        top_module: String,
    },
    /// Open an existing project (path to directory or athena.toml)
    Open {
        /// Path to project directory or athena.toml file
        path: PathBuf,
    },
    /// Build the current project
    Build {
        /// Project directory path (defaults to current directory)
        #[arg(default_value = ".")]
        path: PathBuf,
    },
}

fn main() -> iced::Result {
    let cli = Cli::parse();

    match cli.command {
        Some(Command::Open { path }) => {
            // If passed athena.toml directly, use its parent directory
            let project_dir =
                if path.is_file() && path.file_name().is_some_and(|f| f == "athena.toml") {
                    path.parent().unwrap_or(&path).to_path_buf()
                } else {
                    path
                };
            athena::run_with_project(project_dir)
        }
        Some(Command::New {
            path,
            device,
            top_module,
        }) => athena::run_new_project(path, device, top_module),
        Some(Command::Build { path }) => {
            athena::build(path);
            Ok(())
        }
        None => athena::run(),
    }
}
