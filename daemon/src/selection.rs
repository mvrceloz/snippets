//! Reading the highlighted text. Native Wayland apps put it in the Wayland
//! primary selection; XWayland apps (e.g. VS Code with
//! `--ozone-platform=x11`) put it in the X11 PRIMARY, which Hyprland doesn't
//! reliably mirror. We read the one belonging to the focused window.

use std::env;
use std::error::Error;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    AtomEnum, ConnectionExt, CreateWindowAux, EventMask, Property, WindowClass,
};
use x11rb::protocol::Event;

const X11_TIMEOUT: Duration = Duration::from_millis(1000);

/// Returns the selected text (possibly empty) and where it came from.
pub fn read() -> (String, &'static str) {
    match focused_is_xwayland() {
        Some(true) => (x11(), "x11"),
        Some(false) => (wayland(), "wayland"),
        // Not on Hyprland: prefer Wayland, fall back to X11.
        None => match wayland() {
            text if !text.trim().is_empty() => (text, "wayland"),
            _ => (x11(), "x11"),
        },
    }
}

fn wayland() -> String {
    match Command::new("wl-paste")
        .args(["--primary", "--no-newline", "--type", "text"])
        .output()
    {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).into_owned(),
        _ => String::new(),
    }
}

fn x11() -> String {
    x11_primary().unwrap_or_else(|e| {
        eprintln!("snip: reading X11 PRIMARY failed: {e}");
        String::new()
    })
}

/// Asks Hyprland whether the focused window is an XWayland client.
fn focused_is_xwayland() -> Option<bool> {
    let sig = env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    let runtime = env::var("XDG_RUNTIME_DIR").ok()?;
    let mut sock = UnixStream::connect(format!("{runtime}/hypr/{sig}/.socket.sock")).ok()?;
    sock.set_read_timeout(Some(Duration::from_millis(500))).ok()?;
    sock.write_all(b"j/activewindow").ok()?;
    let mut reply = String::new();
    sock.read_to_string(&mut reply).ok()?;
    serde_json::from_str::<serde_json::Value>(&reply).ok()?.get("xwayland")?.as_bool()
}

/// Converts PRIMARY to UTF8_STRING on a throwaway window, following the
/// INCR protocol for large selections.
fn x11_primary() -> Result<String, Box<dyn Error>> {
    let (conn, screen_num) = x11rb::connect(None)?;
    let root = conn.setup().roots[screen_num].root;
    let win = conn.generate_id()?;
    conn.create_window(
        x11rb::COPY_DEPTH_FROM_PARENT,
        win,
        root,
        0,
        0,
        1,
        1,
        0,
        WindowClass::INPUT_OUTPUT,
        x11rb::COPY_FROM_PARENT,
        &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE),
    )?;
    let utf8 = conn.intern_atom(false, b"UTF8_STRING")?.reply()?.atom;
    let incr = conn.intern_atom(false, b"INCR")?.reply()?.atom;
    let prop = conn.intern_atom(false, b"SNIP_SELECTION")?.reply()?.atom;
    conn.convert_selection(win, AtomEnum::PRIMARY.into(), utf8, prop, x11rb::CURRENT_TIME)?;
    conn.flush()?;

    let deadline = Instant::now() + X11_TIMEOUT;
    let next_event = || -> Result<Event, Box<dyn Error>> {
        loop {
            if let Some(event) = conn.poll_for_event()? {
                return Ok(event);
            }
            if Instant::now() > deadline {
                return Err("timed out waiting for the selection owner".into());
            }
            thread::sleep(Duration::from_millis(5));
        }
    };

    // Wait for the owner's answer; no owner means nothing is selected.
    loop {
        if let Event::SelectionNotify(e) = next_event()? {
            if e.property == x11rb::NONE {
                return Ok(String::new());
            }
            break;
        }
    }

    let reply = conn.get_property(true, win, prop, AtomEnum::ANY, 0, u32::MAX)?.reply()?;
    conn.flush()?;
    if reply.type_ != incr {
        return Ok(String::from_utf8_lossy(&reply.value).into_owned());
    }

    // INCR: the owner sends chunks, each announced by a new property value,
    // and an empty chunk ends the transfer.
    let mut data = Vec::new();
    loop {
        match next_event()? {
            Event::PropertyNotify(e) if e.atom == prop && e.state == Property::NEW_VALUE => {
                let chunk = conn.get_property(true, win, prop, AtomEnum::ANY, 0, u32::MAX)?.reply()?;
                conn.flush()?;
                if chunk.value.is_empty() {
                    return Ok(String::from_utf8_lossy(&data).into_owned());
                }
                data.extend_from_slice(&chunk.value);
            }
            _ => {}
        }
    }
}
