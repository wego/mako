#include <stdbool.h>
#include <stdint.h>

// Strings returned are owned by the caller; release with mako_free. NULL = none.
char *mako_config_error(const char *config);
uint32_t mako_max_trails(const char *config);
uint32_t mako_trail_limit(void);
char *mako_set_setting(const char *config, const char *key, const char *value);
bool mako_restore_session(const char *config);
char *mako_resolve(const char *config, const char *input);
char *mako_blocked(const char *config, const char *host, uint8_t weekday, uint16_t minute);

// Trails (the page tree). Both return JSON: {"state": ..., "rows": [...], "pages": [ids]} or {"error": "..."}.
// state is opaque to the caller: keep it, save it, pass it back. action: see core/src/trails.rs.
char *mako_trails_load(const char *state);
char *mako_trails_apply(const char *config, const char *state, const char *action);

// History (visited pages) lives in the core behind a handle: it is too big to pass as text on
// every keystroke. load: NULL or "" = empty; returns NULL for JSON this build cannot read.
// visit/retitle/clear return true when the history changed and should be saved (mako_history_save).
typedef struct mako_history mako_history;
mako_history *mako_history_load(const char *json);
bool mako_history_visit(mako_history *history, const char *config, const char *url, const char *title, uint64_t now, uint8_t weekday, uint16_t minute);
bool mako_history_retitle(mako_history *history, const char *url, const char *title);
bool mako_history_clear(mako_history *history);
char *mako_history_save(const mako_history *history);
void mako_history_free(mako_history *history);
// Address bar rows as a JSON array: [{"kind": "open_page", "id", "color", "title", "url"} | {"kind": "history", "title", "url"}].
// trails is the state the trails calls return.
char *mako_suggest(const mako_history *history, const char *config, const char *trails, const char *query, uint64_t now);

void mako_free(char *s);
