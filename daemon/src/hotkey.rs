//! Double-Shift detection straight from evdev.
//!
//! Hyprland binds can't express "tap Shift twice", so we read keyboards from
//! /dev/input (granted by dist/70-snippets-keyboard.rules). Only key timing is
//! inspected; nothing is logged or stored.

use evdev::{Device, EventType, KeyCode};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime};

/// Longest a single Shift press may be held and still count as a tap.
const TAP_MAX: Duration = Duration::from_millis(300);
/// Longest gap between the first tap's release and the second tap's press.
const GAP_MAX: Duration = Duration::from_millis(400);
const RESCAN_EVERY: Duration = Duration::from_secs(3);

struct KeyEvent {
    at: SystemTime,
    code: u16,
    value: i32,
}

fn is_shift(code: u16) -> bool {
    code == KeyCode::KEY_LEFTSHIFT.code() || code == KeyCode::KEY_RIGHTSHIFT.code()
}

fn is_keyboard(device: &Device) -> bool {
    device.supported_keys().is_some_and(|keys| {
        keys.contains(KeyCode::KEY_A)
            && (keys.contains(KeyCode::KEY_LEFTSHIFT) || keys.contains(KeyCode::KEY_RIGHTSHIFT))
    })
}

/// Tap state machine. Fires on the release of the second tap, and only when
/// no other key was pressed in between.
#[derive(Default)]
struct Detector {
    shift_down_at: Option<SystemTime>,
    dirty: bool,
    last_tap_release: Option<SystemTime>,
}

impl Detector {
    fn feed(&mut self, ev: &KeyEvent) -> bool {
        let elapsed = |from: SystemTime| ev.at.duration_since(from).unwrap_or_default();

        if !is_shift(ev.code) {
            if ev.value == 1 {
                self.dirty = true;
                self.last_tap_release = None;
            }
            return false;
        }

        match ev.value {
            1 => {
                // Second press must follow the first release quickly.
                if self.last_tap_release.is_some_and(|t| elapsed(t) > GAP_MAX) {
                    self.last_tap_release = None;
                }
                self.shift_down_at = Some(ev.at);
                self.dirty = false;
                false
            }
            0 => {
                let was_tap = self.shift_down_at.take().is_some_and(|d| elapsed(d) <= TAP_MAX) && !self.dirty;
                if !was_tap {
                    self.reset();
                    return false;
                }
                if self.last_tap_release.is_some() {
                    self.reset();
                    return true;
                }
                self.last_tap_release = Some(ev.at);
                false
            }
            _ => false, // autorepeat
        }
    }

    fn reset(&mut self) {
        *self = Detector::default();
    }
}

fn watch_device(path: PathBuf, mut device: Device, tx: Sender<KeyEvent>, open: Arc<Mutex<HashSet<PathBuf>>>) {
    thread::spawn(move || {
        loop {
            let events = match device.fetch_events() {
                Ok(events) => events,
                Err(_) => break, // unplugged
            };
            for ev in events {
                if ev.event_type() == EventType::KEY {
                    let _ = tx.send(KeyEvent { at: ev.timestamp(), code: ev.code(), value: ev.value() });
                }
            }
        }
        open.lock().unwrap().remove(&path);
    });
}

fn scan(tx: &Sender<KeyEvent>, open: &Arc<Mutex<HashSet<PathBuf>>>, warned: &mut bool) {
    let mut found_any = false;
    for (path, device) in evdev::enumerate() {
        if !is_keyboard(&device) {
            continue;
        }
        found_any = true;
        if !open.lock().unwrap().insert(path.clone()) {
            continue;
        }
        eprintln!("snip: watching {} ({})", path.display(), device.name().unwrap_or("?"));
        watch_device(path, device, tx.clone(), open.clone());
    }
    if !found_any && !*warned {
        eprintln!(
            "snip: no readable keyboards in /dev/input; install dist/70-snippets-keyboard.rules \
             (see README). Will keep retrying."
        );
        *warned = true;
    }
}

/// Blocks forever, calling `on_trigger` on every double Shift.
pub fn run(on_trigger: impl Fn() + Send + Sync + 'static) -> ! {
    let (tx, rx) = mpsc::channel::<KeyEvent>();
    let open = Arc::new(Mutex::new(HashSet::new()));

    {
        let open = open.clone();
        thread::spawn(move || {
            let mut warned = false;
            loop {
                scan(&tx, &open, &mut warned);
                thread::sleep(RESCAN_EVERY);
            }
        });
    }

    let on_trigger = Arc::new(on_trigger);
    let mut detector = Detector::default();
    for ev in rx {
        if detector.feed(&ev) {
            let f = on_trigger.clone();
            thread::spawn(move || f());
        }
    }
    unreachable!("event channel closed")
}

#[cfg(test)]
mod tests {
    use super::*;

    const LSHIFT: u16 = 42;
    const KEY_A: u16 = 30;

    fn ev(ms: u64, code: u16, value: i32) -> KeyEvent {
        KeyEvent { at: SystemTime::UNIX_EPOCH + Duration::from_millis(ms), code, value }
    }

    fn run_seq(seq: &[(u64, u16, i32)]) -> usize {
        let mut d = Detector::default();
        seq.iter().filter(|&&(t, c, v)| d.feed(&ev(t, c, v))).count()
    }

    #[test]
    fn double_tap_fires() {
        assert_eq!(run_seq(&[(0, LSHIFT, 1), (80, LSHIFT, 0), (200, LSHIFT, 1), (280, LSHIFT, 0)]), 1);
    }

    #[test]
    fn slow_gap_does_not_fire() {
        assert_eq!(run_seq(&[(0, LSHIFT, 1), (80, LSHIFT, 0), (900, LSHIFT, 1), (980, LSHIFT, 0)]), 0);
    }

    #[test]
    fn held_shift_does_not_fire() {
        assert_eq!(run_seq(&[(0, LSHIFT, 1), (800, LSHIFT, 0), (900, LSHIFT, 1), (980, LSHIFT, 0)]), 0);
    }

    #[test]
    fn typing_capitals_does_not_fire() {
        // Shift+A, then Shift+A again quickly.
        assert_eq!(
            run_seq(&[
                (0, LSHIFT, 1), (40, KEY_A, 1), (60, KEY_A, 0), (90, LSHIFT, 0),
                (150, LSHIFT, 1), (180, KEY_A, 1), (200, KEY_A, 0), (230, LSHIFT, 0),
            ]),
            0
        );
    }

    #[test]
    fn triple_tap_fires_once() {
        assert_eq!(
            run_seq(&[
                (0, LSHIFT, 1), (50, LSHIFT, 0), (150, LSHIFT, 1), (200, LSHIFT, 0),
                (300, LSHIFT, 1), (350, LSHIFT, 0),
            ]),
            1
        );
    }
}
