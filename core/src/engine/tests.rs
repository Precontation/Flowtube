use super::*;
use serde_json::json;

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("flowtube-test-{name}-{}", now_ms()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn renderer(id: &str, title: &str, channel: &str, age: &str, length: &str) -> Value {
    json!({
        "videoId": id,
        "title": { "runs": [{ "text": title }] },
        "ownerText": { "runs": [{ "text": channel, "navigationEndpoint": {
            "browseEndpoint": { "browseId": format!("UC{channel}") } } }] },
        "lengthText": { "simpleText": length },
        "publishedTimeText": { "simpleText": age },
        "viewCountText": { "simpleText": "12,345 views" }
    })
}

fn search_answer(prefix: &str, topic: &str, n: usize) -> String {
    let items: Vec<Value> = (0..n)
        .map(|i| {
            json!({ "videoRenderer": renderer(
                &format!("{prefix}{i:02}"),
                &format!("{topic} lesson part {i} explained"),
                &format!("Chan{prefix}{}", i % 7),
                &format!("{} days ago", i + 1),
                "14:05",
            ) })
        })
        .collect();
    json!({ "contents": { "twoColumnSearchResultsRenderer": { "primaryContents": {
        "sectionListRenderer": { "contents": [{ "itemSectionRenderer": { "contents": items } }] }
    } } } })
    .to_string()
}

fn watch_answer(title: &str, channel: &str, related_topic: &str) -> String {
    let related: Vec<Value> = (0..12)
        .map(|i| {
            json!({ "compactVideoRenderer": renderer(
                &format!("rel{i:02}"),
                &format!("{related_topic} technique number {i}"),
                &format!("Rel{}", i % 5),
                &format!("{} weeks ago", i + 1),
                "9:30",
            ) })
        })
        .collect();
    json!({ "contents": { "twoColumnWatchNextResults": {
        "results": { "results": { "contents": [
            { "videoPrimaryInfoRenderer": { "title": { "runs": [{ "text": title }] } } },
            { "videoSecondaryInfoRenderer": {
                "owner": { "videoOwnerRenderer": {
                    "title": { "runs": [{ "text": channel }] },
                    "navigationEndpoint": { "browseEndpoint": { "browseId": format!("UC{channel}") } }
                } },
                "attributedDescription": { "content": format!("{title}. A full walkthrough.") }
            } }
        ] } },
        "secondaryResults": { "secondaryResults": { "results": related } }
    } } })
    .to_string()
}

fn watch(engine: &mut Engine, id: &str, title: &str, channel: &str, seconds: f64) {
    engine.watch_page(id, &watch_answer(title, channel, "woodworking"));
    let mut position = 0.0;
    while position < seconds {
        position += 10.0;
        engine.watch_progress(ProgressReport {
            video_id: id.into(),
            title: String::new(),
            channel_name: String::new(),
            channel_id: String::new(),
            is_live: false,
            position,
            duration: 600.0,
            played_delta: 10.0,
        });
    }
}

/// Answers a plan the way the tweak would, with synthetic pages.
fn answer(plan: &Plan) -> Vec<Answer> {
    plan.requests
        .iter()
        .map(|r| {
            let body = if r.url.contains("/search") {
                let query: Value = serde_json::from_str(&r.body).unwrap();
                search_answer(&r.id, query["query"].as_str().unwrap_or("x"), 20)
            } else if r.url.contains("/next") {
                watch_answer("Seed video", "SeedChan", "woodworking")
            } else {
                search_answer(&r.id, "uploads", 8)
            };
            Answer { id: r.id.clone(), status: 200, body }
        })
        .collect()
}

#[test]
fn a_new_viewer_gets_a_starter_feed_from_discovery_searches() {
    let mut engine = Engine::open(&temp_dir("cold"), "us");
    let plan = engine.plan_home(false);
    assert!(plan.requests.iter().any(|r| r.url.contains("/search")), "cold start searches");
    let page = engine.assemble(plan.load_id, answer(&plan));
    assert!(!page.items.is_empty(), "a starter page");
    assert!(page.cold_start);
    assert!(page.items.iter().all(|i| i.reason.starts_with("From a search for")));
}

#[test]
fn watching_teaches_the_brain_and_seeds_the_related_lane() {
    let dir = temp_dir("learn");
    let mut engine = Engine::open(&dir, "US");
    watch(&mut engine, "w1", "Hand cut dovetail joints for beginners", "WoodShop", 500.0);
    watch(&mut engine, "w2", "Sharpening chisels and hand planes", "WoodShop", 480.0);
    engine.watch_end();
    assert!(engine.brain.total_interactions >= 2, "click and watch logged");
    assert_eq!(engine.library.history.len(), 2);
    assert!(engine.stats().top_topics.iter().any(|t| {
        let t = t.to_lowercase();
        t.contains("dovetail") || t.contains("chisel") || t.contains("joint") || t.contains("plane")
    }), "topics: {:?}", engine.stats().top_topics);

    let plan = engine.plan_home(false);
    let related: Vec<&RequestSpec> = plan.requests.iter().filter(|r| r.id.starts_with("r:")).collect();
    // The watch pages already fetched while watching are reused, so seeds need no new request.
    assert!(related.is_empty() || related.iter().all(|r| r.url.contains("/next")));
    let page = engine.assemble(plan.load_id, answer(&plan));
    assert!(page.items.iter().any(|i| i.source == "related"), "{:#?}", page.items.iter().map(|i| (&i.source, &i.reason)).collect::<Vec<_>>());
    assert!(!page.items.iter().any(|i| i.video.id == "w1"), "watched videos stay out");

    // Everything survives a relaunch.
    engine.save().unwrap();
    let reopened = Engine::open(&dir, "US");
    assert_eq!(reopened.brain.total_interactions, engine.brain.total_interactions);
    assert_eq!(reopened.library.history.len(), 2);
}

#[test]
fn not_interested_hides_the_video_and_a_like_is_kept() {
    let mut engine = Engine::open(&temp_dir("feedback"), "US");
    watch(&mut engine, "w1", "Restoring a vintage motorcycle engine", "Garage", 400.0);
    assert!(engine.feedback("w1", "like", None));
    assert_eq!(engine.library.likes.len(), 1);
    let video = VideoSummary {
        id: "bad".into(),
        title: "Celebrity gossip roundup".into(),
        channel_name: "Gossip".into(),
        channel_id: Some("UCGossip".into()),
        duration_seconds: Some(300),
        ..VideoSummary::default()
    };
    assert!(engine.feedback("bad", "notInterested", Some(video)));
    assert!(engine.brain.suppressed_video_ids.contains_key("bad"));
}

#[test]
fn subscriptions_are_fetched_and_their_uploads_shown() {
    let mut engine = Engine::open(&temp_dir("subs"), "US");
    engine.subscription("UCMaker", "Maker", None, true);
    let plan = engine.plan_home(false);
    assert!(plan.requests.iter().any(|r| r.id == "c:UCMaker"));
    let answers: Vec<Answer> = plan
        .requests
        .iter()
        .map(|r| {
            let body = if r.id == "c:UCMaker" {
                let items: Vec<Value> = (0..5)
                    .map(|i| json!({ "richItemRenderer": { "content": { "videoRenderer":
                        renderer(&format!("up{i}"), &format!("Workshop build {i}"), "Maker", &format!("{} hours ago", i + 2), "20:00") } } }))
                    .collect();
                json!({ "metadata": { "channelMetadataRenderer": { "title": "Maker" } },
                        "contents": { "richGridRenderer": { "contents": items } } })
                .to_string()
            } else {
                search_answer(&r.id, "misc", 10)
            };
            Answer { id: r.id.clone(), status: 200, body }
        })
        .collect();
    let page = engine.assemble(plan.load_id, answers);
    assert!(page.items.iter().any(|i| i.source == "subscription" && i.video.id.starts_with("up")));
}

#[test]
fn load_more_brings_new_cards() {
    let mut engine = Engine::open(&temp_dir("more"), "US");
    let plan = engine.plan_home(false);
    let first = engine.assemble(plan.load_id, answer(&plan));
    let plan = engine.plan_home(true);
    let more = engine.assemble(plan.load_id, answer(&plan));
    let first_ids: HashSet<&str> = first.items.iter().map(|i| i.video.id.as_str()).collect();
    assert!(!more.items.is_empty());
    assert!(more.items.iter().all(|i| !first_ids.contains(i.video.id.as_str())));
}

#[test]
fn no_answers_is_offline_not_empty() {
    let mut engine = Engine::open(&temp_dir("offline"), "US");
    let plan = engine.plan_home(false);
    let page = engine.assemble(plan.load_id, Vec::new());
    assert!(page.items.is_empty());
    assert!(page.offline);
}

#[test]
fn a_stale_plan_is_ignored() {
    let mut engine = Engine::open(&temp_dir("stale"), "US");
    let old = engine.plan_home(false);
    let new = engine.plan_home(false);
    assert!(engine.assemble(old.load_id, answer(&old)).items.is_empty());
    let _ = new;
}

#[test]
fn a_corrupt_state_file_is_kept_aside() {
    let dir = temp_dir("corrupt");
    std::fs::write(dir.join(STATE_FILE), "{not json").unwrap();
    let mut engine = Engine::open(&dir, "US");
    assert_eq!(engine.brain.total_interactions, 0);
    engine.save().unwrap();
    let kept = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(Result::ok)
        .any(|e| e.file_name().to_string_lossy().contains("corrupt"));
    assert!(kept);
}

#[test]
fn the_subscriptions_page_lists_followed_uploads_newest_first_and_names_channels() {
    let mut engine = Engine::open(&temp_dir("subs-page"), "US");
    // Copied from the account: ids only.
    engine.import_subscriptions(vec![Subscription { id: "UCMaker".into(), name: String::new(), avatar_url: None }]);
    assert!(engine.is_subscribed("UCMaker"));
    let plan = engine.plan_subscriptions();
    assert_eq!(plan.requests.len(), 1);
    let items: Vec<Value> = [("old", "3 weeks ago"), ("new", "2 hours ago"), ("mid", "4 days ago")]
        .iter()
        .map(|(id, age)| json!({ "richItemRenderer": { "content": { "videoRenderer":
            renderer(id, &format!("Build {id}"), "Maker", age, "12:00") } } }))
        .collect();
    let body = json!({ "metadata": { "channelMetadataRenderer": { "title": "Maker Workshop" } },
                       "contents": { "richGridRenderer": { "contents": items } } }).to_string();
    let page = engine.assemble(plan.load_id, vec![Answer { id: plan.requests[0].id.clone(), status: 200, body }]);
    let ids: Vec<&str> = page.items.iter().map(|i| i.video.id.as_str()).collect();
    assert_eq!(ids, ["new", "mid", "old"]);
    assert_eq!(engine.library_list("subscriptions")[0]["name"], "Maker Workshop");
    // A fresh store needs no refetch, and the page still shows from it.
    let again = engine.plan_subscriptions();
    assert!(again.requests.is_empty());
    let page = engine.assemble(again.load_id, Vec::new());
    assert_eq!(page.items.len(), 3);
    assert!(!page.offline);
}

#[test]
fn library_lists_hold_likes_and_history() {
    let mut engine = Engine::open(&temp_dir("library"), "US");
    watch(&mut engine, "w1", "Restoring a vintage motorcycle engine", "Garage", 400.0);
    engine.feedback("w1", "like", None);
    engine.watch_end();
    assert_eq!(engine.library_list("likes").as_array().unwrap().len(), 1);
    assert_eq!(engine.library_list("history")[0]["videoId"], "w1");
    engine.subscription("UCGarage", "Garage", None, true);
    engine.subscription("UCGarage", "Garage", None, false);
    assert!(!engine.is_subscribed("UCGarage"));
}

#[test]
fn a_nameless_copy_keeps_a_known_channel_name() {
    let mut engine = Engine::open(&temp_dir("names"), "US");
    engine.subscription("UCA", "Alpha", None, true);
    let added = engine.import_subscriptions(vec![
        Subscription { id: "UCA".into(), name: String::new(), avatar_url: None },
        Subscription { id: "UCB".into(), name: String::new(), avatar_url: None },
    ]);
    assert_eq!(added, 1);
    let subs = engine.library_list("subscriptions");
    assert!(subs.as_array().unwrap().iter().any(|s| s["id"] == "UCA" && s["name"] == "Alpha"));
}
