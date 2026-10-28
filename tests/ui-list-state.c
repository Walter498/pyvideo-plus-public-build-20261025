#include "../src/MediaMetadataState.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(PVXMetadataConcurrencyLimit == 3);
    // The original HLS bug: a successful manifest response is NOT final delivery.
    PVXMetadataState hls = {0};
    hls.probeDone = true;
    assert(!PVXMetadataTakeDelivery(&hls, false));
    hls.coverDone = true; // asynchronous poster/AVAsset image completion
    assert(PVXMetadataTakeDelivery(&hls, false));
    assert(!PVXMetadataTakeDelivery(&hls, false));
    assert(!PVXMetadataTakeDelivery(&hls, true));
    // MP4 range response must not win the race against its thumbnail either.
    PVXMetadataState mp4 = {0};
    mp4.probeDone = true;
    assert(!PVXMetadataTakeDelivery(&mp4, false));
    mp4.coverDone = true;
    assert(PVXMetadataTakeDelivery(&mp4, false));
    // Poster/thumbnail can complete before the metadata probe.
    PVXMetadataState poster = {0};
    poster.coverDone = true;
    assert(!PVXMetadataTakeDelivery(&poster, false));
    poster.probeDone = true;
    assert(PVXMetadataTakeDelivery(&poster, false));
    // Timeout releases a job exactly once; late probe/thumbnail cannot redeliver.
    PVXMetadataState timeout = {0};
    assert(PVXMetadataTakeDelivery(&timeout, true));
    timeout.probeDone = timeout.coverDone = true;
    assert(!PVXMetadataTakeDelivery(&timeout, false));
    // Image errors or asset failures finish normally once both branches finish.
    PVXMetadataState failed = {true, true, false};
    assert(PVXMetadataTakeDelivery(&failed, false));
    puts("PASS production completion gate: HLS/MP4 races, poster-first, timeout, late callbacks, concurrency constant");
    return 0;
}
