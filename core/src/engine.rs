//! FlowTube's engine: Flow Desktop's `RecommendationService`, `home_engine.rs` and Home load
//! (`home_feed/load.rs`) without Tauri, SQLite or async. Everything is resident and saved as one
//! JSON file in the tweak's Application Support folder.
//!
//! A Home load is two calls: [`Engine::plan_home`] says which searches, watch pages and channel
//! tabs to fetch (as ready-made InnerTube requests), and [`Engine::assemble`] takes the answers
//! and returns the ranked page, the way Flow's load fetches wave 1 and then builds its lanes.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::flow_neuro::bootstrap::{ImportedVideo, bootstrap_from_history, bootstrap_from_subscriptions};
use crate::flow_neuro::categories::{CategoryStore, StoredChannel};
use crate::flow_neuro::channel_knowledge::{learn_from_uploads, subscription_changed};
use crate::flow_neuro::clusters::{ClusterInputs, build_clusters};
use crate::flow_neuro::co_watch::{CoWatchSnapshot, CoWatchStore, RelatedChannel, neighbours as co_watch_neighbours};
use crate::flow_neuro::content_store::{ContentStore, Stored as StoredContent};
use crate::flow_neuro::discovery::{SurfaceState, next_queries, note_query_novelty, stale_key};
use crate::flow_neuro::display_forms::with_pick_spellings;
use crate::flow_neuro::learning::{Interaction, apply_interaction};
use crate::flow_neuro::rank::{RankContext, SessionState, rank, share_by_interest};
use crate::flow_neuro::ranker::MomentumEntry;
use crate::flow_neuro::scoring::{
    CHANNEL_SUPPRESSION_DAYS, FeedEntry, IMPRESSION_CACHE_MAX, SESSION_TOPIC_HISTORY_MAX,
    TimeBucket, UserBrain, classify_persona, is_known_short,
};
use crate::flow_neuro::search_learning::learn_search;
use crate::flow_neuro::signals::{InteractionType, SPELLING_TITLES, settle_brain};
use crate::flow_neuro::watch_session::{WatchReport, WatchSession};
use crate::home::arrange::{TasteProfile, rhythm_by_source, space_by_channel};
use crate::home::card::Card;
use crate::home::channel_memory;
use crate::home::filters::{RECENT_CHANNEL_WINDOW, keep_showable};
use crate::home::inputs::{HistoryRecord, Inputs, Library, Subscription};
use crate::home::lanes::{self, Raw};
use crate::home::mixer::FeedSource;
use crate::home::neighbours::{self, Neighbour};
use crate::home::origin::{Origin, OriginKind, Provenance, queries_by_id};
use crate::home::seeds::{GraphCandidate, SeedClusters, SeedInput, SeedSource, merge_candidates, select_with_long_term};
use crate::models::video::VideoSummary;
use crate::youtube::{
    RequestSpec, channel_videos, channel_videos_request, search_request, videos_in, watch_details,
    watch_next_request,
};

const STATE_FILE: &str = "flowneuro_state.json";
const STATE_VERSION: u32 = 1;
/// A channel above its starting score is one the viewer has watched.
const NEUTRAL_CHANNEL_SCORE: f64 = 0.5;
const SESSION_RESET_IDLE_MINUTES: u64 = 120;
const SESSION_RESET_EMPTY_MINUTES: u64 = 30;
const MOMENTUM_WINDOW: usize = 10;
const RECENTLY_SHOWN_MS: u64 = 48 * 3_600_000;
const RELATED_SEED_COOLDOWN_MS: u64 = 6 * 3_600_000;
const RECENT_RELATED_SEEDS_MAX: usize = 60;
const DAY_MS: u64 = 86_400_000;

// Home load sizes, Flow's (`home_feed/load.rs`) trimmed for a phone on cellular.
const FIRST_SEARCHES: usize = 5;
const MORE_SEARCHES: usize = 3;
const MAX_RELATED_SEEDS: usize = 4;
const MORE_RELATED_SEEDS: usize = 2;
const SUB_FETCHES_PER_LOAD: usize = 6;
const MEMORY_FETCHES_PER_LOAD: usize = 5;
const SUB_REFRESH_MS: u64 = 30 * 60_000;
const SUB_UPLOADS_KEPT: usize = 15;
const RELATED_CACHE_MS: u64 = 45 * 60_000;
const CHANNEL_GAP: usize = 10;
const FIRST_PAGE_MIN_SIZE: usize = 30;
const MORE_PAGE_SIZE: usize = 20;
const RESERVE_MAX: usize = 120;
const SUBS_PAGE_FETCHES: usize = 15;
const SUBS_PAGE_SIZE: usize = 150;
const DETAILS_CACHE_MAX: usize = 64;

#[must_use]
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

pub(crate) fn is_watched_channel(brain: &UserBrain, channel: &str) -> bool {
    brain.channel_scores.get(channel).copied().unwrap_or(0.0) > NEUTRAL_CHANNEL_SCORE
}

/// A real watch, a like or a save, as learning counts it.
fn is_strong_signal(kind: InteractionType, percent_watched: f32) -> bool {
    matches!(kind, InteractionType::Liked | InteractionType::Saved)
        || (kind == InteractionType::Watched && percent_watched >= 0.40)
}

fn clean_channel(id: &str) -> &str {
    id.trim().trim_start_matches("channel:")
}

/// Uploads of one followed channel, newest first, and when they were fetched.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChannelUploads {
    fetched_at: u64,
    uploads: Vec<Card>,
}

/// Everything saved between launches.
#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Saved {
    #[serde(default)]
    version: u32,
    /// Kept as raw JSON so a brain that fails to read can be set aside on its own.
    #[serde(default)]
    brain: Value,
    #[serde(default)]
    tidied: bool,
    #[serde(default)]
    categories: HashMap<String, StoredChannel>,
    #[serde(default)]
    co_watch: CoWatchSnapshot,
    #[serde(default)]
    content: HashMap<String, StoredContent>,
    #[serde(default)]
    library: Library,
    #[serde(default)]
    subscription_uploads: HashMap<String, ChannelUploads>,
    #[serde(default)]
    channel_memory: channel_memory::State,
    #[serde(default)]
    neighbours: HashMap<String, neighbours::Stored>,
    #[serde(default)]
    reserve: Vec<Card>,
    #[serde(default)]
    learning_paused: bool,
}

/// What a request in a plan is for.
#[derive(Debug, Clone)]
enum Want {
    Search(String),
    Related(String),
    Subscription(String, String),
    Memory(String, String),
    Neighbour(String, String),
}

/// Which page a plan is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LoadKind {
    Home,
    More,
    Subscriptions,
}

struct PendingLoad {
    id: u64,
    kind: LoadKind,
    wants: HashMap<String, Want>,
    queries: Vec<String>,
    seeds: Vec<SeedInput>,
    seed_ids: Vec<String>,
}

/// What [`Engine::plan_home`] asks the host to fetch.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub load_id: u64,
    pub requests: Vec<RequestSpec>,
}

/// One answer the host fetched for a plan.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Answer {
    pub id: String,
    #[serde(default)]
    pub status: u16,
    #[serde(default)]
    pub body: String,
}

/// One card of a page, with its "Why you see this" line.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedItem {
    #[serde(flatten)]
    pub video: VideoSummary,
    pub reason: String,
    pub source: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    pub items: Vec<FeedItem>,
    /// No answer arrived: nothing to show because the network failed, not because nothing fits.
    pub offline: bool,
    pub cold_start: bool,
}

/// What a watch page told about a video, kept while it is watched.
#[derive(Debug, Clone, Default)]
struct Details {
    title: String,
    channel_name: String,
    channel_id: String,
    description: Option<String>,
}

#[derive(Default)]
struct WatchSlot {
    session: Option<WatchSession>,
    generation: u64,
}

/// A player report from the host. Details are optional: the engine fills them from watch pages.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgressReport {
    pub video_id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub channel_name: String,
    #[serde(default)]
    pub channel_id: String,
    #[serde(default)]
    pub is_live: bool,
    #[serde(default)]
    pub position: f64,
    #[serde(default)]
    pub duration: f64,
    #[serde(default)]
    pub played_delta: f64,
}

/// A summary for the settings screen.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub total_interactions: i32,
    pub persona: String,
    pub top_topics: Vec<String>,
    pub watched_videos: usize,
    pub liked_videos: usize,
    pub subscriptions: usize,
    pub learning_paused: bool,
}

pub struct Engine {
    path: PathBuf,
    region: String,
    pub(crate) brain: UserBrain,
    tidied: bool,
    categories: CategoryStore,
    co_watch: CoWatchStore,
    content: ContentStore,
    library: Library,
    subscription_uploads: HashMap<String, ChannelUploads>,
    memory: channel_memory::State,
    neighbour_store: HashMap<String, neighbours::Stored>,
    reserve: Vec<Card>,
    learning_paused: bool,
    // Session state, as Flow keeps it in memory.
    home_depth: usize,
    related_cache: HashMap<String, (u64, Vec<Card>)>,
    details: HashMap<String, Details>,
    impression_cache: HashMap<String, (i32, u64)>,
    session_topics: Vec<String>,
    session_video_count: i32,
    momentum: Vec<MomentumEntry>,
    last_activity_ms: u64,
    watch: WatchSlot,
    profiled_channels: HashSet<String>,
    pending: Option<PendingLoad>,
    next_load_id: u64,
    on_screen: Vec<String>,
    on_screen_channels: Vec<String>,
    dirty: bool,
}

impl Engine {
    /// Opens the engine saved in `dir`, or a new one. A state file that fails to read is kept
    /// beside the new one rather than overwritten.
    #[must_use]
    pub fn open(dir: &Path, region: &str) -> Self {
        let path = dir.join(STATE_FILE);
        let saved: Saved = match std::fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_else(|error| {
                let backup = dir.join(format!("{STATE_FILE}.corrupt-{}", now_ms()));
                let _ = std::fs::rename(&path, backup);
                tracing::warn!(%error, "[FlowTube] state unreadable; started over");
                Saved::default()
            }),
            Err(_) => Saved::default(),
        };
        let mut tidied = saved.tidied;
        let had_brain = !saved.brain.is_null();
        let mut brain = if had_brain {
            serde_json::from_value::<UserBrain>(saved.brain.clone()).unwrap_or_else(|error| {
                let backup = dir.join(format!("brain.corrupt-{}.json", now_ms()));
                let _ = std::fs::write(backup, saved.brain.to_string());
                tracing::warn!(%error, "[FlowTube] brain unreadable; kept a copy and started a new one");
                UserBrain::default()
            })
        } else {
            // A new brain starts tidy: there is nothing old to migrate.
            tidied = true;
            UserBrain::default()
        };
        let titles = saved.library.recent_titles(usize::try_from(SPELLING_TITLES).unwrap_or(500));
        let changed = settle_brain(&mut brain, &titles, &mut tidied);
        Self {
            path,
            region: if region.len() == 2 { region.to_uppercase() } else { "US".into() },
            brain,
            tidied,
            categories: CategoryStore::new(saved.categories),
            co_watch: CoWatchStore::new(saved.co_watch),
            content: ContentStore::new(saved.content),
            library: saved.library,
            subscription_uploads: saved.subscription_uploads,
            memory: saved.channel_memory,
            neighbour_store: saved.neighbours,
            reserve: saved.reserve,
            learning_paused: saved.learning_paused,
            home_depth: 0,
            related_cache: HashMap::new(),
            details: HashMap::new(),
            impression_cache: HashMap::new(),
            session_topics: Vec::new(),
            session_video_count: 0,
            momentum: Vec::new(),
            last_activity_ms: now_ms(),
            watch: WatchSlot::default(),
            profiled_channels: HashSet::new(),
            pending: None,
            next_load_id: 1,
            on_screen: Vec::new(),
            on_screen_channels: Vec::new(),
            dirty: changed || !had_brain,
        }
    }

    /// Writes the state if anything changed since the last save (write-then-rename).
    pub fn save(&mut self) -> std::io::Result<bool> {
        if !self.dirty {
            return Ok(false);
        }
        let saved = Saved {
            version: STATE_VERSION,
            brain: serde_json::to_value(&self.brain).unwrap_or(Value::Null),
            tidied: self.tidied,
            categories: self.categories.snapshot(),
            co_watch: self.co_watch.snapshot(),
            content: self.content.snapshot(),
            library: self.library.clone(),
            subscription_uploads: self.subscription_uploads.clone(),
            channel_memory: self.memory.clone(),
            neighbours: self.neighbour_store.clone(),
            reserve: self.reserve.clone(),
            learning_paused: self.learning_paused,
        };
        let text = serde_json::to_string(&saved).map_err(std::io::Error::other)?;
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, &self.path)?;
        self.dirty = false;
        Ok(true)
    }

    /// Forgets everything learned and every local record.
    pub fn reset(&mut self) {
        let mut brain = UserBrain::default();
        let mut tidied = true;
        settle_brain(&mut brain, &[], &mut tidied);
        self.brain = brain;
        self.tidied = tidied;
        self.categories = CategoryStore::new(HashMap::new());
        self.co_watch = CoWatchStore::new(CoWatchSnapshot::default());
        self.content = ContentStore::new(HashMap::new());
        self.library = Library::default();
        self.subscription_uploads.clear();
        self.memory = channel_memory::State::default();
        self.neighbour_store.clear();
        self.reserve.clear();
        self.related_cache.clear();
        self.details.clear();
        self.impression_cache.clear();
        self.session_topics.clear();
        self.session_video_count = 0;
        self.momentum.clear();
        self.on_screen.clear();
        self.home_depth = 0;
        self.dirty = true;
    }

    // ---------------------------------------------------------------- ranking (Flow's service)

    fn rank_context<R>(
        &self,
        user_subs: &HashSet<String>,
        min_relevance: f64,
        f: impl FnOnce(&RankContext) -> R,
    ) -> R {
        let now = now_ms();
        let brain = &self.brain;
        let is_watched = |channel: &str| is_watched_channel(brain, channel);
        let channel_edges = self.co_watch.edges(&is_watched, now);
        let co_watch_prior = co_watch_neighbours(&channel_edges, &is_watched);
        let category_of = |channel: &str| self.categories.category_of(channel);
        let stored_topics = |video_id: &str| self.content.topics_for(video_id);
        let no_likes = HashMap::new();
        let ctx = RankContext {
            brain,
            user_subs,
            now_ms: now,
            min_relevance,
            shorts_feed: false,
            like_counts: &no_likes,
            session: SessionState {
                topics: &self.session_topics,
                video_count: self.session_video_count,
                momentum: &self.momentum,
            },
            category_of: &category_of,
            co_watch_prior: &co_watch_prior,
            channel_edges: &channel_edges,
            stored_topics: &stored_topics,
            seed: now,
        };
        f(&ctx)
    }

    /// Flow's `rank_candidates`.
    pub(crate) fn rank_candidates(
        &self,
        candidates: Vec<VideoSummary>,
        user_subs: &HashSet<String>,
        min_relevance: f64,
    ) -> Vec<VideoSummary> {
        if candidates.is_empty() {
            return candidates;
        }
        self.rank_context(user_subs, min_relevance, |ctx| rank(ctx, candidates))
    }

    /// Flow's `share_by_interest`.
    pub(crate) fn share_by_interest(
        &self,
        ranked: Vec<VideoSummary>,
        user_subs: &HashSet<String>,
    ) -> Vec<VideoSummary> {
        if ranked.len() < 2 {
            return ranked;
        }
        self.rank_context(user_subs, 0.0, |ctx| share_by_interest(ctx, ranked))
    }

    /// A session idle for two hours, or half an hour without a video, starts over.
    fn reset_idle_session(&mut self) {
        let now = now_ms();
        let idle_minutes = now.saturating_sub(self.last_activity_ms) / 60_000;
        if idle_minutes > SESSION_RESET_IDLE_MINUTES
            || (self.session_video_count == 0 && idle_minutes > SESSION_RESET_EMPTY_MINUTES)
        {
            self.session_topics.clear();
            self.session_video_count = 0;
            self.momentum.clear();
            self.impression_cache.clear();
        }
        self.last_activity_ms = now;
    }

    fn discovery_queries(&mut self, reset_depth: bool) -> Vec<String> {
        let now = now_ms();
        let brain = &self.brain;
        let is_watched = |channel: &str| is_watched_channel(brain, channel);
        let channel_edges = self.co_watch.edges(&is_watched, now);
        let mut state = SurfaceState {
            depth: self.home_depth,
            recent_query_tokens: brain.recent_query_tokens.clone(),
            cluster_rotation: brain.cluster_rotation.clone(),
        };
        let queries = next_queries(
            brain,
            &mut state,
            reset_depth,
            classify_persona(brain),
            TimeBucket::current(),
            now,
            &channel_edges,
        );
        self.home_depth = state.depth;
        self.brain.recent_query_tokens = state.recent_query_tokens;
        self.brain.cluster_rotation = state.cluster_rotation;
        self.dirty = true;
        queries
    }

    /// When most of a search's results were shown in the last two days, it waits a day.
    fn report_discovery_results(&mut self, query: &str, video_ids: &[String]) {
        let now = now_ms();
        let cutoff = now.saturating_sub(RECENTLY_SHOWN_MS);
        let brain = &mut self.brain;
        if !brain.feed_history.values().any(|e| e.last_shown >= cutoff) {
            return;
        }
        let Some(key) = stale_key(query, &brain.key_spec()) else {
            return;
        };
        let novel = video_ids
            .iter()
            .filter(|id| brain.feed_history.get(*id).is_none_or(|e| e.last_shown < cutoff))
            .count();
        #[allow(clippy::cast_precision_loss)]
        let ratio = novel as f64 / video_ids.len().max(1) as f64;
        note_query_novelty(&mut brain.stale_queries, key, video_ids.len(), ratio, now);
    }

    /// Flow's `select_related_seeds`: interests spread, seeds used in the last six hours resting.
    fn select_related_seeds(
        &mut self,
        candidates: &[SeedInput],
        max_seeds: usize,
        long_term: &[SeedInput],
    ) -> Vec<String> {
        if candidates.is_empty() && long_term.is_empty() {
            return Vec::new();
        }
        let now = now_ms();
        let selected = {
            let brain = &self.brain;
            let channel_cutoff = now.saturating_sub(CHANNEL_SUPPRESSION_DAYS * DAY_MS);
            let excluded: HashSet<String> = brain
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
            let cooldown_cutoff = now.saturating_sub(RELATED_SEED_COOLDOWN_MS);
            let cooled: HashSet<String> = brain
                .recent_related_seeds
                .iter()
                .filter(|(_, at)| **at > cooldown_cutoff)
                .map(|(id, _)| id.clone())
                .collect();
            let interests: HashMap<String, f64> =
                brain.interests().map(|(k, v)| (k.clone(), v)).collect();
            let spec = brain.key_spec();
            let is_watched = |channel: &str| is_watched_channel(brain, channel);
            let channel_edges = self.co_watch.edges(&is_watched, now);
            let clusters = build_clusters(&ClusterInputs {
                topic_scores: &interests,
                affinities: &brain.topic_affinities,
                channel_topic_profiles: &brain.channel_topic_profiles,
                channel_edges: &channel_edges,
                spec: &spec,
            });
            let seed_clusters = SeedClusters::new(&spec, &interests, &clusters);
            let hidden = &brain.suppressed_video_ids;
            let visible = |seeds: &[SeedInput]| -> Vec<SeedInput> {
                seeds.iter().filter(|s| !hidden.contains_key(&s.id)).cloned().collect()
            };
            select_with_long_term(
                &visible(candidates),
                max_seeds,
                &visible(long_term),
                &seed_clusters,
                now,
                &cooled,
                &excluded,
            )
        };
        if !selected.is_empty() {
            let brain = &mut self.brain;
            let cutoff = now.saturating_sub(RELATED_SEED_COOLDOWN_MS);
            brain.recent_related_seeds.retain(|_, at| *at >= cutoff);
            for id in &selected {
                brain.recent_related_seeds.insert(id.clone(), now);
            }
            if brain.recent_related_seeds.len() > RECENT_RELATED_SEEDS_MAX {
                let mut by_age: Vec<(String, u64)> = brain.recent_related_seeds.drain().collect();
                by_age.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
                brain.recent_related_seeds = by_age.into_iter().take(RECENT_RELATED_SEEDS_MAX).collect();
            }
            self.dirty = true;
        }
        selected
    }

    /// Flow's `neighbour_channels`.
    fn neighbour_channels(&self, followed: &HashMap<String, String>) -> Vec<Neighbour> {
        let now = now_ms();
        let brain = &self.brain;
        let suppression_cutoff = now.saturating_sub(CHANNEL_SUPPRESSION_DAYS * DAY_MS);
        let anchors: HashSet<String> = followed
            .keys()
            .cloned()
            .chain(
                brain
                    .channel_scores
                    .keys()
                    .filter(|channel| is_watched_channel(brain, channel))
                    .cloned(),
            )
            .collect();
        let excluded = |channel: &str| {
            brain.blocked_channels.contains(channel)
                || brain.suppressed_channels.get(channel).is_some_and(|at| *at > suppression_cutoff)
                || brain.channel_scores.get(channel).copied().unwrap_or(0.5) < 0.5
        };
        let mut names = self.co_watch.names();
        names.extend(followed.iter().map(|(id, name)| (id.clone(), name.clone())));
        neighbours::neighbours(&self.co_watch.sources(), &anchors, &excluded, &names, now)
    }

    fn recently_shown(&self) -> HashSet<String> {
        let now = now_ms();
        self.brain
            .feed_history
            .iter()
            .filter(|(_, e)| crate::flow_neuro::gates::is_recently_seen(Some(e), now))
            .map(|(id, _)| id.clone())
            .collect()
    }

    fn record_feed_impressions(&mut self, videos: &[VideoSummary]) {
        if videos.is_empty() || self.learning_paused {
            return;
        }
        let now = now_ms();
        let mut seen = HashSet::new();
        for video in videos.iter().filter(|v| seen.insert(v.id.clone())) {
            let entry = self.impression_cache.entry(video.id.clone()).or_insert((0, now));
            entry.0 += 1;
            entry.1 = now;
            let feed = self.brain.feed_history.entry(video.id.clone()).or_insert(FeedEntry {
                last_shown: now,
                show_count: 0,
            });
            feed.last_shown = now;
            feed.show_count += 1;
        }
        while self.impression_cache.len() > IMPRESSION_CACHE_MAX {
            let Some(oldest) = self
                .impression_cache
                .iter()
                .min_by_key(|(_, (_, at))| *at)
                .map(|(id, _)| id.clone())
            else {
                break;
            };
            self.impression_cache.remove(&oldest);
        }
        crate::flow_neuro::caps::prune_feed_history(&mut self.brain, now);
        self.dirty = true;
    }

    /// Reads what channels are about from upload titles already fetched, once per channel.
    fn observe_channel_uploads(&mut self, uploads: &[Card]) {
        if self.learning_paused {
            return;
        }
        let mut by_channel: HashMap<String, Vec<String>> = HashMap::new();
        for card in uploads {
            let channel = clean_channel(card.channel_id());
            if channel.is_empty() || self.profiled_channels.contains(channel) {
                continue;
            }
            by_channel.entry(channel.to_string()).or_default().push(card.video.title.clone());
        }
        if by_channel.is_empty() {
            return;
        }
        self.profiled_channels.extend(by_channel.keys().cloned());
        learn_from_uploads(&mut self.brain, &by_channel);
        self.dirty = true;
    }

    // ---------------------------------------------------------------- learning

    /// Flow's `log_video_interaction`.
    #[allow(clippy::too_many_arguments)]
    fn log_interaction(
        &mut self,
        video: &VideoSummary,
        description: Option<&str>,
        kind: InteractionType,
        percent_watched: f32,
    ) {
        if self.learning_paused {
            return;
        }
        let channel_id = clean_channel(video.channel_id.as_deref().unwrap_or(&video.id)).to_string();
        let now = now_ms();
        #[allow(clippy::cast_precision_loss)]
        let seconds_since_impression = self
            .impression_cache
            .get(&video.id)
            .map(|(_, shown)| now.saturating_sub(*shown) as f64 / 1000.0);
        let is_short = video.is_short || is_known_short(video.duration_seconds);
        let outcome = apply_interaction(
            &mut self.brain,
            &Interaction {
                video_id: &video.id,
                title: &video.title,
                channel_name: &video.channel_name,
                channel_id: &channel_id,
                description,
                duration_sec: video.duration_seconds,
                is_live: video.is_live,
                is_short,
                kind,
                percent_watched,
                seconds_since_impression,
                category: None,
            },
        );
        self.dirty = true;
        if matches!(kind, InteractionType::NotInterested | InteractionType::Disliked) {
            self.memory.record_rejection(&channel_id, now);
        }
        self.last_activity_ms = now;
        let learned = outcome.learning_rate.is_some_and(|rate| rate > 0.0);
        if learned && !is_short && is_strong_signal(kind, percent_watched) {
            self.co_watch.record_pending(&video.id, &channel_id, now);
        }
        if learned && description.is_some_and(|text| !text.trim().is_empty()) {
            #[allow(clippy::cast_possible_wrap)]
            self.content.put(&video.id, &outcome.topics, now as i64);
        }
        if let (Some(topic), Some(rate)) = (&outcome.primary_topic, outcome.learning_rate) {
            self.momentum.push(MomentumEntry { topic: topic.clone(), positive: rate > 0.0 });
            if self.momentum.len() > MOMENTUM_WINDOW {
                self.momentum.remove(0);
            }
        }
        if learned {
            self.impression_cache.remove(&video.id);
        }
        if outcome.learning_rate.is_some()
            && matches!(kind, InteractionType::Click | InteractionType::Watched)
            && let Some(topic) = outcome.primary_topic
        {
            self.session_topics.push(topic);
            if self.session_topics.len() > SESSION_TOPIC_HISTORY_MAX {
                self.session_topics.remove(0);
            }
            self.session_video_count += 1;
        }
    }

    fn video_of_report(&self, report: &WatchReport) -> VideoSummary {
        let duration = (report.duration > 0.0)
            .then(|| std::time::Duration::from_secs_f64(report.duration + 0.5).as_secs());
        VideoSummary {
            id: report.video_id.clone(),
            title: report.title.clone(),
            channel_name: report.channel_name.clone(),
            channel_id: Some(if report.channel_id.is_empty() {
                report.video_id.clone()
            } else {
                report.channel_id.clone()
            }),
            duration_seconds: duration,
            is_live: report.is_live,
            ..VideoSummary::default()
        }
    }

    fn watch_report(&self, report: ProgressReport) -> WatchReport {
        let details = self.details.get(&report.video_id).cloned().unwrap_or_default();
        let pick = |own: String, known: &str| if own.is_empty() { known.to_string() } else { own };
        WatchReport {
            title: pick(report.title, &details.title),
            channel_name: pick(report.channel_name, &details.channel_name),
            channel_id: pick(clean_channel(&report.channel_id).to_string(), &details.channel_id),
            description: details.description,
            is_live: report.is_live,
            is_music: false,
            category: None,
            position: report.position,
            duration: report.duration,
            played_delta: report.played_delta,
            video_id: report.video_id,
        }
    }

    /// Flow's `report_watch_progress`: a report for another video finishes the previous session.
    pub fn watch_progress(&mut self, report: ProgressReport) {
        if self.learning_paused || report.video_id.is_empty() {
            return;
        }
        let report = self.watch_report(report);
        let finished = match self.watch.session.as_mut() {
            Some(session) if session.report.video_id == report.video_id => {
                session.ended = false;
                session.absorb(report);
                None
            }
            _ => {
                self.watch.generation += 1;
                let session = WatchSession::start(report, self.watch.generation);
                self.watch.session.replace(session)
            }
        };
        let click = self
            .watch
            .session
            .as_mut()
            .and_then(|s| s.take_click().then(|| s.report.clone()));
        if let Some(previous) = finished {
            self.finish_watch(previous);
        }
        if let Some(report) = click {
            let video = self.video_of_report(&report);
            self.log_interaction(&video, report.description.as_deref(), InteractionType::Click, 0.0);
        }
    }

    /// Ends whatever session is open (the player closed, the app went to the background).
    pub fn watch_end(&mut self) {
        if let Some(session) = self.watch.session.take() {
            self.finish_watch(session);
        }
    }

    fn finish_watch(&mut self, mut session: WatchSession) {
        if session.report.title.trim().is_empty() {
            // The details may have arrived after the last report.
            if let Some(details) = self.details.get(&session.report.video_id).cloned() {
                session.absorb(WatchReport {
                    title: details.title,
                    channel_name: details.channel_name,
                    channel_id: details.channel_id,
                    description: details.description,
                    played_delta: 0.0,
                    ..session.report.clone()
                });
            }
        }
        if session.report.title.trim().is_empty() {
            return;
        }
        let report = session.report.clone();
        let video = self.video_of_report(&report);
        if session.take_click() {
            self.log_interaction(&video, report.description.as_deref(), InteractionType::Click, 0.0);
        }
        let percent = session.percent_watched();
        if let Some(verdict) = session.verdict() {
            self.log_interaction(
                &video,
                report.description.as_deref(),
                verdict.interaction,
                verdict.percent_watched,
            );
        }
        // Flow's watch history, which seeds the related lane and channel memory.
        if !video.is_live && video.duration_seconds.is_some_and(|d| d > 0) {
            let duration = video.duration_seconds.unwrap_or(0);
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss, clippy::cast_precision_loss)]
            let watched = (f64::from(percent) * duration as f64).round() as u64;
            if watched >= 5 {
                self.library.add_history(HistoryRecord {
                    video_id: video.id.clone(),
                    title: video.title.clone(),
                    channel_id: Some(report.channel_id.clone()).filter(|c| !c.is_empty()),
                    channel_name: video.channel_name.clone(),
                    watched_at_ms: now_ms(),
                    watch_seconds: watched,
                    duration_seconds: video.duration_seconds,
                });
                self.dirty = true;
            }
        }
    }

    /// The watch page of a video being watched: its details fill the session, and its related
    /// list waits to become a co-watch source if the viewer watches or likes the video.
    pub fn watch_page(&mut self, video_id: &str, body: &str) {
        let Ok(next) = serde_json::from_str::<Value>(body) else {
            return;
        };
        let details = watch_details(&next, video_id);
        let now = now_ms();
        let related: Vec<Card> = details
            .related
            .iter()
            .cloned()
            .map(|v| Card::from_summary(v, now))
            .collect();
        self.co_watch.note_related(
            video_id,
            related
                .iter()
                .filter(|c| !c.channel_id().is_empty())
                .map(|c| RelatedChannel {
                    channel_id: c.channel_id().to_string(),
                    channel_name: c.video.channel_name.clone(),
                })
                .collect(),
        );
        if !related.is_empty() {
            self.related_cache.insert(video_id.to_string(), (now, related));
        }
        if self.details.len() >= DETAILS_CACHE_MAX && !self.details.contains_key(video_id) {
            self.details.clear();
        }
        // A later page fills what an earlier one lacked and never blanks what it had.
        let known = self.details.remove(video_id).unwrap_or_default();
        let pick = |new: String, old: String| if new.trim().is_empty() { old } else { new };
        self.details.insert(
            video_id.to_string(),
            Details {
                title: pick(details.title, known.title),
                channel_name: pick(details.channel_name, known.channel_name),
                channel_id: pick(details.channel_id, known.channel_id),
                description: details.description.or(known.description),
            },
        );
        // A session already open for this video takes the details now.
        if let Some(session) = self.watch.session.as_mut()
            && session.report.video_id == video_id
        {
            let report = WatchReport { played_delta: 0.0, ..session.report.clone() };
            let filled = {
                let d = &self.details[video_id];
                WatchReport {
                    title: d.title.clone(),
                    channel_name: d.channel_name.clone(),
                    channel_id: d.channel_id.clone(),
                    description: d.description.clone(),
                    ..report
                }
            };
            session.absorb(filled);
        }
    }

    /// Request for the watch page of `video_id`, which the host sends when a video starts.
    #[must_use]
    pub fn watch_page_request(&self, video_id: &str) -> RequestSpec {
        watch_next_request(format!("watch:{video_id}"), video_id, &self.region)
    }

    fn video_for(&self, video_id: &str, given: Option<VideoSummary>) -> VideoSummary {
        let mut video = given.unwrap_or_else(|| VideoSummary { id: video_id.to_string(), ..VideoSummary::default() });
        if let Some(d) = self.details.get(video_id) {
            if video.title.is_empty() {
                video.title.clone_from(&d.title);
            }
            if video.channel_name.is_empty() {
                video.channel_name.clone_from(&d.channel_name);
            }
            if video.channel_id.as_deref().is_none_or(str::is_empty) && !d.channel_id.is_empty() {
                video.channel_id = Some(d.channel_id.clone());
            }
        }
        if video.duration_seconds.is_none()
            && let Some(session) = &self.watch.session
            && session.report.video_id == video_id
            && session.report.duration > 0.0
        {
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            {
                video.duration_seconds = Some(session.report.duration.round() as u64);
            }
        }
        video
    }

    /// A like, dislike, "not interested", save or their removal, from YouTube's buttons or the
    /// Flow feed. Returns whether it taught anything.
    pub fn feedback(&mut self, video_id: &str, action: &str, given: Option<VideoSummary>) -> bool {
        let video = self.video_for(video_id, given);
        let description = self.details.get(video_id).and_then(|d| d.description.clone());
        let now = now_ms();
        let kind = match action {
            "like" => InteractionType::Liked,
            "dislike" => InteractionType::Disliked,
            "notInterested" => InteractionType::NotInterested,
            "save" => InteractionType::Saved,
            "unlike" => {
                self.library.set_liked(video, false, now);
                self.dirty = true;
                return false;
            }
            "dismiss" => {
                self.library.dismiss(video_id);
                self.dirty = true;
                return false;
            }
            _ => return false,
        };
        if video.title.trim().is_empty() {
            // Nothing to learn from yet; a like still seeds the related lane once titled.
            return false;
        }
        if kind == InteractionType::Liked {
            self.library.set_liked(video.clone(), true, now);
        }
        if kind == InteractionType::NotInterested {
            self.library.dismiss(video_id);
        }
        self.log_interaction(&video, description.as_deref(), kind, 0.0);
        true
    }

    /// A subscribe or unsubscribe, from YouTube's button or an import.
    pub fn subscription(&mut self, channel_id: &str, name: &str, avatar: Option<String>, subscribed: bool) {
        let channel_id = clean_channel(channel_id);
        if channel_id.is_empty() {
            return;
        }
        self.library.set_subscribed(
            Subscription { id: channel_id.to_string(), name: name.to_string(), avatar_url: avatar },
            subscribed,
        );
        if !subscribed {
            self.subscription_uploads.remove(channel_id);
        }
        if !self.learning_paused {
            subscription_changed(&mut self.brain, channel_id, name, subscribed);
        }
        self.dirty = true;
    }

    /// Learns from a typed search.
    pub fn searched(&mut self, query: &str) -> bool {
        if self.learning_paused {
            return false;
        }
        self.dirty = true;
        learn_search(&mut self.brain, query, now_ms())
    }

    /// Imports subscriptions in bulk (Google Takeout, NewPipe), and seeds the brain from them.
    pub fn import_subscriptions(&mut self, channels: Vec<Subscription>) -> usize {
        let mut names = Vec::new();
        let mut added = 0;
        for channel in channels {
            let id = clean_channel(&channel.id).to_string();
            if id.is_empty() {
                continue;
            }
            if !self.library.subscriptions.iter().any(|s| s.id == id) {
                added += 1;
            }
            if !channel.name.is_empty() {
                names.push(channel.name.clone());
            }
            self.library.set_subscribed(Subscription { id, ..channel }, true);
        }
        if !names.is_empty() {
            bootstrap_from_subscriptions(&mut self.brain, &names);
        }
        self.dirty = true;
        added
    }

    /// Imports watch history (Google Takeout), seeding the brain and the related lane.
    pub fn import_history(&mut self, videos: Vec<ImportedVideo>) -> usize {
        for video in videos.iter().take(200).rev() {
            self.library.add_history(HistoryRecord {
                video_id: video.video_id.clone(),
                title: video.title.clone(),
                channel_id: video.channel_id.clone(),
                channel_name: video.channel_name.clone(),
                watched_at_ms: u64::try_from(video.watched_at).unwrap_or(0),
                // A history entry says it was opened, not how long; count it as watched in full
                // only for seeding purposes is too strong, so a third is recorded.
                watch_seconds: video.duration_seconds.unwrap_or(600) / 3,
                duration_seconds: video.duration_seconds,
            });
        }
        self.library.history.sort_by_key(|r| std::cmp::Reverse(r.watched_at_ms));
        let learned = bootstrap_from_history(&mut self.brain, videos);
        self.dirty = true;
        learned
    }

    /// Onboarding: topics the viewer picked as interests (Flow's `complete_onboarding`).
    pub fn choose_topics(&mut self, topics: &[String]) {
        let mut preferred = self.brain.preferred_topics.clone();
        for (index, topic) in topics.iter().enumerate() {
            let trimmed = topic.trim();
            if trimmed.is_empty() {
                continue;
            }
            let weight = match index {
                0..=2 => 0.55,
                3..=5 => 0.40,
                _ => 0.30,
            };
            for token in self.brain.key_spec().keys_of(trimmed) {
                let current = self.brain.global_vector.topics.get(&token).copied().unwrap_or(0.0);
                self.brain.global_vector.topics.insert(token, current.max(weight));
            }
            preferred.insert(trimmed.to_string());
        }
        self.brain.display_forms = with_pick_spellings(&self.brain.display_forms, &preferred, &self.brain.key_spec());
        self.brain.preferred_topics = preferred;
        self.brain.has_completed_onboarding = true;
        self.dirty = true;
    }

    /// Hides a topic for good (Flow's `add_blocked_topic`).
    pub fn block_topic(&mut self, topic: &str) {
        let normalized = topic.trim().to_lowercase();
        if normalized.is_empty() {
            return;
        }
        let lemma = self.brain.key_spec().key_of(&normalized);
        let brain = &mut self.brain;
        brain.blocked_topics.insert(normalized.clone());
        brain.preferred_topics.retain(|p| p.to_lowercase() != normalized);
        let keep = |key: &String| {
            let lower = key.to_lowercase();
            !lower.contains(&lemma) && !lower.contains(&normalized)
        };
        brain.global_vector.topics.retain(|k, _| keep(k));
        for vector in brain
            .time_vectors
            .values_mut()
            .chain([&mut brain.recent_vector, &mut brain.shorts_vector])
        {
            vector.topics.retain(|k, _| keep(k));
        }
        self.dirty = true;
    }

    /// Never shows a channel again (Flow's `block_channel`).
    pub fn block_channel(&mut self, channel_id: &str) {
        let channel_id = clean_channel(channel_id).to_string();
        if channel_id.is_empty() {
            return;
        }
        let brain = &mut self.brain;
        brain.blocked_channels.insert(channel_id.clone());
        brain.channel_scores.remove(&channel_id);
        brain.suppressed_channels.remove(&channel_id);
        brain.channel_strikes.remove(&channel_id);
        self.dirty = true;
    }

    pub fn set_learning_paused(&mut self, paused: bool) {
        self.learning_paused = paused;
        self.dirty = true;
    }

    #[must_use]
    pub fn stats(&self) -> Stats {
        let mut topics: Vec<(String, f64)> = self.brain.interests().map(|(k, v)| (k.clone(), v)).collect();
        topics.sort_by(|a, b| b.1.total_cmp(&a.1));
        let display = |key: &str| crate::flow_neuro::display_forms::label(&self.brain.display_forms, key);
        Stats {
            total_interactions: self.brain.total_interactions,
            persona: format!("{:?}", classify_persona(&self.brain)),
            top_topics: topics.iter().take(12).map(|(k, _)| display(k)).collect(),
            watched_videos: self.library.history.len(),
            liked_videos: self.library.likes.len(),
            subscriptions: self.library.subscriptions.len(),
            learning_paused: self.learning_paused,
        }
    }

    /// The subscriptions known locally, for the settings screen and exports.
    #[must_use]
    pub fn subscriptions(&self) -> &[Subscription] {
        &self.library.subscriptions
    }

    // ---------------------------------------------------------------- Home

    /// What one Home load fetches. `more` digs one level deeper for the next page; otherwise
    /// the discovery tree starts again at its roots, like Flow's refresh.
    pub fn plan_home(&mut self, more: bool) -> Plan {
        self.reset_idle_session();
        let now = now_ms();
        let id = self.next_load_id;
        self.next_load_id += 1;
        let mut wants = HashMap::new();
        let mut requests = Vec::new();
        let region = self.region.clone();
        let mut add = |key: String, want: Want, spec: RequestSpec| {
            wants.insert(key, want);
            requests.push(spec);
        };

        let queries: Vec<String> = self
            .discovery_queries(!more)
            .into_iter()
            .take(if more { MORE_SEARCHES } else { FIRST_SEARCHES })
            .collect();
        for (i, query) in queries.iter().enumerate() {
            let key = format!("s{i}");
            add(key.clone(), Want::Search(query.clone()), search_request(key, query, &region));
        }

        let inputs = Inputs::load(&self.library, &self.brain, now);
        let disliked = inputs.exclusions.hidden_videos().clone();
        let recent = inputs.recent_seeds(&disliked);
        let long_term = inputs.long_term_seeds(&disliked);
        let seed_ids = self.select_related_seeds(
            &recent,
            if more { MORE_RELATED_SEEDS } else { MAX_RELATED_SEEDS },
            &long_term,
        );
        self.related_cache.retain(|_, (at, _)| now.saturating_sub(*at) < RELATED_CACHE_MS);
        for seed in &seed_ids {
            if !self.related_cache.contains_key(seed) {
                let key = format!("r:{seed}");
                add(key.clone(), Want::Related(seed.clone()), watch_next_request(key, seed, &region));
            }
        }

        if !more {
            // Followed channels whose uploads are oldest, a few per load (Flow's top-up).
            let mut followed: Vec<(&Subscription, u64)> = self
                .library
                .subscriptions
                .iter()
                .map(|s| (s, self.subscription_uploads.get(&s.id).map_or(0, |u| u.fetched_at)))
                .filter(|(_, at)| now.saturating_sub(*at) >= SUB_REFRESH_MS)
                .collect();
            followed.sort_by_key(|(s, at)| (*at, s.id.clone()));
            for (sub, _) in followed.into_iter().take(SUB_FETCHES_PER_LOAD) {
                let key = format!("c:{}", sub.id);
                add(
                    key.clone(),
                    Want::Subscription(sub.id.clone(), sub.name.clone()),
                    channel_videos_request(key, &sub.id, &region),
                );
            }
            let followed_ids = inputs.subscriptions.ids();
            let remembered = channel_memory::remembered(
                &inputs.watches(),
                &inputs.liked_channels(),
                &self.memory,
                &followed_ids,
                &self.brain.blocked_channels,
                &self.brain.suppressed_channels,
                now,
            );
            for r in channel_memory::refresh_queue(&remembered, &self.memory.entries, now)
                .into_iter()
                .take(MEMORY_FETCHES_PER_LOAD)
            {
                let key = format!("m:{}", r.channel_id);
                add(
                    key.clone(),
                    Want::Memory(r.channel_id.clone(), r.name.clone()),
                    channel_videos_request(key, &r.channel_id, &region),
                );
            }
            let neighbour_list: Vec<Neighbour> = self
                .neighbour_channels(&inputs.subscriptions.names)
                .into_iter()
                .filter(|n| !self.neighbour_store.get(&n.channel_id).is_some_and(|s| s.dropped))
                .collect();
            for n in neighbours::refresh_queue(&neighbour_list, &self.neighbour_store, now) {
                let key = format!("n:{}", n.channel_id);
                add(
                    key.clone(),
                    Want::Neighbour(n.channel_id.clone(), n.name.clone()),
                    channel_videos_request(key, &n.channel_id, &region),
                );
            }
        }

        let seeds: Vec<SeedInput> = recent.into_iter().chain(long_term).collect();
        let kind = if more { LoadKind::More } else { LoadKind::Home };
        self.pending = Some(PendingLoad { id, kind, wants, queries, seeds, seed_ids });
        Plan { load_id: id, requests }
    }

    /// Builds the page from a plan's answers. Answers that failed or are missing are skipped.
    pub fn assemble(&mut self, load_id: u64, answers: Vec<Answer>) -> Page {
        let Some(pending) = self.pending.take().filter(|p| p.id == load_id) else {
            return Page { items: Vec::new(), offline: false, cold_start: false };
        };
        let now = now_ms();
        let answered = answers.iter().filter(|a| (200..300).contains(&a.status)).count();
        let mut searches: Vec<(String, Vec<Card>)> = Vec::new();
        let mut uploads_seen: Vec<Card> = Vec::new();
        let mut fresh_neighbours: HashSet<String> = HashSet::new();
        let by_id: HashMap<&str, &Answer> = answers.iter().map(|a| (a.id.as_str(), a)).collect();
        for query in &pending.queries {
            let key = pending
                .wants
                .iter()
                .find(|(_, w)| matches!(w, Want::Search(q) if q == query))
                .map(|(k, _)| k.clone());
            let cards = key
                .and_then(|k| by_id.get(k.as_str()).copied())
                .filter(|a| (200..300).contains(&a.status))
                .and_then(|a| serde_json::from_str::<Value>(&a.body).ok())
                .map(|v| videos_in(&v).into_iter().map(|v| Card::from_summary(v, now)).collect())
                .unwrap_or_default();
            searches.push((query.clone(), cards));
        }
        for (key, want) in &pending.wants {
            let Some(answer) = by_id.get(key.as_str()).filter(|a| (200..300).contains(&a.status)) else {
                continue;
            };
            let Ok(value) = serde_json::from_str::<Value>(&answer.body) else {
                continue;
            };
            match want {
                Want::Search(_) => {}
                Want::Related(seed) => {
                    let related: Vec<Card> = watch_details(&value, seed)
                        .related
                        .into_iter()
                        .map(|v| Card::from_summary(v, now))
                        .collect();
                    self.related_cache.insert(seed.clone(), (now, related));
                }
                Want::Subscription(channel, name) => {
                    let mut cards: Vec<Card> = channel_videos(&value, channel, name)
                        .into_iter()
                        .map(|v| Card::from_summary(v, now))
                        .filter(|c| !c.is_short())
                        .collect();
                    uploads_seen.extend(cards.iter().cloned());
                    cards.sort_by_key(|c| std::cmp::Reverse(c.published_at_ms));
                    cards.truncate(SUB_UPLOADS_KEPT);
                    // A subscription copied from the account or a file may have come without a name.
                    if let Some(found) = crate::youtube::channel_name_of(&value) {
                        for sub in self.library.subscriptions.iter_mut().filter(|s| &s.id == channel && s.name.is_empty()) {
                            sub.name.clone_from(&found);
                        }
                    }
                    self.subscription_uploads
                        .insert(channel.clone(), ChannelUploads { fetched_at: now, uploads: cards });
                }
                Want::Memory(channel, name) => {
                    let cards: Vec<Card> = channel_videos(&value, channel, name)
                        .into_iter()
                        .map(|v| Card::from_summary(v, now))
                        .collect();
                    uploads_seen.extend(cards.iter().cloned());
                    self.memory.save_uploads(channel, channel_memory::keep_uploads(cards, now), now);
                }
                Want::Neighbour(channel, name) => {
                    let mut cards: Vec<Card> = channel_videos(&value, channel, name)
                        .into_iter()
                        .map(|v| Card::from_summary(v, now))
                        .filter(|c| c.is_valid())
                        .filter(|c| c.age_ms(now).is_some_and(|age| age <= neighbours::UPLOAD_WINDOW_MS))
                        .collect();
                    cards.sort_by_key(|c| std::cmp::Reverse(c.published_at_ms));
                    cards.truncate(neighbours::UPLOADS_PER_CHANNEL);
                    fresh_neighbours.insert(channel.clone());
                    neighbours::save_uploads(&mut self.neighbour_store, channel, cards, now);
                }
            }
        }
        self.dirty = true;
        self.observe_channel_uploads(&uploads_seen);
        for (query, cards) in &searches {
            let ids: Vec<String> = cards.iter().map(|c| c.id().to_string()).collect();
            if !ids.is_empty() {
                self.report_discovery_results(query, &ids);
            }
        }

        // The related graph, and co-watch from the lists beside videos the viewer took to.
        let seed_by_id: HashMap<&str, &SeedInput> = pending
            .seeds
            .iter()
            .filter(|s| pending.seed_ids.contains(&s.id))
            .fold(HashMap::new(), |mut map, seed| {
                if map.get(seed.id.as_str()).is_none_or(|s: &&SeedInput| seed.score(now) > s.score(now)) {
                    map.insert(seed.id.as_str(), seed);
                }
                map
            });
        let mut graph = Vec::new();
        for seed_id in &pending.seed_ids {
            let cards = self.related_cache.get(seed_id).map(|(_, c)| c.clone()).unwrap_or_default();
            let seed = seed_by_id.get(seed_id.as_str());
            if let Some(seed) = seed
                && matches!(seed.source, SeedSource::WatchHistory | SeedSource::Liked)
                && !cards.is_empty()
                && !seed.channel_id.is_empty()
                && !self.learning_paused
            {
                let related: Vec<RelatedChannel> = cards
                    .iter()
                    .filter(|c| !c.channel_id().is_empty())
                    .map(|c| RelatedChannel {
                        channel_id: c.channel_id().to_string(),
                        channel_name: c.video.channel_name.clone(),
                    })
                    .collect();
                self.co_watch.record(&seed.id, &seed.channel_id, &related, now);
            }
            let seed_score = seed.map_or(0.0, |s| s.score(now));
            let count = cards.len();
            graph.extend(cards.into_iter().enumerate().map(|(rank, card)| GraphCandidate {
                card,
                seed_id: seed_id.clone(),
                seed_score,
                graph_rank: rank,
                seed_result_count: count,
                hit_count: 1,
            }));
        }
        let graph = merge_candidates(graph);
        let seed_titles: HashMap<String, String> = {
            let titles: HashMap<&str, &str> =
                pending.seeds.iter().map(|s| (s.id.as_str(), s.title.as_str())).collect();
            graph
                .iter()
                .filter_map(|c| {
                    let title = titles.get(c.seed_id.as_str()).filter(|t| !t.is_empty())?;
                    Some((c.card.id().to_string(), (*title).to_string()))
                })
                .collect()
        };

        let offline = answered == 0 && !pending.wants.is_empty();
        let page = match pending.kind {
            LoadKind::More => self.assemble_more(searches, graph, seed_titles, now),
            LoadKind::Home => self.assemble_first(searches, graph, seed_titles, &fresh_neighbours, now),
            LoadKind::Subscriptions => self.subscriptions_page(now),
        };
        let cold_start = self.brain.total_interactions == 0 && self.library.subscriptions.is_empty();
        // A subscriptions page with stored uploads is not offline even if its refreshes failed.
        let offline = offline && pending.kind != LoadKind::More && page.is_empty();
        Page { items: page, offline, cold_start }
    }

    /// The Subscriptions page: refreshes the followed channels whose uploads are oldest, then
    /// lists every followed channel's uploads newest first, as Flow's Subscriptions tab does.
    pub fn plan_subscriptions(&mut self) -> Plan {
        let now = now_ms();
        let id = self.next_load_id;
        self.next_load_id += 1;
        let mut followed: Vec<(&Subscription, u64)> = self
            .library
            .subscriptions
            .iter()
            .map(|s| (s, self.subscription_uploads.get(&s.id).map_or(0, |u| u.fetched_at)))
            .filter(|(_, at)| now.saturating_sub(*at) >= SUB_REFRESH_MS)
            .collect();
        followed.sort_by_key(|(s, at)| (*at, s.id.clone()));
        let mut wants = HashMap::new();
        let mut requests = Vec::new();
        for (sub, _) in followed.into_iter().take(SUBS_PAGE_FETCHES) {
            let key = format!("c:{}", sub.id);
            requests.push(channel_videos_request(key.clone(), &sub.id, &self.region));
            wants.insert(key, Want::Subscription(sub.id.clone(), sub.name.clone()));
        }
        self.pending = Some(PendingLoad {
            id,
            kind: LoadKind::Subscriptions,
            wants,
            queries: Vec::new(),
            seeds: Vec::new(),
            seed_ids: Vec::new(),
        });
        Plan { load_id: id, requests }
    }

    fn subscriptions_page(&self, now: u64) -> Vec<FeedItem> {
        let followed: HashSet<&str> = self.library.subscriptions.iter().map(|s| s.id.as_str()).collect();
        let hidden: HashSet<&str> = self.library.dismissed.iter().map(String::as_str).collect();
        let mut seen = HashSet::new();
        let mut cards: Vec<&Card> = self
            .subscription_uploads
            .iter()
            .filter(|(id, _)| followed.contains(id.as_str()))
            .flat_map(|(_, u)| u.uploads.iter())
            .filter(|c| !c.is_short() && !hidden.contains(c.id()) && seen.insert(c.id().to_string()))
            .collect();
        // Newest first; uploads without a readable age go last.
        cards.sort_by_key(|c| std::cmp::Reverse(if c.published_at_ms > 0 && c.published_at_ms <= now { c.published_at_ms } else { 0 }));
        cards
            .into_iter()
            .take(SUBS_PAGE_SIZE)
            .map(|c| FeedItem { video: c.video.clone(), reason: String::new(), source: "subscription".into() })
            .collect()
    }

    #[must_use]
    pub fn is_subscribed(&self, channel_id: &str) -> bool {
        let channel_id = clean_channel(channel_id);
        self.library.subscriptions.iter().any(|s| s.id == channel_id)
    }

    /// A local list for the Library screens: "subscriptions", "likes" or "history".
    #[must_use]
    pub fn library_list(&self, kind: &str) -> Value {
        match kind {
            "subscriptions" => {
                let mut subs = self.library.subscriptions.clone();
                subs.sort_by_key(|s| s.name.to_lowercase());
                serde_json::to_value(subs).unwrap_or(Value::Null)
            }
            "likes" => Value::Array(
                self.library
                    .likes
                    .iter()
                    .map(|(video, at)| {
                        let mut v = serde_json::to_value(video).unwrap_or(Value::Null);
                        v["at"] = Value::from(*at);
                        v
                    })
                    .collect(),
            ),
            "history" => serde_json::to_value(&self.library.history).unwrap_or(Value::Null),
            _ => Value::Null,
        }
    }

    fn assemble_first(
        &mut self,
        searches: Vec<(String, Vec<Card>)>,
        graph: Vec<GraphCandidate>,
        seed_titles: HashMap<String, String>,
        fresh_neighbours: &HashSet<String>,
        now: u64,
    ) -> Vec<FeedItem> {
        let inputs = Inputs::load(&self.library, &self.brain, now);
        let followed = inputs.subscriptions.ids();
        let store: Vec<Card> = self
            .subscription_uploads
            .iter()
            .filter(|(id, _)| followed.contains(*id))
            .flat_map(|(_, u)| u.uploads.iter().cloned())
            .collect();
        let remembered = channel_memory::remembered(
            &inputs.watches(),
            &inputs.liked_channels(),
            &self.memory,
            &followed,
            &self.brain.blocked_channels,
            &self.brain.suppressed_channels,
            now,
        );
        let raw_memory = channel_memory::uploads(&remembered, &self.memory.entries, now);
        let neighbour_list: Vec<Neighbour> = self
            .neighbour_channels(&inputs.subscriptions.names)
            .into_iter()
            .filter(|n| !self.neighbour_store.get(&n.channel_id).is_some_and(|s| s.dropped))
            .collect();
        let raw_neighbours: Vec<Card> = neighbour_list
            .iter()
            .filter_map(|n| self.neighbour_store.get(&n.channel_id))
            .flat_map(|s| s.uploads.iter())
            .filter(|c| c.age_ms(now).is_some_and(|age| age <= neighbours::UPLOAD_WINDOW_MS))
            .cloned()
            .collect();
        let neighbour_channels_with_uploads: HashSet<String> =
            raw_neighbours.iter().map(|c| c.channel_id().to_string()).collect();

        let taste = TasteProfile::of(&self.brain, &classify_persona(&self.brain));
        let recently_shown = self.recently_shown();
        let query_of = queries_by_id(&searches);
        let built = lanes::build(
            self,
            Raw::new(&store, &searches, raw_memory, graph, raw_neighbours, now),
            &inputs,
            &recently_shown,
            &taste,
            now,
        );
        let on_screen: HashSet<String> = self.on_screen.iter().cloned().collect();
        let mix = lanes::assemble(&built, &on_screen, followed.len(), self.brain.total_interactions);
        let source_of = mix.source_of.clone();
        let laid_out = space_by_channel(
            rhythm_by_source(
                mix.cards.clone(),
                &|c| followed.contains(c.channel_id()),
                &|c| source_of.get(c.id()).copied(),
                mix.fresh_added,
                true,
                FIRST_PAGE_MIN_SIZE,
            ),
            CHANNEL_GAP,
            &[],
        );
        let related_picks: HashSet<String> = source_of
            .iter()
            .filter(|(_, s)| **s == FeedSource::Related)
            .map(|(id, _)| id.clone())
            .collect();
        let pointers: HashMap<String, String> = neighbour_list
            .iter()
            .filter(|n| !n.pointer_names.is_empty())
            .map(|n| (n.channel_id.clone(), n.pointer_names.iter().take(2).cloned().collect::<Vec<_>>().join("|")))
            .collect();
        let origins = Provenance {
            source_of: source_of.clone(),
            seed_titles: seed_titles.into_iter().filter(|(id, _)| related_picks.contains(id)).collect(),
            queries: query_of,
            followed: Some(&followed),
            neighbour_pointers: pointers,
        }
        .origins(&laid_out);

        // Neighbours: count showings, and drop those none of whose fetched uploads fit.
        let shown_neighbours: HashSet<String> = laid_out
            .iter()
            .filter(|c| source_of.get(c.id()) == Some(&FeedSource::Neighbours))
            .map(|c| c.channel_id().to_string())
            .collect();
        neighbours::note_shown(&mut self.neighbour_store, &shown_neighbours);
        let off_topic: HashSet<String> = neighbour_channels_with_uploads
            .difference(&built.relevant_neighbour_channels)
            .filter(|c| fresh_neighbours.contains(*c))
            .cloned()
            .collect();
        neighbours::drop_off_topic(&mut self.neighbour_store, &off_topic);

        // What the page did not use waits for load-more.
        let rendered: HashSet<&str> = laid_out.iter().map(Card::id).collect();
        self.reserve = built
            .best_related
            .iter()
            .chain(&built.best_discovery)
            .chain(&mix.subs_backlog)
            .filter(|c| !rendered.contains(c.id()))
            .cloned()
            .take(RESERVE_MAX)
            .collect();

        let videos: Vec<VideoSummary> = laid_out.iter().map(|c| c.video.clone()).collect();
        self.record_feed_impressions(&videos);
        self.on_screen = laid_out.iter().map(|c| c.id().to_string()).collect();
        self.on_screen_channels = laid_out.iter().map(|c| c.channel_id().to_string()).collect();
        laid_out
            .into_iter()
            .map(|card| {
                let origin = origins.get(card.id()).cloned();
                let source = source_of.get(card.id()).copied();
                to_item(card, origin.as_ref(), source)
            })
            .collect()
    }

    /// Load-more: the reserve the first page left, new searches one level deeper and the related
    /// lists of a couple more seeds, ranked together and spaced (Flow's `more.rs`, simplified).
    fn assemble_more(
        &mut self,
        searches: Vec<(String, Vec<Card>)>,
        graph: Vec<GraphCandidate>,
        seed_titles: HashMap<String, String>,
        now: u64,
    ) -> Vec<FeedItem> {
        let inputs = Inputs::load(&self.library, &self.brain, now);
        let followed = inputs.subscriptions.ids();
        let on_screen: HashSet<String> = self.on_screen.iter().cloned().collect();
        let hidden = |card: &Card| inputs.exclusions.hides(card);
        let query_of = queries_by_id(&searches);
        let mut seen = HashSet::new();
        let pool: Vec<Card> = keep_showable(
            std::mem::take(&mut self.reserve)
                .into_iter()
                .chain(graph.into_iter().map(|g| g.card))
                .chain(searches.into_iter().flat_map(|(_, cards)| cards)),
            &inputs.watched,
            &hidden,
            now,
            true,
        )
        .filter(|c| !on_screen.contains(c.id()) && seen.insert(c.id().to_string()))
        .collect();
        let published: HashMap<String, u64> =
            pool.iter().map(|c| (c.id().to_string(), c.published_at_ms)).collect();
        let ranked = self.rank_candidates(pool.into_iter().map(|c| c.video).collect(), &followed, 0.0);
        let shared = self.share_by_interest(ranked, &followed);
        let cards: Vec<Card> = shared
            .into_iter()
            .map(|video| Card { published_at_ms: published.get(&video.id).copied().unwrap_or(0), video })
            .collect();
        let recent: Vec<String> = self
            .on_screen_channels
            .iter()
            .rev()
            .take(RECENT_CHANNEL_WINDOW)
            .rev()
            .cloned()
            .collect();
        let mut page: Vec<Card> = cards.iter().take(MORE_PAGE_SIZE).cloned().collect();
        self.reserve = cards.into_iter().skip(MORE_PAGE_SIZE).take(RESERVE_MAX).collect();
        page = space_by_channel(page, CHANNEL_GAP, &recent);
        let videos: Vec<VideoSummary> = page.iter().map(|c| c.video.clone()).collect();
        self.record_feed_impressions(&videos);
        self.on_screen.extend(page.iter().map(|c| c.id().to_string()));
        self.on_screen_channels.extend(page.iter().map(|c| c.channel_id().to_string()));
        page.into_iter()
            .map(|card| {
                let origin = if let Some(title) = seed_titles.get(card.id()) {
                    Some(Origin::new(OriginKind::Related, Some(title.clone())))
                } else if let Some(query) = query_of.get(card.id()) {
                    Some(Origin::new(OriginKind::Search, Some(query.clone())))
                } else if followed.contains(card.channel_id()) {
                    Some(Origin::new(OriginKind::Subscription, None))
                } else {
                    None
                };
                to_item(card, origin.as_ref(), None)
            })
            .collect()
    }

}

/// Flow's "Why you see this" line (`lib/homeOrigin.ts`).
fn reason(origin: Option<&Origin>) -> String {
    let Some(origin) = origin else {
        return String::new();
    };
    let detail = origin.detail.as_deref().map(str::trim).filter(|d| !d.is_empty());
    match origin.kind {
        OriginKind::Subscription => "From a channel you follow".into(),
        OriginKind::Related => match detail {
            Some(title) => format!("Related to {title}"),
            None => "Related to a video you watched".into(),
        },
        OriginKind::Search => match detail {
            Some(query) => format!("From a search for {query}"),
            None => "From a search for your interests".into(),
        },
        OriginKind::ChannelMemory => "From a channel you often watch".into(),
        OriginKind::Neighbour => {
            let names: Vec<&str> = detail.unwrap_or("").split('|').filter(|n| !n.is_empty()).collect();
            match names.as_slice() {
                [] => "A channel like the ones you follow".into(),
                [one] => format!("A channel like {one}"),
                [a, b, ..] => format!("A channel like {a} and {b}"),
            }
        }
    }
}

fn to_item(card: Card, origin: Option<&Origin>, source: Option<FeedSource>) -> FeedItem {
    let source = match origin.map(|o| o.kind) {
        Some(OriginKind::Subscription) => "subscription",
        Some(OriginKind::Related) => "related",
        Some(OriginKind::Search) => "search",
        Some(OriginKind::ChannelMemory) => "channelMemory",
        Some(OriginKind::Neighbour) => "neighbour",
        None => match source {
            Some(FeedSource::Subs) => "subscription",
            _ => "",
        },
    };
    FeedItem { reason: reason(origin), source: source.into(), video: card.video }
}

#[cfg(test)]
mod tests;
