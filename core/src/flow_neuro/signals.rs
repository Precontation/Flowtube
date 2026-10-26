use serde::{Deserialize, Serialize};
use crate::flow_neuro::key_migration::{spell_from_titles, to_key_spec_2};
use crate::flow_neuro::language::system_language;
use crate::flow_neuro::maintenance::migrate;
use crate::flow_neuro::scoring::UserBrain;

/// The setting the brain is stored under.
pub const BRAIN_SETTING: &str = "user_neuro_brain";
/// The brain as it was before its one-time tidy ([`crate::flow_neuro::maintenance`]); its
/// presence also marks the tidy done on this device.
pub const BRAIN_BEFORE_MIGRATION_SETTING: &str = "user_neuro_brain_before_v14";
/// How many recent titles spell the keys of a brain converted to key spec 2.
pub const SPELLING_TITLES: i64 = 500;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum InteractionType {
    Click,
    Liked,
    Watched,
    Skipped,
    Disliked,
    /// Watch later, a playlist or a download: a strong signal, weaker than a like.
    Saved,
    /// "Not interested" on a card: hides the video for good and its channel for a while.
    NotInterested,
}

impl InteractionType {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Click => "CLICK",
            Self::Liked => "LIKED",
            Self::Watched => "WATCHED",
            Self::Skipped => "SKIPPED",
            Self::Disliked => "DISLIKED",
            Self::Saved => "SAVED",
            Self::NotInterested => "NOT_INTERESTED",
        }
    }
}

/// The key of a link between two topics, the way Flow for Android writes it ("a|b", in order).
pub fn make_affinity_key(t1: &str, t2: &str) -> String {
    if t1 < t2 {
        format!("{t1}|{t2}")
    } else {
        format!("{t2}|{t1}")
    }
}

/// Brings a loaded brain up to this engine's schema, key spec and evidence horizons
/// (Flow Desktop's `settle_brain`). `recent_titles` spell keys converted from key spec 1, and
/// `tidied` records that the one-time evidence migration already ran. Returns whether it changed.
pub fn settle_brain(brain: &mut UserBrain, recent_titles: &[String], tidied: &mut bool) -> bool {
    let mut changed = brain.schema_version != crate::flow_neuro::scoring::SCHEMA_VERSION;
    brain.schema_version = crate::flow_neuro::scoring::SCHEMA_VERSION;
    changed |= brain.settle_languages(&system_language());
    if to_key_spec_2(brain) {
        spell_from_titles(brain, recent_titles);
        tracing::info!("[FlowNeuro] brain converted to key spec 2");
        changed = true;
    }
    if !*tidied {
        migrate(brain);
        *tidied = true;
        changed = true;
    }
    changed
}
