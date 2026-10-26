//! Flow's Home feed assembly (Flow Desktop `services/home_feed`, itself Flow for Android's
//! `HomeFeedAssembly`/`HomeFeedMixer`), the pure parts ported unchanged.
pub mod arrange;
pub mod card;
pub mod channel_memory;
pub mod filters;
pub mod inputs;
pub mod lanes;
pub mod mixer;
pub mod neighbours;
pub mod origin;
pub mod seeds;
