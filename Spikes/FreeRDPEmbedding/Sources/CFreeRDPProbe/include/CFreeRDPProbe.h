#ifndef C_FREERDP_PROBE_H
#define C_FREERDP_PROBE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct FreeRDPProbeResult {
    bool headers_available;
    const char *detail;
} FreeRDPProbeResult;

typedef struct FreeRDPFrame {
    const uint8_t *bytes;
    size_t width;
    size_t height;
    size_t stride;
} FreeRDPFrame;

FreeRDPProbeResult freerdp_probe(void);
FreeRDPFrame freerdp_mock_frame(void);

#endif
