//! InnerTube for the tweak: the requests the feed needs (search, a watch page's related list, a
//! channel's uploads) as ready-to-send specs, and readers that turn the answers into cards with
//! Flow's own renderer parsers. The tweak only moves bytes; everything YouTube-shaped lives here.
//!
//! Requests are logged-out WEB requests, exactly what Flow sends, so fetching candidates never
//! touches the viewer's account, history or recommendations.

use std::collections::HashSet;

use serde::Serialize;
use serde_json::{Value, json};

use crate::api::innertube::json::text::text_of;
use crate::api::innertube::renderers::lockup::{lockup_item, related_to_video};
use crate::api::innertube::renderers::video::video_from_renderer;
use crate::models::video::VideoSummary;

const BASE: &str = "https://www.youtube.com/youtubei/v1/";
/// Flow Desktop's WEB client (`core/clients.rs`).
pub const WEB_CLIENT_VERSION: &str = "2.20260710.06.00";
/// Search filtered to videos (type = video).
const VIDEOS_ONLY: &str = "EgIQAQ==";
/// A channel's Videos tab (Flow `extractors/channel::VIDEOS_TAB_PARAMS`).
const VIDEOS_TAB_PARAMS: &str = "EgZ2aWRlb3PyBgQKAjoA";

/// One HTTP request for the host to send: POST `url` with the JSON `body` and `headers`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestSpec {
    /// The host hands this back with the answer.
    pub id: String,
    pub url: String,
    pub body: String,
    pub headers: Vec<(String, String)>,
}

fn context(region: &str) -> Value {
    json!({
        "client": {
            "clientName": "WEB",
            "clientVersion": WEB_CLIENT_VERSION,
            // English text, so counts and ages read the way the ranker expects.
            "hl": "en",
            "gl": region,
        }
    })
}

fn request(id: String, endpoint: &str, mut body: Value, region: &str) -> RequestSpec {
    body["context"] = context(region);
    RequestSpec {
        id,
        url: format!("{BASE}{endpoint}?prettyPrint=false"),
        body: body.to_string(),
        headers: vec![
            ("Content-Type".into(), "application/json".into()),
            ("X-YouTube-Client-Name".into(), "1".into()),
            ("X-YouTube-Client-Version".into(), WEB_CLIENT_VERSION.into()),
            ("Origin".into(), "https://www.youtube.com".into()),
        ],
    }
}

#[must_use]
pub fn search_request(id: String, query: &str, region: &str) -> RequestSpec {
    request(
        id,
        "search",
        json!({ "query": query, "params": VIDEOS_ONLY }),
        region,
    )
}

#[must_use]
pub fn watch_next_request(id: String, video_id: &str, region: &str) -> RequestSpec {
    request(
        id,
        "next",
        json!({ "videoId": video_id, "racyCheckOk": true, "contentCheckOk": true }),
        region,
    )
}

#[must_use]
pub fn channel_videos_request(id: String, channel_id: &str, region: &str) -> RequestSpec {
    request(
        id,
        "browse",
        json!({ "browseId": channel_id, "params": VIDEOS_TAB_PARAMS }),
        region,
    )
}

/// Every video card anywhere in an answer, in document order, once each: classic renderers
/// (`videoRenderer`, `compactVideoRenderer`, `gridVideoRenderer`) and lockup view models, which
/// is what search, the related lane and channel tabs are built from.
#[must_use]
pub fn videos_in(answer: &Value) -> Vec<VideoSummary> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    walk(answer, &mut out, &mut seen, 0);
    out
}

fn walk(value: &Value, out: &mut Vec<VideoSummary>, seen: &mut HashSet<String>, depth: usize) {
    if depth > 64 {
        return;
    }
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                let found = match key.as_str() {
                    "videoRenderer" | "compactVideoRenderer" | "gridVideoRenderer" => {
                        video_from_renderer(child)
                    }
                    "lockupViewModel" => lockup_item(child)
                        .filter(|item| item.item_type == "video")
                        .map(related_to_video),
                    // Ads and promoted renderers carry videos the viewer did not ask for.
                    "adSlotRenderer" | "promotedSparklesWebRenderer" | "promotedVideoRenderer" => {
                        continue;
                    }
                    _ => None,
                };
                match found {
                    Some(video) => {
                        if seen.insert(video.id.clone()) {
                            out.push(video);
                        }
                    }
                    None => walk(child, out, seen, depth + 1),
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                walk(item, out, seen, depth + 1);
            }
        }
        _ => {}
    }
}

/// What a watch page says about its video, and the related list beside it.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchDetails {
    pub title: String,
    pub channel_name: String,
    pub channel_id: String,
    pub description: Option<String>,
    pub related: Vec<VideoSummary>,
}

/// Flow `extractors/watch_next`: the primary and secondary info renderers, then the related lane.
#[must_use]
pub fn watch_details(next: &Value, video_id: &str) -> WatchDetails {
    let mut primary = &Value::Null;
    let mut secondary = &Value::Null;
    for item in next["contents"]["twoColumnWatchNextResults"]["results"]["results"]["contents"]
        .as_array()
        .into_iter()
        .flatten()
    {
        if let Some(renderer) = item.get("videoPrimaryInfoRenderer") {
            primary = renderer;
        }
        if let Some(renderer) = item.get("videoSecondaryInfoRenderer") {
            secondary = renderer;
        }
    }
    let owner = &secondary["owner"]["videoOwnerRenderer"];
    let related_root = &next["contents"]["twoColumnWatchNextResults"]["secondaryResults"];
    let related = videos_in(related_root)
        .into_iter()
        .filter(|video| video.id != video_id)
        .collect();
    WatchDetails {
        title: text_of(&primary["title"]).unwrap_or_default(),
        channel_name: text_of(&owner["title"])
            .or_else(|| text_of(&owner["attributedTitle"]))
            .unwrap_or_default(),
        channel_id: owner["navigationEndpoint"]["browseEndpoint"]["browseId"]
            .as_str()
            .unwrap_or_default()
            .to_string(),
        description: secondary["attributedDescription"]["content"]
            .as_str()
            .filter(|text| !text.is_empty())
            .map(ToOwned::to_owned),
        related,
    }
}

/// A channel's name as its browse answer gives it, for uploads whose cards leave it out.
#[must_use]
pub fn channel_name_of(browse: &Value) -> Option<String> {
    browse["metadata"]["channelMetadataRenderer"]["title"]
        .as_str()
        .map(ToOwned::to_owned)
        .or_else(|| {
            browse["header"]["pageHeaderRenderer"]["pageTitle"]
                .as_str()
                .map(ToOwned::to_owned)
        })
}

/// A channel's uploads, with the channel filled in where the tab's cards omit it.
#[must_use]
pub fn channel_videos(browse: &Value, channel_id: &str, fallback_name: &str) -> Vec<VideoSummary> {
    let name = channel_name_of(browse).unwrap_or_else(|| fallback_name.to_string());
    videos_in(browse)
        .into_iter()
        .map(|mut video| {
            if video.channel_id.as_deref().is_none_or(str::is_empty) {
                video.channel_id = Some(channel_id.to_string());
            }
            if video.channel_name.is_empty() {
                video.channel_name.clone_from(&name);
            }
            video
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn renderer(id: &str, title: &str, channel: &str) -> Value {
        json!({
            "videoId": id,
            "title": { "runs": [{ "text": title }] },
            "ownerText": { "runs": [{ "text": channel, "navigationEndpoint": {
                "browseEndpoint": { "browseId": format!("UC{channel}") } } }] },
            "lengthText": { "simpleText": "12:34" },
            "publishedTimeText": { "simpleText": "3 days ago" },
            "viewCountText": { "simpleText": "1,234 views" }
        })
    }

    #[test]
    fn search_cards_are_read_in_order_once_and_ads_skipped() {
        let answer = json!({ "contents": { "twoColumnSearchResultsRenderer": { "primaryContents": {
            "sectionListRenderer": { "contents": [{ "itemSectionRenderer": { "contents": [
                { "adSlotRenderer": { "videoRenderer": renderer("ad", "Buy", "Ads") } },
                { "videoRenderer": renderer("a1", "Rust ownership explained", "Chan") },
                { "videoRenderer": renderer("a2", "Borrow checker deep dive", "Other") },
                { "videoRenderer": renderer("a1", "Rust ownership explained", "Chan") }
            ] } }] } } } } });
        let videos = videos_in(&answer);
        let ids: Vec<&str> = videos.iter().map(|v| v.id.as_str()).collect();
        assert_eq!(ids, ["a1", "a2"]);
        assert_eq!(videos[0].title, "Rust ownership explained");
        assert_eq!(videos[0].channel_name, "Chan");
        assert_eq!(videos[0].channel_id.as_deref(), Some("UCChan"));
        assert_eq!(videos[0].duration_seconds, Some(754));
    }

    #[test]
    fn a_watch_page_gives_its_details_and_related_list() {
        let next = json!({ "contents": { "twoColumnWatchNextResults": {
            "results": { "results": { "contents": [
                { "videoPrimaryInfoRenderer": { "title": { "runs": [{ "text": "Main video" }] } } },
                { "videoSecondaryInfoRenderer": {
                    "owner": { "videoOwnerRenderer": {
                        "title": { "runs": [{ "text": "Owner" }] },
                        "navigationEndpoint": { "browseEndpoint": { "browseId": "UCowner" } }
                    } },
                    "attributedDescription": { "content": "All about woodworking" }
                } }
            ] } },
            "secondaryResults": { "secondaryResults": { "results": [
                { "compactVideoRenderer": renderer("r1", "Related one", "X") },
                { "compactVideoRenderer": renderer("main", "Itself", "Owner") }
            ] } }
        } } });
        let details = watch_details(&next, "main");
        assert_eq!(details.title, "Main video");
        assert_eq!(details.channel_name, "Owner");
        assert_eq!(details.channel_id, "UCowner");
        assert_eq!(details.description.as_deref(), Some("All about woodworking"));
        assert_eq!(details.related.len(), 1);
        assert_eq!(details.related[0].id, "r1");
    }

    #[test]
    fn channel_uploads_take_the_channel_when_cards_omit_it() {
        let mut card = renderer("u1", "New upload", "x");
        card.as_object_mut().unwrap().remove("ownerText");
        let browse = json!({
            "metadata": { "channelMetadataRenderer": { "title": "Maker" } },
            "contents": { "richGridRenderer": { "contents": [
                { "richItemRenderer": { "content": { "videoRenderer": card } } }
            ] } }
        });
        let videos = channel_videos(&browse, "UCmaker", "");
        assert_eq!(videos[0].channel_id.as_deref(), Some("UCmaker"));
        assert_eq!(videos[0].channel_name, "Maker");
    }

    #[test]
    fn requests_carry_the_web_client() {
        let spec = search_request("s0".into(), "chess openings", "US");
        let body: Value = serde_json::from_str(&spec.body).unwrap();
        assert_eq!(body["query"], "chess openings");
        assert_eq!(body["context"]["client"]["clientName"], "WEB");
        assert_eq!(body["context"]["client"]["hl"], "en");
        assert!(spec.url.ends_with("/search?prettyPrint=false"));
    }
}
