//! The tweak asks InnerTube for English (`hl=en`) text, so counts and ages always read as English.
pub mod locale {
    #[must_use]
    pub fn content_language() -> String {
        "en".to_string()
    }

    #[must_use]
    pub fn is_english() -> bool {
        true
    }
}
