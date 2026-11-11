#define _POSIX_C_SOURCE 200809L
#include "Camera.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void close_enough(double a, double b) {
    assert(fabs(a - b) < 1e-8);
}
static void test_anchor(void) {
    BMConfig config = bm_config_default();
    BMCamera c;
    bm_camera_reset(&c, &config);
    c.offset = (BMPoint){-150, 73};
    BMPoint anchor = {761, 209}, before = bm_camera_world(&c, anchor);
    bm_camera_zoom(&c, &config, anchor, log(12));
    for (int i = 0; i < 300; ++i) {
        bm_camera_step(&c, &config, 1.0 / 120);
        BMPoint after = bm_camera_world(&c, anchor);
        close_enough(before.x, after.x);
        close_enough(before.y, after.y);
    }
    close_enough(c.scale, 12);
    bm_camera_zoom(&c, &config, anchor, 1000);
    close_enough(c.target_scale, config.max_scale);
    bm_camera_zoom(&c, &config, anchor, -1000);
    close_enough(c.target_scale, config.min_scale);
}
static void test_frame_rate(void) {
    BMConfig config = bm_config_default();
    BMCamera a, b;
    bm_camera_reset(&a, &config);
    bm_camera_reset(&b, &config);
    bm_camera_zoom(&a, &config, (BMPoint){400, 250}, log(4));
    b = a;
    for (int i = 0; i < 30; ++i)
        bm_camera_step(&a, &config, 1.0 / 60);
    for (int i = 0; i < 72; ++i)
        bm_camera_step(&b, &config, 1.0 / 144);
    close_enough(a.scale, b.scale);
    close_enough(a.offset.x, b.offset.x);
    bm_camera_reset(&a, &config);
    a.velocity = (BMPoint){1000, -700};
    b = a;
    for (int i = 0; i < 30; ++i)
        bm_camera_step(&a, &config, 1.0 / 60);
    for (int i = 0; i < 72; ++i)
        bm_camera_step(&b, &config, 1.0 / 144);
    close_enough(a.offset.x, b.offset.x);
    close_enough(a.offset.y, b.offset.y);
    close_enough(a.velocity.x, b.velocity.x);
    for (int i = 0; i < 300; ++i)
        bm_camera_step(&a, &config, 1.0 / 60);
    assert(!bm_camera_step(&a, &config, 1.0 / 60));
}
static void test_drag_reset(void) {
    BMConfig cfg = bm_config_default();
    BMCamera c;
    bm_camera_reset(&c, &cfg);
    c.dragging = true;
    bm_camera_drag(&c, (BMPoint){80, -20}, 0.02);
    close_enough(c.offset.x, 80);
    close_enough(c.offset.y, -20);
    bm_camera_step(&c, &cfg, 0.01);
    close_enough(c.offset.x, 80); // No inertia while held.
    c.dragging = false;
    bm_camera_step(&c, &cfg, 0.01);
    assert(c.offset.x > 80);
    bm_camera_reset(&c, &cfg);
    assert(c.scale == 1 && c.target_scale == 1 && !c.dragging);
    assert(c.offset.x == 0 && c.velocity.x == 0);
    bm_camera_zoom(&c, &cfg, (BMPoint){0}, NAN);
    assert(c.target_scale == 1);
    // A coalesced drag must not turn a short gesture into a multi-screen fling.
    bm_camera_drag(&c, (BMPoint){135, -70}, 0.000001);
    for (int i = 0; i < 300; ++i)
        bm_camera_step(&c, &cfg, 1.0 / 120);
    assert(c.offset.x > 135 && c.offset.x < 250);
    assert(c.offset.y < -70 && c.offset.y > -185);
}
static void write_config(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    assert(f);
    fputs(text, f);
    fclose(f);
}
static void test_config(void) {
    char path[] = "/tmp/boomer-config-test-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    close(fd);
    char error[1400];
    BMConfig cfg = bm_config_default();
    assert(cfg.filter_mode == BMFilterBicubic);
    write_config(path,
                 " # comment\nmin_scale = 0.1\nscroll_speed = 2 # inline\nlinear_filter = 1\n");
    assert(bm_config_load(path, &cfg, error, sizeof error));
    assert(cfg.min_scale == 0.1 && cfg.scroll_speed == 2 && cfg.filter_mode == BMFilterLinear);
    const char *invalid[] = {
        "min_scale",         "min_scale = nan",      "scale_friction = 0",  "max_scale = 0.5",
        "min_scale = 2",     "linear_filter = 2",    "unknown = 1",         "min_scale = 0.5junk",
        "scroll_speed = -1", "flashlight_dim = 1.5", "drag_friction = inf", "min_scale = ",
        "filter_mode = -1",  "filter_mode = 3",      "filter_mode = 1.5",   "filter_mode = nan"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; ++i) {
        write_config(path, invalid[i]);
        assert(!bm_config_load(path, &cfg, error, sizeof error));
        assert(cfg.min_scale == 0.1 && cfg.scroll_speed == 2 &&
               cfg.filter_mode == BMFilterLinear); // Atomic failure.
        assert(strstr(error, path));
    }
    const char *filters[] = {"linear_filter = 0",
                             "linear_filter = 1",
                             "filter_mode = 2",
                             "filter_mode = 0",
                             "filter_mode = 1",
                             "linear_filter = 0\nfilter_mode = 2",
                             "filter_mode = 2\nlinear_filter = 0",
                             "# default"};
    const BMFilterMode expected[] = {BMFilterNearest, BMFilterLinear, BMFilterBicubic,
                                     BMFilterNearest, BMFilterLinear, BMFilterBicubic,
                                     BMFilterBicubic, BMFilterBicubic};
    for (size_t i = 0; i < sizeof filters / sizeof *filters; ++i) {
        write_config(path, filters[i]);
        assert(bm_config_load(path, &cfg, error, sizeof error));
        assert(cfg.filter_mode == expected[i]);
    }
    unlink(path);
    assert(!bm_config_load(path, &cfg, error, sizeof error));
}
int main(void) {
    test_anchor();
    test_frame_rate();
    test_drag_reset();
    test_config();
    puts("Camera/config tests passed (ASan + UBSan).");
    return 0;
}
