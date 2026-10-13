mod hotkey;
mod store;

use serde::Deserialize;
use std::io::{self, BufRead};
use std::process::{Command, ExitCode};

const USAGE: &str = "\
snip — save the selected text as Markdown items

usage:
  snip daemon         listen for double Shift and capture the selection
  snip capture        capture the current selection once
  snip list           print all items as JSON (newest first)
  snip save           create/update from one JSON line on stdin: {\"id\",\"title\",\"body\"}
  snip delete <id>    delete an item
  snip dir            print the storage directory

env: SNIPPETS_DIR overrides the storage directory (default ~/Documents/snippets)";

#[derive(Deserialize)]
struct SaveRequest {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    title: String,
    #[serde(default)]
    body: String,
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("daemon") => hotkey::run(|| {
            if let Err(e) = capture() {
                eprintln!("snip: capture failed: {e}");
            }
        }),
        Some("capture") => capture(),
        Some("list") => list(),
        Some("save") => save(),
        Some("delete") => match args.get(1) {
            Some(id) => store::delete(id),
            None => Err(io::Error::new(io::ErrorKind::InvalidInput, "delete needs an id")),
        },
        Some("dir") => {
            println!("{}", store::dir().display());
            Ok(())
        }
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("snip: {e}");
            ExitCode::FAILURE
        }
    }
}

fn list() -> io::Result<()> {
    let items = store::list()?;
    println!("{}", serde_json::to_string(&items)?);
    Ok(())
}

fn save() -> io::Result<()> {
    let mut line = String::new();
    io::stdin().lock().read_line(&mut line)?;
    let req: SaveRequest = serde_json::from_str(&line)?;
    let id = store::save(req.id.as_deref(), &req.title, &req.body)?;
    println!("{}", serde_json::json!({ "id": id }));
    Ok(())
}

/// Read the Wayland primary selection (whatever is highlighted) without
/// touching the clipboard.
fn capture() -> io::Result<()> {
    let out = Command::new("wl-paste")
        .args(["--primary", "--no-newline", "--type", "text"])
        .output()?;
    let text = String::from_utf8_lossy(&out.stdout).into_owned();

    if !out.status.success() || text.trim().is_empty() {
        notify("Nothing selected", "Highlight some text, then tap Shift twice.");
        return Ok(());
    }

    if store::list()?.first().is_some_and(|newest| newest.body == text) {
        notify("Already saved", &preview(&text));
        return Ok(());
    }

    store::save(None, "", &text)?;
    notify("Snippet saved", &preview(&text));
    Ok(())
}

fn preview(text: &str) -> String {
    let flat: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    match flat.char_indices().nth(120) {
        Some((i, _)) => format!("{}…", &flat[..i]),
        None => flat,
    }
}

fn notify(summary: &str, body: &str) {
    let _ = Command::new("notify-send")
        .args(["--app-name=Snippets", "--icon=edit-paste", "--expire-time=2500", summary, body])
        .spawn()
        .and_then(|mut c| c.wait());
}
