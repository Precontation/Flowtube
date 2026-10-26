//! FlowNeuro, the on-device recommendation engine of Flow (github.com/Flow-Tube/Flow-Desktop,
//! GPL-3.0), packaged for the FlowTube iOS tweak. `flow_neuro` is Flow's own code with its SQLite
//! stores swapped for resident snapshots; `home` is its Home feed assembly; `engine` is its
//! recommendation service and Home load without Tauri or SQLite;
//! `youtube` builds InnerTube requests and reads answers into cards; `import` reads Takeout and NewPipe exports; `ffi` is the C API the tweak links against.
#![allow(dead_code)]

pub mod api;
pub mod engine;
pub mod errors;
pub mod ffi;
pub mod flow_neuro;
pub mod home;
pub mod import;
pub mod models;
pub mod youtube;
