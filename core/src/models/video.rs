//! Flow Desktop's feed card models (`models/video.rs`), the parts the feed and ranker read.
use serde::{Deserialize, Serialize};


#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoSummary {
    pub id: String,
    pub title: String,
    pub channel_name: String,
    pub channel_id: Option<String>,
    pub thumbnail_url: Option<String>,
    pub duration_seconds: Option<u64>,
    pub published_text: Option<String>,
    pub view_count_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel_avatar_url: Option<String>,
    #[serde(default)]
    pub is_live: bool,
    /// The view count as a number, read from `view_count_text`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub view_count: Option<u64>,
    /// A premiere or scheduled stream that has not started.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_upcoming: bool,
    /// When an upcoming video starts, in epoch milliseconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upcoming_start_ms: Option<u64>,
    /// A Short, known from the card itself rather than guessed from its length.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_short: bool,
    /// The channel carries a verified or verified-artist badge.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_verified: bool,
    /// Only the channel's members can watch it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_members_only: bool,
    /// The card's own badges as the server labels them ("4K", "CC", "New").
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub badges: Vec<String>,
    /// The channels behind a collaboration, the lead first; empty for one channel.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub collaborators: Vec<Collaborator>,
    /// The description excerpt search results show.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snippet: Option<String>,
}

/// One channel of a collaboration.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Collaborator {
    pub channel_id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscriber_count_text: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelatedContentItem {
    pub id: String,
    pub item_type: String,
    pub title: String,
    pub channel_name: String,
    pub channel_id: Option<String>,
    pub thumbnail_url: Option<String>,
    pub duration_seconds: Option<u64>,
    pub published_text: Option<String>,
    pub view_count_text: Option<String>,
    pub video_id: Option<String>,
    pub playlist_id: Option<String>,
    pub is_mix: bool,
    #[serde(default)]
    pub is_live: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel_avatar_url: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_upcoming: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_verified: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_members_only: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub badges: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub collaborators: Vec<Collaborator>,
}

