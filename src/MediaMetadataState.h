#ifndef PVX_MEDIA_METADATA_STATE_H
#define PVX_MEDIA_METADATA_STATE_H
#include <stdbool.h>
// Shared, platform-independent completion gate. Called only on the main queue.
typedef struct {
    bool probeDone;
    bool coverDone;
    bool delivered;
} PVXMetadataState;
enum { PVXMetadataConcurrencyLimit = 3 };
static inline bool PVXMetadataTakeDelivery(PVXMetadataState *state, bool timeout) {
    if (state->delivered || (!timeout && (!state->probeDone || !state->coverDone))) return false;
    state->delivered = true;
    return true;
}
#endif
