// Thin C shim over Apple's private MultitouchSupport.framework.
//
// Everything here is dynamically resolved with dlopen/dlsym rather than linked.
// Direct extern declarations into a private framework trip arm64e pointer
// authentication and fault at the first call, so the symbols have to come back
// as plain function pointers.
#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *PMDeviceRef;

typedef struct {
    float x;
    float y;
} PMPoint;

typedef struct {
    PMPoint position;
    PMPoint velocity;
} PMReadout;

// 96 bytes per touch. Field order was established by the open-source projects
// that have tracked this struct since 10.5 (FingerMgmt, Karabiner's multitouch
// extension, BetterTouchTool) and the size still matches on macOS 27.
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;
    int32_t fingerID;
    int32_t handID;
    PMReadout normalized;
    float size;
    int32_t pressureInt;
    float angle;
    float majorAxis;
    float minorAxis;
    PMReadout absolute;
    int32_t unused[2];
    float density;
} PMTouch;

// Called on MultitouchSupport's own serial queue, once per hardware frame.
typedef void (*PMFrameHandler)(const PMTouch *touches, int32_t count,
                               double timestamp, int32_t frame, void *context);

typedef struct {
    int32_t familyID;
    int32_t surfaceWidth;   // 1/100 mm
    int32_t surfaceHeight;  // 1/100 mm
    int32_t sensorRows;     // physical capacitive trace rows
    int32_t sensorCols;     // physical capacitive trace columns
    bool builtIn;
    bool opaque;
} PMDeviceInfo;

/// Resolves the framework and its symbols. Safe to call repeatedly.
/// Returns false if the framework or a required symbol is missing.
bool pm_available(void);

/// Human-readable reason the shim is unavailable, or NULL when it is fine.
const char *pm_unavailable_reason(void);

/// Number of multitouch devices the system reports.
int pm_device_count(void);

/// Metadata for device `index`. Returns false when the index is out of range.
bool pm_device_info(int index, PMDeviceInfo *out);

/// Picks the device that is most likely the main trackpad: prefers built-in,
/// then largest sensor surface. Explicitly rejects the Touch Bar (family 176).
/// Returns -1 when there is no suitable device.
int pm_default_device_index(void);

/// Opens device `index` and begins delivering frames to `handler`.
/// Only one device may be open at a time; opening again replaces the previous.
bool pm_start(int index, PMFrameHandler handler, void *context);

/// Stops delivery and closes the device. Safe to call when not started.
void pm_stop(void);

/// Whether a device is currently started.
bool pm_is_running(void);

/// Sensor dimensions of the currently started device, in 1/100 mm.
bool pm_current_surface(int32_t *width, int32_t *height);

#ifdef __cplusplus
}
#endif
#endif
