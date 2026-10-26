//! Imports that give a new brain something to start from: Google Takeout's YouTube
//! `subscriptions.csv` and `watch-history.json`, and NewPipe's subscriptions export.

use serde::Deserialize;

use crate::flow_neuro::bootstrap::ImportedVideo;
use crate::home::inputs::Subscription;

/// Takeout `subscriptions.csv`: `Channel Id,Channel Url,Channel Title`.
#[must_use]
pub fn takeout_subscriptions(csv: &str) -> Vec<Subscription> {
    csv.lines()
        .filter(|line| !line.trim().is_empty())
        .filter_map(|line| {
            let fields = split_csv(line);
            let id = fields.first()?.trim().to_string();
            id.starts_with("UC").then(|| Subscription {
                id,
                name: fields.get(2).map(|n| n.trim().to_string()).unwrap_or_default(),
                avatar_url: None,
            })
        })
        .collect()
}

fn split_csv(line: &str) -> Vec<String> {
    let mut fields = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' if quoted && chars.peek() == Some(&'"') => {
                field.push('"');
                chars.next();
            }
            '"' => quoted = !quoted,
            ',' if !quoted => fields.push(std::mem::take(&mut field)),
            _ => field.push(c),
        }
    }
    fields.push(field);
    fields
}

#[derive(Deserialize)]
struct NewPipeExport {
    #[serde(default)]
    subscriptions: Vec<NewPipeChannel>,
}

#[derive(Deserialize)]
struct NewPipeChannel {
    #[serde(default)]
    url: String,
    #[serde(default)]
    name: String,
}

fn channel_id_in(url: &str) -> Option<String> {
    let at = url.find("/channel/")? + "/channel/".len();
    let id: String = url[at..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .collect();
    id.starts_with("UC").then_some(id)
}

/// NewPipe / Flow `subscriptions.json`: `{ "subscriptions": [{ "url", "name" }] }`.
#[must_use]
pub fn newpipe_subscriptions(json: &str) -> Vec<Subscription> {
    serde_json::from_str::<NewPipeExport>(json)
        .map(|export| {
            export
                .subscriptions
                .into_iter()
                .filter_map(|c| {
                    Some(Subscription { id: channel_id_in(&c.url)?, name: c.name, avatar_url: None })
                })
                .collect()
        })
        .unwrap_or_default()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TakeoutEntry {
    #[serde(default)]
    header: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    title_url: String,
    #[serde(default)]
    subtitles: Vec<TakeoutSubtitle>,
    #[serde(default)]
    time: String,
}

#[derive(Deserialize)]
struct TakeoutSubtitle {
    #[serde(default)]
    name: String,
    #[serde(default)]
    url: String,
}

/// Takeout `watch-history.json`. Music plays and removed videos are left out; the title loses
/// its "Watched " prefix (English exports; other languages keep their title as is).
#[must_use]
pub fn takeout_history(json: &str) -> Vec<ImportedVideo> {
    let Ok(entries) = serde_json::from_str::<Vec<TakeoutEntry>>(json) else {
        return Vec::new();
    };
    entries
        .into_iter()
        .filter_map(|entry| {
            let video_id = entry.title_url.split("v=").nth(1)?.split('&').next()?.to_string();
            if video_id.len() != 11 {
                return None;
            }
            let title = entry.title.strip_prefix("Watched ").unwrap_or(&entry.title).trim().to_string();
            if title.starts_with("https://") {
                return None;
            }
            let channel = entry.subtitles.first();
            let watched_at = chrono::DateTime::parse_from_rfc3339(&entry.time)
                .map(|t| t.timestamp_millis())
                .unwrap_or(0);
            Some(ImportedVideo {
                video_id,
                title,
                channel_name: channel.map(|c| c.name.clone()).unwrap_or_default(),
                channel_id: channel.and_then(|c| channel_id_in(&c.url)),
                duration_seconds: None,
                watched_at,
                is_music: entry.header.contains("Music"),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takeout_csv_reads_ids_and_quoted_names() {
        let csv = "Channel Id,Channel Url,Channel Title\n\
                   UCabc,http://www.youtube.com/channel/UCabc,\"Smith, Woodworks\"\n\
                   UCdef,http://www.youtube.com/channel/UCdef,Chess Daily\n";
        let subs = takeout_subscriptions(csv);
        assert_eq!(subs.len(), 2);
        assert_eq!(subs[0].name, "Smith, Woodworks");
        assert_eq!(subs[1].id, "UCdef");
    }

    #[test]
    fn newpipe_reads_channel_urls() {
        let json = r#"{"app_version":"0.27","subscriptions":[
            {"service_id":0,"url":"https://www.youtube.com/channel/UCxyz","name":"Maker"},
            {"service_id":0,"url":"https://www.youtube.com/@handle","name":"No id"}]}"#;
        let subs = newpipe_subscriptions(json);
        assert_eq!(subs.len(), 1);
        assert_eq!(subs[0].id, "UCxyz");
    }

    #[test]
    fn takeout_history_strips_watched_and_skips_music_and_removed() {
        let json = r#"[
          {"header":"YouTube","title":"Watched Restoring an old lathe","titleUrl":"https://www.youtube.com/watch?v=abcdefghijk",
           "subtitles":[{"name":"Shop","url":"https://www.youtube.com/channel/UCshop"}],"time":"2026-09-01T10:00:00.000Z"},
          {"header":"YouTube Music","title":"Watched Song","titleUrl":"https://www.youtube.com/watch?v=bcdefghijkl","time":"2026-09-01T10:00:00Z"},
          {"header":"YouTube","title":"Watched https://www.youtube.com/watch?v=cdefghijklm","titleUrl":"https://www.youtube.com/watch?v=cdefghijklm","time":"2026-09-01T10:00:00Z"}
        ]"#;
        let videos = takeout_history(json);
        assert_eq!(videos.len(), 2);
        assert_eq!(videos[0].title, "Restoring an old lathe");
        assert_eq!(videos[0].channel_id.as_deref(), Some("UCshop"));
        assert!(videos[0].watched_at > 0);
        assert!(videos[1].is_music);
    }
}
