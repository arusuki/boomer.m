#ifndef BOOMER_CAMERA_H
#define BOOMER_CAMERA_H
#include <stdbool.h>
#include <stddef.h>

typedef struct {
    double x, y;
} BMPoint;
typedef enum { BMFilterNearest, BMFilterLinear, BMFilterBicubic } BMFilterMode;
typedef struct {
    double min_scale, max_scale, scroll_speed, drag_friction, scale_friction;
    double flashlight_radius, flashlight_dim;
    BMFilterMode filter_mode;
} BMConfig;
typedef struct {
    BMPoint offset, velocity, anchor;
    double scale, target_scale;
    bool dragging;
} BMCamera;

BMConfig bm_config_default(void);
// Transactional: errors leave the caller's config untouched.
bool bm_config_load(const char *path, BMConfig *out, char *error, size_t capacity);
void bm_camera_reset(BMCamera *camera, const BMConfig *config);
void bm_camera_zoom(BMCamera *camera, const BMConfig *config, BMPoint anchor, double log_delta);
void bm_camera_drag(BMCamera *camera, BMPoint delta, double dt);
bool bm_camera_step(BMCamera *camera, const BMConfig *config, double dt);
BMPoint bm_camera_world(const BMCamera *camera, BMPoint screen);
#endif
