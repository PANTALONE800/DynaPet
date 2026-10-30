#ifndef PET_BRIDGE_H
#define PET_BRIDGE_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define PET_BRIDGE_API __attribute__((visibility("default")))

typedef struct pet_bridge_window pet_bridge_window;

/* Window calls must execute on the main thread. The pointer is opaque and
 * owned by this library. Callers must never free() it or dereference it. */
PET_BRIDGE_API pet_bridge_window *bridge_create_test_window(void);
/* 0 = success; -1 = invalid argument/handle; -2 = wrong thread. */
PET_BRIDGE_API int bridge_set_topmost(pet_bridge_window *handle, int is_top);
/* NULL is a no-op. A live handle must be destroyed once, on the main thread. */
PET_BRIDGE_API void bridge_destroy_window(pet_bridge_window *handle);

/* Read-only test diagnostics; do not expose native window objects. */
PET_BRIDGE_API int bridge_debug_is_topmost(pet_bridge_window *handle);
PET_BRIDGE_API size_t bridge_debug_live_handles(void);
PET_BRIDGE_API size_t bridge_debug_live_native_windows(void);
/* Thread-local static text; do not free the returned string. */
PET_BRIDGE_API const char *bridge_last_error(void);
#ifdef __cplusplus
}
#endif
#endif
