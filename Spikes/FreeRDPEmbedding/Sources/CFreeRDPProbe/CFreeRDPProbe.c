#include "CFreeRDPProbe.h"

#if __has_include(<freerdp/freerdp.h>) && __has_include(<freerdp/gdi/gdi.h>)
#define FREERDP_HEADERS_AVAILABLE true
#define FREERDP_PROBE_DETAIL "FreeRDP headers found"
#else
#define FREERDP_HEADERS_AVAILABLE false
#define FREERDP_PROBE_DETAIL "FreeRDP headers not found; no supported SPM/XCFramework artifact supplied"
#endif

FreeRDPProbeResult freerdp_probe(void) {
    FreeRDPProbeResult result = {
        .headers_available = FREERDP_HEADERS_AVAILABLE,
        .detail = FREERDP_PROBE_DETAIL,
    };
    return result;
}

FreeRDPFrame freerdp_mock_frame(void) {
    /* Two BGRX pixels: red, then green. This is the layout requested from gdi_init. */
    static const uint8_t pixels[] = {
        0x00, 0x00, 0xFF, 0xFF,
        0x00, 0xFF, 0x00, 0xFF,
    };
    FreeRDPFrame frame = {
        .bytes = pixels,
        .width = 2,
        .height = 1,
        .stride = 8,
    };
    return frame;
}
