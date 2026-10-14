#![allow(unexpected_cfgs)]

use std::{
    env,
    ffi::{CStr, CString, c_char},
    io::{self, BufRead, Write},
    path::{Path, PathBuf},
    process::Command,
    ptr,
};

use objc::{class, msg_send, sel, sel_impl};
use objc::runtime::Object;

type Id = *mut Object;

#[link(name = "AppKit", kind = "framework")]
#[link(name = "Vision", kind = "framework")]
unsafe extern "C" {}

fn main() {
    if let Err(error) = run() {
        eprintln!("textsniper-rs: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut image = None;
    let mut server = false;
    for arg in env::args_os().skip(1) {
        if arg == "--help" || arg == "-h" {
            println!("Usage: textsniper-rs [--server] [IMAGE]\n\nSelect a screen region or OCR an image, then copy recognized text to the clipboard.\n\nWith --server, read one request per line from standard input and answer each with\na single line of \"OK <bytes>\" or \"ERROR <bytes>\" followed by that many bytes of\nUTF-8. A request is an image path, optionally prefixed with \"fast\\t\" for the quicker\nrecognition level. The process stays alive so the OCR models stay loaded.");
            return Ok(());
        } else if arg == "--server" {
            server = true;
        } else if image.replace(PathBuf::from(arg)).is_some() {
            return Err("pass one image path".into());
        }
    }

    if server {
        if image.is_some() {
            return Err("--server reads image paths from standard input, not arguments".into());
        }
        return serve();
    }

    let text = if let Some(path) = image.as_deref() {
        recognize(path, false)?
    } else {
        recognize_data(&capture_region()?, false)?
    };

    if text.trim().is_empty() {
        return Err("no text found".into());
    }
    print!("{text}");
    set_clipboard(&text)?;
    Ok(())
}

/// Keeps Vision loaded between requests. Each input line is an image path,
/// optionally prefixed with `fast\t` to use the quicker recognition level. Every
/// request answers with one length-prefixed frame, so a caller can stay
/// connected for the lifetime of the app instead of paying process start on
/// every capture.
fn serve() -> Result<(), String> {
    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line.map_err(|error| format!("could not read standard input: {error}"))?;
        let (level, path) = match line.split_once('\t') {
            Some((level, path)) => (level.trim(), path.trim()),
            None => ("accurate", line.trim()),
        };
        if path.is_empty() {
            continue;
        }
        let outcome = recognize(Path::new(path), level == "fast").and_then(|text| {
            if text.trim().is_empty() {
                return Err("no text found".into());
            }
            set_clipboard(&text)?;
            Ok(text)
        });
        match outcome {
            Ok(text) => write_frame(&mut stdout, "OK", &text),
            Err(message) => write_frame(&mut stdout, "ERROR", &message),
        }?;
    }
    Ok(())
}

fn write_frame(output: &mut impl Write, status: &str, payload: &str) -> Result<(), String> {
    write!(output, "{status} {}\n", payload.len())
        .and_then(|()| output.write_all(payload.as_bytes()))
        .and_then(|()| output.flush())
        .map_err(|error| format!("could not write result: {error}"))
}

fn capture_region() -> Result<Vec<u8>, String> {
    // macOS 26 can fail when interactive screencapture writes the selected rect to a file.
    let output = Command::new("/usr/sbin/screencapture")
        .args(["-i", "-c", "-x"])
        .output()
        .map_err(|error| format!("could not start screen capture: {error}"))?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        let detail = detail.trim();
        return if detail.contains("could not create image from") {
            Err(format!(
                "{detail}. macOS denied screen capture; allow the launching app (such as Terminal) in System Settings > Privacy & Security > Screen & System Audio Recording."
            ))
        } else {
            Err("screen capture was cancelled or failed".into())
        };
    }
    unsafe {
        let pool: Id = msg_send![class!(NSAutoreleasePool), new];
        let pasteboard: Id = msg_send![class!(NSPasteboard), generalPasteboard];
        let mut captured = None;
        for type_name in ["public.png", "public.tiff"] {
            let type_name = CString::new(type_name).unwrap();
            let pasteboard_type: Id = msg_send![class!(NSString), stringWithUTF8String: type_name.as_ptr()];
            let data: Id = msg_send![pasteboard, dataForType: pasteboard_type];
            if !data.is_null() {
                let length: usize = msg_send![data, length];
                let bytes: *const u8 = msg_send![data, bytes];
                if !bytes.is_null() && length > 0 {
                    captured = Some(std::slice::from_raw_parts(bytes, length).to_vec());
                    break;
                }
            }
        }
        let _: () = msg_send![pool, drain];
        captured.ok_or_else(|| "screen capture did not put an image on the clipboard".into())
    }
}

fn recognize(path: &Path, fast: bool) -> Result<String, String> {
    let image = std::fs::read(path).map_err(|error| format!("could not read image: {error}"))?;
    recognize_data(&image, fast)
}

fn recognize_data(image_data: &[u8], fast: bool) -> Result<String, String> {
    if image_data.is_empty() {
        return Err("image is empty".into());
    }
    let image_length = image_data.len();
    unsafe {
        let pool: Id = msg_send![class!(NSAutoreleasePool), new];
        let image: Id = msg_send![class!(NSData), dataWithBytes: image_data.as_ptr() length: image_length];
        let handler: Id = msg_send![class!(VNImageRequestHandler), alloc];
        let options: Id = msg_send![class!(NSDictionary), dictionary];
        let handler: Id = msg_send![handler, initWithData: image options: options];
        let request: Id = msg_send![class!(VNRecognizeTextRequest), new];
        let supports_language_detection: bool = msg_send![request, respondsToSelector: sel!(setAutomaticallyDetectsLanguage:)];
        if supports_language_detection {
            let _: () = msg_send![request, setAutomaticallyDetectsLanguage: true];
        }
        let _: () = msg_send![request, setUsesLanguageCorrection: true];
        if fast {
            // VNRequestTextRecognitionLevelFast is 1.
            let _: () = msg_send![request, setRecognitionLevel: 1_isize];
        }
        let requests: Id = msg_send![class!(NSArray), arrayWithObject: request];
        let mut error: Id = ptr::null_mut();
        let succeeded: bool = msg_send![handler, performRequests: requests error: &mut error];
        if !succeeded {
            let message = if error.is_null() {
                "Vision OCR failed".to_string()
            } else {
                object_string(msg_send![error, localizedDescription])
            };
            let _: () = msg_send![pool, drain];
            return Err(message);
        }

        let observations: Id = msg_send![request, results];
        let count: usize = msg_send![observations, count];
        let mut lines = Vec::with_capacity(count);
        for index in 0..count {
            let observation: Id = msg_send![observations, objectAtIndex: index];
            let candidates: Id = msg_send![observation, topCandidates: 1_usize];
            let candidate_count: usize = msg_send![candidates, count];
            if candidate_count == 0 {
                continue;
            }
            let candidate: Id = msg_send![candidates, objectAtIndex: 0_usize];
            let value: Id = msg_send![candidate, string];
            lines.push(object_string(value));
        }
        let _: () = msg_send![pool, drain];
        Ok(lines.join("\n"))
    }
}

unsafe fn object_string(value: Id) -> String {
    let value: *const c_char = unsafe { msg_send![value, UTF8String] };
    if value.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(value) }.to_string_lossy().into_owned()
}

fn set_clipboard(text: &str) -> Result<(), String> {
    let text = CString::new(text).map_err(|_| "recognized text contains a NUL byte")?;
    unsafe {
        let pool: Id = msg_send![class!(NSAutoreleasePool), new];
        let value: Id = msg_send![class!(NSString), stringWithUTF8String: text.as_ptr()];
        let pasteboard: Id = msg_send![class!(NSPasteboard), generalPasteboard];
        let _: isize = msg_send![pasteboard, clearContents];
        let objects: Id = msg_send![class!(NSArray), arrayWithObject: value];
        let written: bool = msg_send![pasteboard, writeObjects: objects];
        let _: () = msg_send![pool, drain];
        if !written {
            return Err("could not write text to clipboard".into());
        }
    }
    Ok(())
}

