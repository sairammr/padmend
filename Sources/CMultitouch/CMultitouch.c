#include "include/CMultitouch.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define FRAMEWORK_PATH \
    "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

// The Touch Bar presents itself as a multitouch device with this family ID.
// Treating it as the trackpad is the single most common bug in code that uses
// MTDeviceCreateDefault, so it is rejected by name.
#define FAMILY_TOUCHBAR 176

typedef CFMutableArrayRef (*fn_create_list)(void);
typedef void *(*fn_create_default)(void);
typedef int (*fn_frame_cb)(void *device, PMTouch *touches, int count,
                           double timestamp, int frame);
typedef void (*fn_register)(void *device, fn_frame_cb callback);
typedef void (*fn_unregister)(void *device, fn_frame_cb callback);
typedef void (*fn_start)(void *device, int runMode);
typedef void (*fn_stop)(void *device);
typedef bool (*fn_is_running)(void *device);
typedef void (*fn_family)(void *device, int *family);
typedef void (*fn_surface)(void *device, int *width, int *height);
typedef void (*fn_sensor)(void *device, int *rows, int *cols);
typedef bool (*fn_is_builtin)(void *device);
typedef bool (*fn_is_opaque)(void *device);

static struct {
    bool resolved;
    bool ok;
    char reason[256];

    void *handle;
    fn_create_list createList;
    fn_create_default createDefault;
    fn_register registerCallback;
    fn_unregister unregisterCallback;
    fn_start start;
    fn_stop stop;
    fn_is_running isRunning;
    fn_family family;
    fn_surface surface;
    fn_sensor sensor;
    fn_is_builtin isBuiltIn;
    fn_is_opaque isOpaque;

    CFMutableArrayRef devices;

    void *current;
    PMFrameHandler handler;
    void *context;
    int32_t surfaceWidth;
    int32_t surfaceHeight;
} g;

static void fail(const char *why) {
    g.ok = false;
    snprintf(g.reason, sizeof(g.reason), "%s", why);
}

// dlsym for a symbol we cannot run without.
static void *required(const char *name) {
    void *sym = dlsym(g.handle, name);
    if (!sym) {
        char buf[256];
        snprintf(buf, sizeof(buf), "MultitouchSupport is missing %s", name);
        fail(buf);
    }
    return sym;
}

static void resolve(void) {
    if (g.resolved) return;
    g.resolved = true;
    g.ok = true;

    g.handle = dlopen(FRAMEWORK_PATH, RTLD_LAZY);
    if (!g.handle) {
        fail("could not dlopen MultitouchSupport.framework");
        return;
    }

    g.createList = (fn_create_list)required("MTDeviceCreateList");
    g.createDefault = (fn_create_default)required("MTDeviceCreateDefault");
    g.registerCallback = (fn_register)required("MTRegisterContactFrameCallback");
    g.unregisterCallback =
        (fn_unregister)required("MTUnregisterContactFrameCallback");
    g.start = (fn_start)required("MTDeviceStart");
    g.stop = (fn_stop)required("MTDeviceStop");
    if (!g.ok) return;

    // Optional: present on every macOS we care about, but absence should
    // degrade device selection rather than kill the process.
    g.isRunning = (fn_is_running)dlsym(g.handle, "MTDeviceIsRunning");
    g.family = (fn_family)dlsym(g.handle, "MTDeviceGetFamilyID");
    g.surface =
        (fn_surface)dlsym(g.handle, "MTDeviceGetSensorSurfaceDimensions");
    g.sensor = (fn_sensor)dlsym(g.handle, "MTDeviceGetSensorDimensions");
    g.isBuiltIn = (fn_is_builtin)dlsym(g.handle, "MTDeviceIsBuiltIn");
    g.isOpaque = (fn_is_opaque)dlsym(g.handle, "MTDeviceIsOpaque");
}

static CFMutableArrayRef deviceList(void) {
    resolve();
    if (!g.ok) return NULL;
    if (!g.devices) g.devices = g.createList();
    return g.devices;
}

static void *deviceAt(int index) {
    CFMutableArrayRef list = deviceList();
    if (!list) return NULL;
    if (index < 0 || index >= CFArrayGetCount(list)) return NULL;
    return (void *)CFArrayGetValueAtIndex(list, index);
}

bool pm_available(void) {
    resolve();
    return g.ok;
}

const char *pm_unavailable_reason(void) {
    resolve();
    return g.ok ? NULL : g.reason;
}

int pm_device_count(void) {
    CFMutableArrayRef list = deviceList();
    return list ? (int)CFArrayGetCount(list) : 0;
}

static void readInfo(void *device, PMDeviceInfo *out) {
    memset(out, 0, sizeof(*out));
    if (g.family) g.family(device, &out->familyID);
    if (g.surface) g.surface(device, &out->surfaceWidth, &out->surfaceHeight);
    if (g.sensor) g.sensor(device, &out->sensorRows, &out->sensorCols);
    if (g.isBuiltIn) out->builtIn = g.isBuiltIn(device);
    if (g.isOpaque) out->opaque = g.isOpaque(device);
}

bool pm_device_info(int index, PMDeviceInfo *out) {
    void *device = deviceAt(index);
    if (!device || !out) return false;
    readInfo(device, out);
    return true;
}

int pm_default_device_index(void) {
    int count = pm_device_count();
    int best = -1;
    long bestScore = -1;
    for (int i = 0; i < count; i++) {
        PMDeviceInfo info;
        if (!pm_device_info(i, &info)) continue;
        if (info.familyID == FAMILY_TOUCHBAR) continue;
        // Area in (1/100 mm)^2, biased heavily toward the built-in pad.
        long area = (long)info.surfaceWidth * (long)info.surfaceHeight;
        long score = area + (info.builtIn ? 1L << 40 : 0);
        if (score > bestScore) {
            bestScore = score;
            best = i;
        }
    }
    return best;
}

// MultitouchSupport's callback carries no user context, so the shim keeps a
// single active device in globals and forwards. One trackpad is the whole
// product; a multi-device version would need a device->context map here.
static int frameTrampoline(void *device, PMTouch *touches, int count,
                           double timestamp, int frame) {
    (void)device;
    if (g.handler) g.handler(touches, count, timestamp, frame, g.context);
    return 0;
}

bool pm_start(int index, PMFrameHandler handler, void *context) {
    if (!handler) return false;
    void *device = deviceAt(index);
    if (!device) return false;

    pm_stop();

    g.handler = handler;
    g.context = context;
    g.current = device;

    PMDeviceInfo info;
    readInfo(device, &info);
    g.surfaceWidth = info.surfaceWidth;
    g.surfaceHeight = info.surfaceHeight;

    g.registerCallback(device, frameTrampoline);
    g.start(device, 0);
    return true;
}

void pm_stop(void) {
    if (!g.current) return;
    g.stop(g.current);
    g.unregisterCallback(g.current, frameTrampoline);
    g.current = NULL;
    g.handler = NULL;
    g.context = NULL;
}

bool pm_is_running(void) {
    if (!g.current) return false;
    if (!g.isRunning) return true;
    return g.isRunning(g.current);
}

bool pm_current_surface(int32_t *width, int32_t *height) {
    if (!g.current) return false;
    if (width) *width = g.surfaceWidth;
    if (height) *height = g.surfaceHeight;
    return true;
}
