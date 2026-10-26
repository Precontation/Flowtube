// FlowNeuro: Flow's on-device recommendation engine (GPL-3.0), C API.
// Strings in: UTF-8, NUL-terminated. Strings out: UTF-8 JSON, free with fn_free(). NULL on failure.
// Thread-safe (one engine per process, behind a lock); every call is panic-safe.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool fn_open(const char *dir, const char *language, const char *region);
bool fn_save(void);
void fn_reset(void);
void fn_free(char *json);

// Home: plan -> send requests -> assemble.
// plan:   {"loadId":1,"requests":[{"id","url","body","headers":[[name,value],...]}]}
// answers:[{"id","status","body"}]
// page:   {"items":[{...VideoSummary, "reason","source"}],"offline":bool,"coldStart":bool}
char *fn_plan_home(bool more);
char *fn_assemble(uint64_t load_id, const char *answers_json);
// The local Subscriptions page (followed channels' uploads, newest first); answer with fn_assemble.
char *fn_plan_subscriptions(void);
// Local lists: "subscriptions" [{"id","name"}], "likes" [{...VideoSummary,"at"}], "history" [{"videoId","title",...}].
char *fn_library(const char *kind);
bool fn_is_subscribed(const char *channel_id);

// Watching. Send the watch-page request when a video starts, hand its answer to fn_watch_page,
// report progress every few seconds, and end the viewing when the player closes.
char *fn_watch_page_request(const char *video_id);
void fn_watch_page(const char *video_id, const char *body);
void fn_watch_progress(const char *report_json); // {"videoId","position","duration","playedDelta",...}
void fn_watch_end(void);

// Signals. action: like, unlike, dislike, notInterested, save, dismiss. video_json nullable.
bool fn_feedback(const char *video_id, const char *action, const char *video_json);
void fn_subscription(const char *channel_id, const char *name, bool subscribed);
void fn_searched(const char *query);
void fn_choose_topics(const char *topics_json);
void fn_block_topic(const char *topic);
void fn_block_channel(const char *channel_id);
void fn_set_learning_paused(bool paused);

// kind: "subscriptions-csv" (Takeout), "subscriptions-json" (NewPipe), "history-json" (Takeout).
int64_t fn_import(const char *kind, const char *data);
char *fn_stats(void);
char *fn_topic_catalog(void); // [{"name","topics":[...]}]

#ifdef __cplusplus
}
#endif
