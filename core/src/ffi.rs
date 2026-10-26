//! The C API the tweak links against (`include/flowneuro.h`). Strings in are UTF-8 C strings;
//! strings out are UTF-8 JSON the caller frees with `fn_free`. One engine per process, behind a
//! lock, so any thread may call. Every call catches panics: a bug here must never take YouTube
//! down with it, so a failed call returns NULL/false/0 instead.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::Mutex;

use crate::engine::{Answer, Engine, ProgressReport};
use crate::flow_neuro::language::SYSTEM_LANGUAGE;
use crate::models::video::VideoSummary;

static ENGINE: Mutex<Option<Engine>> = Mutex::new(None);

fn text(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller passes a valid NUL-terminated string that outlives this call.
    unsafe { CStr::from_ptr(ptr) }.to_str().ok().map(ToOwned::to_owned)
}

fn out(json: String) -> *mut c_char {
    CString::new(json).map_or(std::ptr::null_mut(), CString::into_raw)
}

fn with_engine<R>(fallback: R, f: impl FnOnce(&mut Engine) -> R) -> R {
    catch_unwind(AssertUnwindSafe(|| {
        let mut guard = match ENGINE.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        guard.as_mut().map(f)
    }))
    .ok()
    .flatten()
    .unwrap_or(fallback)
}

fn json_out<T: serde::Serialize>(value: &T) -> *mut c_char {
    serde_json::to_string(value).map_or(std::ptr::null_mut(), out)
}

/// Opens (or creates) the engine saved in `dir`. `language` is the device language ("en",
/// "pt-BR"), `region` the two-letter region InnerTube results are for.
#[unsafe(no_mangle)]
pub extern "C" fn fn_open(dir: *const c_char, language: *const c_char, region: *const c_char) -> bool {
    let (Some(dir), language, region) = (text(dir), text(language), text(region)) else {
        return false;
    };
    catch_unwind(|| {
        let _ = SYSTEM_LANGUAGE.set(language.unwrap_or_else(|| "en".into()));
        let engine = Engine::open(Path::new(&dir), region.as_deref().unwrap_or("US"));
        let mut guard = match ENGINE.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        *guard = Some(engine);
        true
    })
    .unwrap_or(false)
}

/// Saves if anything changed. Call when the app goes to the background and every so often.
#[unsafe(no_mangle)]
pub extern "C" fn fn_save() -> bool {
    with_engine(false, |e| e.save().is_ok())
}

/// The requests one Home load needs: `{"loadId":1,"requests":[{"id","url","body","headers"}]}`.
#[unsafe(no_mangle)]
pub extern "C" fn fn_plan_home(more: bool) -> *mut c_char {
    with_engine(std::ptr::null_mut(), |e| json_out(&e.plan_home(more)))
}

/// The page built from a plan's answers, `answers` being `[{"id","status","body"}]`.
/// Returns `{"items":[...],"offline":bool,"coldStart":bool}`.
#[unsafe(no_mangle)]
pub extern "C" fn fn_assemble(load_id: u64, answers: *const c_char) -> *mut c_char {
    let answers: Vec<Answer> = text(answers)
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();
    with_engine(std::ptr::null_mut(), |e| json_out(&e.assemble(load_id, answers)))
}

/// The Subscriptions page: same protocol as `fn_plan_home`, answered with `fn_assemble`.
#[unsafe(no_mangle)]
pub extern "C" fn fn_plan_subscriptions() -> *mut c_char {
    with_engine(std::ptr::null_mut(), |e| json_out(&e.plan_subscriptions()))
}

/// A local list: "subscriptions", "likes" or "history".
#[unsafe(no_mangle)]
pub extern "C" fn fn_library(kind: *const c_char) -> *mut c_char {
    let Some(kind) = text(kind) else {
        return std::ptr::null_mut();
    };
    with_engine(std::ptr::null_mut(), |e| json_out(&e.library_list(&kind)))
}

#[unsafe(no_mangle)]
pub extern "C" fn fn_is_subscribed(channel_id: *const c_char) -> bool {
    let Some(channel_id) = text(channel_id) else {
        return false;
    };
    with_engine(false, |e| e.is_subscribed(&channel_id))
}

/// The watch-page request to send when a video starts playing.
#[unsafe(no_mangle)]
pub extern "C" fn fn_watch_page_request(video_id: *const c_char) -> *mut c_char {
    let Some(video_id) = text(video_id) else {
        return std::ptr::null_mut();
    };
    with_engine(std::ptr::null_mut(), |e| json_out(&e.watch_page_request(&video_id)))
}

/// The watch page's answer for a playing video.
#[unsafe(no_mangle)]
pub extern "C" fn fn_watch_page(video_id: *const c_char, body: *const c_char) {
    if let (Some(video_id), Some(body)) = (text(video_id), text(body)) {
        with_engine((), |e| e.watch_page(&video_id, &body));
    }
}

/// A player report: `{"videoId","position","duration","playedDelta","title"?,"channelName"?,
/// "channelId"?,"isLive"?}`.
#[unsafe(no_mangle)]
pub extern "C" fn fn_watch_progress(report: *const c_char) {
    if let Some(report) = text(report).and_then(|t| serde_json::from_str::<ProgressReport>(&t).ok()) {
        with_engine((), |e| e.watch_progress(report));
    }
}

/// The player closed or the app left the foreground: the open viewing is final.
#[unsafe(no_mangle)]
pub extern "C" fn fn_watch_end() {
    with_engine((), Engine::watch_end);
}

/// `action`: like, unlike, dislike, notInterested, save, dismiss. `video` (nullable) is the card
/// JSON when the host has it.
#[unsafe(no_mangle)]
pub extern "C" fn fn_feedback(video_id: *const c_char, action: *const c_char, video: *const c_char) -> bool {
    let (Some(video_id), Some(action)) = (text(video_id), text(action)) else {
        return false;
    };
    let video: Option<VideoSummary> = text(video).and_then(|t| serde_json::from_str(&t).ok());
    with_engine(false, |e| e.feedback(&video_id, &action, video))
}

#[unsafe(no_mangle)]
pub extern "C" fn fn_subscription(channel_id: *const c_char, name: *const c_char, subscribed: bool) {
    if let Some(channel_id) = text(channel_id) {
        let name = text(name).unwrap_or_default();
        with_engine((), |e| e.subscription(&channel_id, &name, None, subscribed));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fn_searched(query: *const c_char) {
    if let Some(query) = text(query) {
        with_engine((), |e| {
            e.searched(&query);
        });
    }
}

/// Imports a file's contents. `kind`: "subscriptions-csv" (Takeout), "subscriptions-json"
/// (NewPipe/Flow), "history-json" (Takeout). Returns how many entries were taken, or -1.
#[unsafe(no_mangle)]
pub extern "C" fn fn_import(kind: *const c_char, data: *const c_char) -> i64 {
    let (Some(kind), Some(data)) = (text(kind), text(data)) else {
        return -1;
    };
    with_engine(-1, |e| {
        let count = match kind.as_str() {
            "subscriptions-csv" => e.import_subscriptions(crate::import::takeout_subscriptions(&data)),
            "subscriptions-json" => e.import_subscriptions(crate::import::newpipe_subscriptions(&data)),
            "history-json" => e.import_history(crate::import::takeout_history(&data)),
            _ => return -1,
        };
        i64::try_from(count).unwrap_or(i64::MAX)
    })
}

/// Interests picked by hand, as a JSON array of strings.
#[unsafe(no_mangle)]
pub extern "C" fn fn_choose_topics(topics: *const c_char) {
    if let Some(topics) = text(topics).and_then(|t| serde_json::from_str::<Vec<String>>(&t).ok()) {
        with_engine((), |e| e.choose_topics(&topics));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fn_block_topic(topic: *const c_char) {
    if let Some(topic) = text(topic) {
        with_engine((), |e| e.block_topic(&topic));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fn_block_channel(channel_id: *const c_char) {
    if let Some(channel_id) = text(channel_id) {
        with_engine((), |e| e.block_channel(&channel_id));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fn_set_learning_paused(paused: bool) {
    with_engine((), |e| e.set_learning_paused(paused));
}

/// `{"totalInteractions","persona","topTopics":[...],"watchedVideos","likedVideos",
/// "subscriptions","learningPaused"}`.
#[unsafe(no_mangle)]
pub extern "C" fn fn_stats() -> *mut c_char {
    with_engine(std::ptr::null_mut(), |e| json_out(&e.stats()))
}

/// Forgets everything and saves the empty state.
#[unsafe(no_mangle)]
pub extern "C" fn fn_reset() {
    with_engine((), |e| {
        e.reset();
        let _ = e.save();
    });
}

/// Flow's onboarding catalog: `[{"name":"Gaming","topics":["Gaming","Minecraft",...]},...]`.
#[unsafe(no_mangle)]
pub extern "C" fn fn_topic_catalog() -> *mut c_char {
    let catalog: Vec<serde_json::Value> = crate::flow_neuro::topic_catalog::TOPIC_CATEGORIES
        .iter()
        .map(|c| serde_json::json!({ "name": c.name, "topics": c.topics }))
        .collect();
    json_out(&catalog)
}

/// Frees a string this library returned.
#[unsafe(no_mangle)]
pub extern "C" fn fn_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: `ptr` came from `CString::into_raw` in this library and is freed once.
        drop(unsafe { CString::from_raw(ptr) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    fn take(ptr: *mut c_char) -> serde_json::Value {
        assert!(!ptr.is_null());
        // SAFETY: returned by this library.
        let text = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned();
        fn_free(ptr);
        serde_json::from_str(&text).unwrap()
    }

    #[test]
    fn the_c_api_runs_a_load_and_survives_bad_input() {
        let dir = std::env::temp_dir().join(format!("flowtube-ffi-{}", crate::engine::now_ms()));
        std::fs::create_dir_all(&dir).unwrap();
        let (d, l, r) = (c(dir.to_str().unwrap()), c("en"), c("US"));
        assert!(fn_open(d.as_ptr(), l.as_ptr(), r.as_ptr()));
        let plan = take(fn_plan_home(false));
        let id = plan["loadId"].as_u64().unwrap();
        assert!(!plan["requests"].as_array().unwrap().is_empty());
        // Garbage answers and garbage reports do no harm.
        let page = take(fn_assemble(id, c("not json").as_ptr()));
        assert_eq!(page["items"].as_array().unwrap().len(), 0);
        fn_watch_progress(c("{broken").as_ptr());
        fn_watch_progress(std::ptr::null());
        fn_watch_page(c("x").as_ptr(), c("[]").as_ptr());
        assert!(!fn_feedback(std::ptr::null(), c("like").as_ptr(), std::ptr::null()));
        assert_eq!(fn_import(c("nope").as_ptr(), c("").as_ptr()), -1);
        let stats = take(fn_stats());
        assert_eq!(stats["totalInteractions"], 0);
        assert!(fn_save());
        assert!(dir.join("flowneuro_state.json").exists());
    }
}
