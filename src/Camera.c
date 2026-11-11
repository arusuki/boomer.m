#include "Camera.h"
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double clamp(double v, double lo, double hi) {
    return fmin(hi, fmax(lo, v));
}
BMConfig bm_config_default(void) {
    return (BMConfig){.min_scale = 0.01,
                      .max_scale = 64,
                      .scroll_speed = 1.5,
                      .drag_friction = 6,
                      .scale_friction = 12,
                      .flashlight_radius = 200,
                      .flashlight_dim = 0.8,
                      .filter_mode = BMFilterBicubic};
}
static char *trim(char *s) {
    while (isspace((unsigned char)*s))
        ++s;
    char *end = s + strlen(s);
    while (end > s && isspace((unsigned char)end[-1]))
        --end;
    *end = 0;
    return s;
}
bool bm_config_load(const char *path, BMConfig *out, char *error, size_t capacity) {
    FILE *f = fopen(path, "r");
    if (!f) {
        snprintf(error, capacity, "%s: %s", path, strerror(errno));
        return false;
    }
    BMConfig next = bm_config_default();
    char line[1024];
    unsigned number = 0;
    const char *reason = NULL;
    bool explicit_filter = false;
    while (fgets(line, sizeof line, f)) {
        ++number;
        if (!strchr(line, '\n') && !feof(f)) {
            reason = "line too long";
            break;
        }
        char *comment = strchr(line, '#');
        if (comment)
            *comment = 0;
        char *key = trim(line);
        if (!*key)
            continue;
        char *equals = strchr(key, '=');
        if (!equals) {
            reason = "expected key = number";
            break;
        }
        *equals = 0;
        key = trim(key);
        char *value = trim(equals + 1), *end;
        errno = 0;
        double v = strtod(value, &end);
        if (value == end || *trim(end) || errno || !isfinite(v)) {
            reason = "expected a finite number";
            break;
        }
        if (!strcmp(key, "min_scale"))
            next.min_scale = v;
        else if (!strcmp(key, "max_scale"))
            next.max_scale = v;
        else if (!strcmp(key, "scroll_speed"))
            next.scroll_speed = v;
        else if (!strcmp(key, "drag_friction"))
            next.drag_friction = v;
        else if (!strcmp(key, "scale_friction"))
            next.scale_friction = v;
        else if (!strcmp(key, "flashlight_radius"))
            next.flashlight_radius = v;
        else if (!strcmp(key, "flashlight_dim"))
            next.flashlight_dim = v;
        else if (!strcmp(key, "filter_mode")) {
            if (v != 0 && v != 1 && v != 2) {
                reason = "filter_mode must be 0, 1 or 2";
                break;
            }
            next.filter_mode = (BMFilterMode)v;
            explicit_filter = true;
        } else if (!strcmp(key, "linear_filter")) {
            if (v != 0 && v != 1) {
                reason = "linear_filter must be 0 or 1";
                break;
            }
            if (!explicit_filter)
                next.filter_mode = v == 0 ? BMFilterNearest : BMFilterLinear;
        } else {
            reason = "unknown key";
            break;
        }
    }
    if (ferror(f))
        reason = "read failed";
    fclose(f);
    if (!reason &&
        !(next.min_scale >= 0.001 && next.min_scale <= 1 && next.max_scale >= 1 &&
          next.max_scale <= 1024 && next.scroll_speed > 0 && next.scroll_speed <= 100 &&
          next.drag_friction > 0 && next.drag_friction <= 1000 && next.scale_friction > 0 &&
          next.scale_friction <= 1000 && next.flashlight_radius >= 1 &&
          next.flashlight_radius <= 10000 && next.flashlight_dim >= 0 && next.flashlight_dim <= 1))
        reason = "value outside supported range";
    if (reason) {
        snprintf(error, capacity, "%s:%u: %s", path, number, reason);
        return false;
    }
    *out = next;
    return true;
}
void bm_camera_reset(BMCamera *c, const BMConfig *cfg) {
    *c = (BMCamera){.scale = clamp(1, cfg->min_scale, cfg->max_scale), .target_scale = 1};
}
BMPoint bm_camera_world(const BMCamera *c, BMPoint p) {
    return (BMPoint){(p.x - c->offset.x) / c->scale, (p.y - c->offset.y) / c->scale};
}
void bm_camera_zoom(BMCamera *c, const BMConfig *cfg, BMPoint anchor, double delta) {
    if (!isfinite(delta))
        return;
    c->anchor = anchor;
    c->velocity = (BMPoint){0};
    c->target_scale =
        clamp(c->target_scale * exp(clamp(delta, -20, 20)), cfg->min_scale, cfg->max_scale);
}
void bm_camera_drag(BMCamera *c, BMPoint d, double dt) {
    c->offset.x += d.x;
    c->offset.y += d.y;
    c->target_scale = c->scale;
    if (dt > 0 && dt < 0.2) {
        // Coalesced/synthetic events may arrive almost simultaneously. Estimate
        // release velocity over a short window instead of amplifying one event.
        double sample_dt = fmax(dt, 1.0 / 120);
        double weight = -expm1(-25 * sample_dt);
        c->velocity.x += (clamp(d.x / sample_dt, -3000, 3000) - c->velocity.x) * weight;
        c->velocity.y += (clamp(d.y / sample_dt, -3000, 3000) - c->velocity.y) * weight;
    } else
        c->velocity = (BMPoint){0};
}
bool bm_camera_step(BMCamera *c, const BMConfig *cfg, double dt) {
    if (!isfinite(dt) || dt <= 0)
        return false;
    dt = fmin(dt, 0.1); // Do not fling after sleep or a breakpoint.
    double old = c->scale;
    c->target_scale = clamp(c->target_scale, cfg->min_scale, cfg->max_scale);
    c->scale =
        exp(log(old) + (log(c->target_scale) - log(old)) * -expm1(-cfg->scale_friction * dt));
    if (fabs(log(c->target_scale / c->scale)) < 0.00001)
        c->scale = c->target_scale;
    double ratio = c->scale / old;
    c->offset.x = c->anchor.x - (c->anchor.x - c->offset.x) * ratio;
    c->offset.y = c->anchor.y - (c->anchor.y - c->offset.y) * ratio;
    if (!c->dragging) {
        double decay = exp(-cfg->drag_friction * dt);
        double distance = (1 - decay) / cfg->drag_friction;
        c->offset.x += c->velocity.x * distance;
        c->offset.y += c->velocity.y * distance;
        c->velocity.x *= decay;
        c->velocity.y *= decay;
        if (hypot(c->velocity.x, c->velocity.y) < 0.1)
            c->velocity = (BMPoint){0};
    }
    return c->scale != c->target_scale ||
           (!c->dragging && hypot(c->velocity.x, c->velocity.y) >= 0.1);
}
