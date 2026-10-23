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
#[link(name = "CoreFoundation", kind = "framework")]
#[link(name = "ImageIO", kind = "framework")]
#[link(name = "Vision", kind = "framework")]
unsafe extern "C" {}

type CFTypeRef = *mut std::ffi::c_void;

/// Engine failure that a fresh helper may recover from.
const RECOGNIZER_FAILED: &str = "The macOS text recognizer stopped working.";

unsafe extern "C" {
    fn CGImageSourceCreateWithData(data: CFTypeRef, options: CFTypeRef) -> CFTypeRef;
    fn CGImageSourceGetCount(source: CFTypeRef) -> isize;
    fn CGImageSourceCopyPropertiesAtIndex(source: CFTypeRef, index: isize, options: CFTypeRef) -> CFTypeRef;
    fn CGImageSourceCreateImageAtIndex(source: CFTypeRef, index: isize, options: CFTypeRef) -> CFTypeRef;
    fn CFRelease(value: CFTypeRef);
}

fn main() {
    if let Err(error) = run() {
        eprintln!("textsniper-rs: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut image = None;
    let mut server = false;
    let mut warmup = false;
    for arg in env::args_os().skip(1) {
        if arg == "--help" || arg == "-h" {
            println!("Usage: textsniper-rs [--server] [--warmup] [IMAGE]\n\nSelect a screen region or OCR an image, then copy recognized text to the clipboard.\n\nWith --server, read one request per line from standard input and answer each with\na single line of \"OK <bytes>\", \"HELPER_ERROR <bytes>\" or \"ERROR <bytes>\" followed by that\nmany bytes of UTF-8. A request is an image path, optionally prefixed with \"fast\\t\" for\nthe quicker recognition level. The process stays alive so the OCR models stay loaded.\n\nWith --warmup, load the recognition models for an image and exit. Nothing is printed\nor copied, and the exit code says whether the accurate recognizer works.");
            return Ok(());
        } else if arg == "--server" {
            server = true;
        } else if arg == "--warmup" {
            warmup = true;
        } else if image.replace(PathBuf::from(arg)).is_some() {
            return Err("pass one image path".into());
        }
    }

    if warmup {
        let path = image.ok_or("--warmup needs an image path")?;
        // Loads the models and reports whether the accurate recognizer works
        // on this Mac. Nothing is printed and the clipboard is left alone.
        let _ = recognize(path.as_path(), false)?;
        return Ok(());
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
    // A long-lived Vision session can end up failing every read while the
    // process itself looks healthy. Answering the same failure forever left the
    // app unable to recognize anything, so a run of failures ends the process
    // and the app starts a fresh helper for the next request.
    const MAX_CONSECUTIVE_ERRORS: u32 = 4;
    let mut consecutive_errors = 0;
    for line in stdin.lock().lines() {
        let line = line.map_err(|error| format!("could not read standard input: {error}"))?;
        let (level, path) = match line.split_once('\t') {
            Some((level, path)) => (level.trim(), path.trim()),
            None => ("accurate", line.trim()),
        };
        if path.is_empty() {
            continue;
        }
        let text = recognize(Path::new(path), level == "fast");
        let outcome = text.and_then(|text| {
            if text.trim().is_empty() {
                return Err("no text found".into());
            }
            set_clipboard(&text)?;
            Ok(text)
        });
        // An image with nothing on it is an answer, not a fault.
        let failed = !matches!(outcome, Ok(_)) && !matches!(&outcome, Err(message) if message == "no text found");
        consecutive_errors = if failed { consecutive_errors + 1 } else { 0 };
        let retiring = consecutive_errors >= MAX_CONSECUTIVE_ERRORS;
        write_response(&mut stdout, outcome)?;
        if retiring {
            break;
        }
    }
    Ok(())
}

fn write_response(output: &mut impl Write, outcome: Result<String, String>) -> Result<(), String> {
    match outcome {
        Ok(text) => write_frame(output, "OK", &text),
        Err(message) => {
            let status = if message == RECOGNIZER_FAILED { "HELPER_ERROR" } else { "ERROR" };
            write_frame(output, status, &message)
        }
    }
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
    unsafe {
        let pool: Id = msg_send![class!(NSAutoreleasePool), new];
        // The size check reads the header through a temporary NSData, so it has
        // to run inside the pool. Before it, that object has nowhere to go and
        // leaks a copy of the image on every capture.
        let (width, height, orientation, picture) = match decode_image(image_data) {
            Ok(decoded) => decoded,
            Err(error) => {
                let _: () = msg_send![pool, drain];
                return Err(error);
            }
        };
        if width < 2 || height < 2 {
            CFRelease(picture);
            let _: () = msg_send![pool, drain];
            return Err(format!(
                "That selection is {width} by {height} pixels. Select a larger area."
            ));
        }
        // Vision reads a decoded picture. Decoding it here hands Vision the
        // image and its orientation directly, and keeps the raw bytes out of
        // the request.
        let handler: Id = msg_send![class!(VNImageRequestHandler), alloc];
        let options: Id = msg_send![class!(NSDictionary), dictionary];
        let handler: Id = msg_send![handler, initWithCGImage: picture as Id
                                                  orientation: orientation
                                                    options: options];
        // `alloc`/`init` and `new` both return +1 ownership that the autorelease
        // pool does not adopt. This process serves every capture for the whole
        // app session, so leaving these alive grows memory without bound until
        // the image reader starts failing.
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
        // Tell Vision which languages this level can read. On its own the
        // automatic detection settles on one language for the whole selection,
        // so a screen that mixes Chinese and English loses the Chinese half.
        set_supported_languages(request);
        let requests: Id = msg_send![class!(NSArray), arrayWithObject: request];
        let mut error: Id = ptr::null_mut();
        let succeeded: bool = msg_send![handler, performRequests: requests error: &mut error];
        if !succeeded {
            let message = if error.is_null() {
                String::new()
            } else {
                object_string(msg_send![error, localizedDescription])
            };
            release(request);
            release(handler);
            CFRelease(picture);
            let _: () = msg_send![pool, drain];
            return Err(friendly_error(&message));
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
        release(request);
        release(handler);
        CFRelease(picture);
        let _: () = msg_send![pool, drain];
        let text = lines.join("\n");
        if fast && text.trim().is_empty() {
            // The quick recognizer has no model for Chinese, Japanese or
            // Korean, so it finds nothing at all in a selection written in
            // those scripts. The accurate recognizer reads them, so try that
            // before reporting that the selection holds no text.
            return recognize_data(image_data, false);
        }
        Ok(text)
    }
}

/// The languages a request asks for: the Chinese, Japanese and Korean models
/// first, then the rest, up to seven.
///
/// Vision reads a selection that mixes scripts with the first language in the
/// list that fits, so a screen that shows Chinese next to English keeps both
/// halves. The automatic detection still picks the language of a selection
/// written in one script, so the languages after the CJK ones are only there
/// to win a line that mixes two scripts.
///
/// The list stops at seven. Every language in it needs its own correction
/// model, and building those is what makes a read slow: asking for all
/// thirty-three languages macOS knows took 46 seconds to build them, while
/// seven takes a few seconds and reads every script the same.
fn ordered_languages(supported: &[String]) -> Vec<String> {
    const FIRST: [&str; 6] = ["zh-Hans", "zh-Hant", "yue-Hans", "yue-Hant", "ja-JP", "ko-KR"];
    const LIMIT: usize = 7;
    let mut ordered: Vec<String> = Vec::new();
    for wanted in FIRST {
        if ordered.len() == LIMIT {
            break;
        }
        if let Some(found) = supported.iter().find(|language| *language == wanted) {
            ordered.push(found.clone());
        }
    }
    for language in supported {
        if ordered.len() == LIMIT {
            break;
        }
        if FIRST.contains(&language.as_str()) {
            continue;
        }
        ordered.push(language.clone());
    }
    ordered
}

/// Gives the request the languages its own recognition level supports.
fn set_supported_languages(request: Id) {
    unsafe {
        let supported: bool = msg_send![
            request,
            respondsToSelector: sel!(supportedRecognitionLanguagesAndReturnError:)
        ];
        if !supported {
            return;
        }
        let mut error: Id = ptr::null_mut();
        let languages: Id = msg_send![request, supportedRecognitionLanguagesAndReturnError: &mut error];
        if languages.is_null() {
            return;
        }
        let count: usize = msg_send![languages, count];
        let mut available: Vec<String> = Vec::with_capacity(count);
        for index in 0..count {
            let language: Id = msg_send![languages, objectAtIndex: index];
            available.push(object_string(language));
        }
        let ordered: Id = msg_send![class!(NSMutableArray), array];
        for language in ordered_languages(&available) {
            let bytes = CString::new(language).unwrap_or_default();
            let value: Id = msg_send![class!(NSString), stringWithUTF8String: bytes.as_ptr()];
            let _: () = msg_send![ordered, addObject: value];
        }
        let _: () = msg_send![request, setRecognitionLanguages: ordered];
    }
}

unsafe fn release(object: Id) {
    let _: () = msg_send![object, release];
}

/// Decodes the picture once. The pixel size comes from the header alone, so a
/// thin selection is reported as such instead of reaching the image reader,
/// and the decoded image is what Vision reads.
fn decode_image(image_data: &[u8]) -> Result<(usize, usize, u32, CFTypeRef), String> {
    unsafe {
        let data: Id = msg_send![class!(NSData), dataWithBytes: image_data.as_ptr() length: image_data.len()];
        let source = CGImageSourceCreateWithData(data as CFTypeRef, ptr::null_mut());
        if source.is_null() {
            return Err("TextS could not read that selection. Select it again.".into());
        }
        let count = CGImageSourceGetCount(source);
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, ptr::null_mut());
        let dimension = |key: &str| -> Option<usize> {
            if properties.is_null() {
                return None;
            }
            let key = CString::new(key).unwrap();
            let key: Id = msg_send![class!(NSString), stringWithUTF8String: key.as_ptr()];
            let number: Id = msg_send![properties as Id, objectForKey: key];
            if number.is_null() {
                return None;
            }
            let value: usize = msg_send![number, unsignedIntegerValue];
            Some(value)
        };
        let size = (dimension("PixelWidth"), dimension("PixelHeight"));
        // Vision reads a decoded image, so the orientation the file carries
        // has to be handed over with it. A screenshot has none and reads
        // upright.
        let orientation = dimension("Orientation").unwrap_or(1) as u32;
        if !properties.is_null() {
            CFRelease(properties as CFTypeRef);
        }
        let (width, height) = match size {
            (Some(width), Some(height)) if count > 0 && width > 0 && height > 0 => (width, height),
            _ => {
                CFRelease(source);
                return Err("TextS could not read that selection. Select it again.".into());
            }
        };
        let picture = CGImageSourceCreateImageAtIndex(source, 0, ptr::null_mut());
        CFRelease(source);
        if picture.is_null() {
            return Err("TextS could not read that selection. Select it again.".into());
        }
        Ok((width, height, orientation, picture))
    }
}

/// Vision's own error strings name the framework and leave the user with
/// nothing to act on, so replace them with guidance.
fn friendly_error(message: &str) -> String {
    let lowered = message.to_lowercase();
    if lowered.contains("too small") || lowered.contains("zero-dimensioned") {
        return "That selection is too small to read. Select a larger area.".into();
    }
    RECOGNIZER_FAILED.into()
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

#[cfg(test)]
mod tests {
    use super::{RECOGNIZER_FAILED, ordered_languages, recognize_data, write_response};

    /// The languages macOS lists for the accurate level on this machine.
    const ACCURATE: [&str; 33] = [
        "en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR", "zh-Hans", "zh-Hant", "yue-Hans",
        "yue-Hant", "ko-KR", "ja-JP", "ru-RU", "uk-UA", "th-TH", "vi-VT", "ar-SA", "ars-SA",
        "tr-TR", "id-ID", "cs-CZ", "da-DK", "nl-NL", "no-NO", "nn-NO", "nb-NO", "ms-MY", "pl-PL",
        "ro-RO", "sv-SE", "fi-FI", "hi-IN", "mr-IN",
    ];

    /// The Chinese, Japanese and Korean models come first, so a line that
    /// mixes scripts keeps its Chinese half, and the list stays short, so the
    /// first read does not build a correction model for every language macOS
    /// knows.
    #[test]
    fn language_list_is_cjk_first_and_short() {
        let supported: Vec<String> = ACCURATE.iter().map(|language| language.to_string()).collect();
        let ordered = ordered_languages(&supported);
        assert_eq!(ordered.len(), 7, "asked for {ordered:?}");
        assert_eq!(
            ordered,
            ["zh-Hans", "zh-Hant", "yue-Hans", "yue-Hant", "ja-JP", "ko-KR", "en-US"]
        );
    }

    /// The quick level only has six languages and no CJK model, and the limit
    /// must not cut them out.
    #[test]
    fn language_list_keeps_every_language_a_level_offers() {
        let supported: Vec<String> = ["en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR"]
            .iter()
            .map(|language| language.to_string())
            .collect();
        assert_eq!(ordered_languages(&supported), supported);
    }

    #[test]
    fn server_distinguishes_engine_failure_from_rejected_images() {
        for (outcome, expected) in [
            (Err(RECOGNIZER_FAILED.into()), format!("HELPER_ERROR {}\n{RECOGNIZER_FAILED}", RECOGNIZER_FAILED.len())),
            (Err("no text found".into()), "ERROR 13\nno text found".into()),
            (recognize_data(b"invalid image", false), "ERROR 53\nTextS could not read that selection. Select it again.".into()),
            (Ok("你好".into()), "OK 6\n你好".into()),
        ] {
            let mut bytes = Vec::new();
            write_response(&mut bytes, outcome).unwrap();
            assert_eq!(String::from_utf8(bytes).unwrap(), expected);
        }
    }
}
