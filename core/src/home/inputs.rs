//! What one Home load reads locally (Flow Desktop `home_feed/inputs.rs`): the channels followed,
//! likes and watch history as seeds, the videos already watched, and what the viewer hid. Flow
//! reads these from SQLite; FlowTube keeps them in its [`Library`], saved with the brain.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use super::card::Card;
use super::channel_memory::Watch;
use super::seeds::{SeedInput, SeedSource};
use crate::flow_neuro::gates::BlockedMatchers;
use crate::flow_neuro::scoring::{CHANNEL_SUPPRESSION_DAYS, UserBrain, is_known_short};
use crate::models::video::VideoSummary;

const HISTORY_MAX: usize = 400;
const LIKES_MAX: usize = 300;
const DISMISSED_MAX: usize = 500;
const HISTORY_SEED_MAX: usize = 40;
const LONG_TERM_HISTORY_MAX: usize = 200;
/// Mostly watched: Home does not suggest it again.
const WATCHED_SHARE: f64 = 0.85;
const WATCHED_UNKNOWN_LENGTH_SECONDS: u64 = 1800;

/// One viewing, as Flow's `watch_history` table holds it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryRecord {
    pub video_id: String,
    pub title: String,
    #[serde(default)]
    pub channel_id: Option<String>,
    #[serde(default)]
    pub channel_name: String,
    pub watched_at_ms: u64,
    pub watch_seconds: u64,
    #[serde(default)]
    pub duration_seconds: Option<u64>,
}

impl HistoryRecord {
    fn is_short(&self) -> bool {
        is_known_short(self.duration_seconds)
    }

    fn is_mostly_watched(&self) -> bool {
        match self.duration_seconds {
            #[allow(clippy::cast_precision_loss)]
            Some(total) if total > 0 => self.watch_seconds as f64 / total as f64 >= WATCHED_SHARE,
            _ => self.watch_seconds >= WATCHED_UNKNOWN_LENGTH_SECONDS,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Subscription {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub avatar_url: Option<String>,
}

/// The viewer's local library: what Flow keeps in its history, library and settings tables.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Library {
    /// Newest first.
    #[serde(default)]
    pub history: Vec<HistoryRecord>,
    /// Liked videos with when they were liked, newest first.
    #[serde(default)]
    pub likes: Vec<(VideoSummary, u64)>,
    #[serde(default)]
    pub subscriptions: Vec<Subscription>,
    /// Videos dismissed from the feed.
    #[serde(default)]
    pub dismissed: Vec<String>,
}

impl Library {
    /// Records a viewing; a video watched again replaces its earlier record.
    pub fn add_history(&mut self, record: HistoryRecord) {
        self.history.retain(|r| r.video_id != record.video_id);
        self.history.insert(0, record);
        self.history.truncate(HISTORY_MAX);
    }

    pub fn set_liked(&mut self, video: VideoSummary, liked: bool, now_ms: u64) {
        self.likes.retain(|(v, _)| v.id != video.id);
        if liked {
            self.likes.insert(0, (video, now_ms));
            self.likes.truncate(LIKES_MAX);
        }
    }

    pub fn dismiss(&mut self, video_id: &str) {
        if !self.dismissed.iter().any(|id| id == video_id) {
            self.dismissed.push(video_id.to_string());
        }
        if self.dismissed.len() > DISMISSED_MAX {
            let excess = self.dismissed.len() - DISMISSED_MAX;
            self.dismissed.drain(..excess);
        }
    }

    pub fn set_subscribed(&mut self, mut channel: Subscription, subscribed: bool) {
        if let Some(known) = self.subscriptions.iter().find(|s| s.id == channel.id) {
            // A source without a name or avatar never blanks what is known.
            if channel.name.is_empty() {
                channel.name.clone_from(&known.name);
            }
            if channel.avatar_url.is_none() {
                channel.avatar_url.clone_from(&known.avatar_url);
            }
        }
        self.subscriptions.retain(|s| s.id != channel.id);
        if subscribed {
            self.subscriptions.push(channel);
        }
    }

    #[must_use]
    pub fn recent_titles(&self, limit: usize) -> Vec<String> {
        self.history.iter().take(limit).map(|r| r.title.clone()).collect()
    }
}

/// The channels the viewer follows, by id, with their names and avatars.
#[derive(Default)]
pub struct Subscriptions {
    pub names: HashMap<String, String>,
    pub avatars: HashMap<String, String>,
}

impl Subscriptions {
    pub fn ids(&self) -> HashSet<String> {
        self.names.keys().cloned().collect()
    }
}

/// What the viewer hid: videos, channels and topics.
pub struct Exclusions {
    videos: HashSet<String>,
    channels: HashSet<String>,
    matchers: BlockedMatchers,
    spec: crate::flow_neuro::keyspec::KeySpec,
}

impl Exclusions {
    pub fn hidden_videos(&self) -> &HashSet<String> {
        &self.videos
    }

    #[must_use]
    pub fn hides(&self, card: &Card) -> bool {
        self.videos.contains(card.id())
            || self.channels.contains(card.channel_id())
            || self
                .matchers
                .blocks_text(&card.video.title, &card.video.channel_name, &self.spec)
    }
}

/// Everything local one Home load reads.
pub struct Inputs {
    pub subscriptions: Subscriptions,
    pub watched: HashSet<String>,
    pub exclusions: Exclusions,
    pub history: Vec<HistoryRecord>,
    pub likes: Vec<(VideoSummary, u64)>,
}

impl Inputs {
    #[must_use]
    pub fn load(library: &Library, brain: &UserBrain, now_ms: u64) -> Self {
        let mut subscriptions = Subscriptions::default();
        for sub in &library.subscriptions {
            let id = sub.id.trim().trim_start_matches("channel:").to_string();
            if id.is_empty() {
                continue;
            }
            if let Some(avatar) = sub.avatar_url.clone().filter(|a| !a.is_empty()) {
                subscriptions.avatars.insert(id.clone(), avatar);
            }
            subscriptions.names.insert(id, sub.name.clone());
        }
        let watched: HashSet<String> = library
            .history
            .iter()
            .filter(|r| r.is_mostly_watched())
            .map(|r| r.video_id.clone())
            .collect();
        let channel_cutoff = now_ms.saturating_sub(CHANNEL_SUPPRESSION_DAYS * 86_400_000);
        let channels: HashSet<String> = brain
            .blocked_channels
            .iter()
            .cloned()
            .chain(
                brain
                    .suppressed_channels
                    .iter()
                    .filter(|(_, at)| **at > channel_cutoff)
                    .map(|(id, _)| id.clone()),
            )
            .collect();
        let mut videos: HashSet<String> = brain.suppressed_video_ids.keys().cloned().collect();
        videos.extend(library.dismissed.iter().cloned());
        let spec = brain.key_spec();
        Self {
            exclusions: Exclusions {
                videos,
                channels,
                matchers: BlockedMatchers::new(&brain.blocked_topics, &spec),
                spec,
            },
            subscriptions,
            watched,
            history: library.history.clone(),
            likes: library.likes.clone(),
        }
    }

    fn history_seeds(&self) -> impl Iterator<Item = SeedInput> + '_ {
        self.history.iter().filter(|r| !r.is_short()).map(|record| {
            let duration = record.duration_seconds.unwrap_or(0);
            #[allow(clippy::cast_precision_loss)]
            let percent = if duration > 0 {
                (record.watch_seconds as f64 * 100.0 / duration as f64).clamp(0.0, 100.0)
            } else {
                0.0
            };
            SeedInput {
                id: record.video_id.clone(),
                title: record.title.clone(),
                channel_id: record.channel_id.clone().unwrap_or_default(),
                source: SeedSource::WatchHistory,
                engagement_weight: percent / 100.0,
                timestamp_ms: record.watched_at_ms,
                duration_seconds: duration,
                percent_watched: percent,
            }
        })
    }

    /// The newest 40 watches, as related-lane seeds.
    pub fn recent_seeds(&self, disliked: &HashSet<String>) -> Vec<SeedInput> {
        self.history_seeds()
            .filter(|seed| !disliked.contains(&seed.id))
            .take(HISTORY_SEED_MAX)
            .collect()
    }

    fn like_seeds(&self) -> impl Iterator<Item = SeedInput> + '_ {
        self.likes.iter().map(|(video, at)| SeedInput {
            id: video.id.clone(),
            title: video.title.clone(),
            channel_id: video.channel_id.clone().unwrap_or_default(),
            source: SeedSource::Liked,
            engagement_weight: 1.0,
            timestamp_ms: *at,
            duration_seconds: video.duration_seconds.unwrap_or(0),
            percent_watched: 0.0,
        })
    }

    /// Seeds for lasting interests: likes and the watches older than the recent ones.
    pub fn long_term_seeds(&self, disliked: &HashSet<String>) -> Vec<SeedInput> {
        let mut seen = HashSet::new();
        self.like_seeds()
            .chain(
                self.history_seeds()
                    .take(LONG_TERM_HISTORY_MAX)
                    .skip(HISTORY_SEED_MAX),
            )
            .filter(|seed| !disliked.contains(&seed.id) && seen.insert(seed.id.clone()))
            .collect()
    }

    /// Watches by channel, for channel memory.
    pub fn watches(&self) -> Vec<Watch> {
        self.history
            .iter()
            .filter(|r| !r.is_short())
            .filter_map(|record| {
                Some(Watch {
                    channel_id: record.channel_id.clone()?,
                    channel_name: record.channel_name.clone(),
                    watched_at_ms: record.watched_at_ms,
                    watched_seconds: record.watch_seconds,
                    duration_seconds: record.duration_seconds.unwrap_or(0),
                })
            })
            .collect()
    }

    /// Likes by channel, for channel memory.
    pub fn liked_channels(&self) -> Vec<(String, u64)> {
        self.likes
            .iter()
            .filter_map(|(video, at)| Some((video.channel_id.clone()?, *at)))
            .collect()
    }
}
