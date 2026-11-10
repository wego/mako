#include <stdbool.h>
#include <stdint.h>

// Strings returned are owned by the caller; release with mako_free. NULL = none.
char *mako_config_error(const char *config);
uint32_t mako_max_tabs(const char *config);
bool mako_restore_session(const char *config);
char *mako_resolve(const char *config, const char *input);
char *mako_blocked(const char *config, const char *host, uint8_t weekday, uint16_t minute);

// Trails (the page tree). Both return JSON: {"state": ..., "rows": [...]} or {"error": "..."}.
// state is opaque to the caller: keep it, save it, pass it back. action: see core/src/trails.rs.
char *mako_trails_load(const char *state);
char *mako_trails_apply(const char *config, const char *state, const char *action);

void mako_free(char *s);
