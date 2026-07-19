#include "HelmBridge.h"

#include <SDL3/SDL.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

static const Uint16 kVirtualVendor = 0x1209;
static const Uint16 kVirtualProduct = 0x484D;

typedef struct SamplerContext {
    atomic_bool running;
    atomic_uint successful_samples;
    atomic_uint failed_samples;
    atomic_ullong maximum_call_ns;
} SamplerContext;

static void record_maximum_call(SamplerContext *context, Uint64 call_ns) {
    unsigned long long observed = atomic_load(&context->maximum_call_ns);
    while (call_ns > observed && !atomic_compare_exchange_weak(
            &context->maximum_call_ns,
            &observed,
            call_ns)) {
    }
}

static void *sample_analog_state(void *raw_context) {
    SamplerContext *context = raw_context;
    (void)pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    const Uint64 interval_ns = 1000000000ULL / 240ULL;
    Uint64 next_deadline = SDL_GetTicksNS();
    while (atomic_load(&context->running)) {
        Uint64 call_started_at = SDL_GetTicksNS();
        HelmSDLAnalogState state;
        if (HelmSDLReadAnalogState(&state)) {
            atomic_fetch_add(&context->successful_samples, 1);
        } else {
            atomic_fetch_add(&context->failed_samples, 1);
        }
        record_maximum_call(context, SDL_GetTicksNS() - call_started_at);

        next_deadline += interval_ns;
        Uint64 now = SDL_GetTicksNS();
        if (next_deadline > now) {
            SDL_DelayPrecise(next_deadline - now);
        } else {
            next_deadline = now;
        }
    }
    return NULL;
}

static void report_failure(const char *message) {
    fprintf(stderr, "FAIL: %s (%s)\n", message, SDL_GetError());
}

int main(void) {
    int exit_code = 1;
    bool sdl_initialized = false;
    bool bridge_started = false;
    SDL_JoystickID identifier = 0;
    SDL_Joystick *joystick = NULL;
    pthread_t sampler_thread;
    bool sampler_started = false;
    SamplerContext context = {
        .running = ATOMIC_VAR_INIT(false),
        .successful_samples = ATOMIC_VAR_INIT(0),
        .failed_samples = ATOMIC_VAR_INIT(0),
        .maximum_call_ns = ATOMIC_VAR_INIT(0),
    };

    if (!SDL_SetHint(
            SDL_HINT_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT,
            "0x1209/0x484D") ||
        !SDL_Init(SDL_INIT_GAMEPAD | SDL_INIT_EVENTS)) {
        report_failure("could not initialize isolated SDL fixture");
        goto cleanup;
    }
    sdl_initialized = true;

    SDL_VirtualJoystickDesc description;
    SDL_INIT_INTERFACE(&description);
    description.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    description.vendor_id = kVirtualVendor;
    description.product_id = kVirtualProduct;
    description.naxes = SDL_GAMEPAD_AXIS_COUNT;
    description.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    description.axis_mask = (1u << SDL_GAMEPAD_AXIS_COUNT) - 1u;
    description.button_mask = (1u << SDL_GAMEPAD_BUTTON_COUNT) - 1u;
    description.name = "Helm Concurrent Analog Fixture";

    identifier = SDL_AttachVirtualJoystick(&description);
    if (identifier == 0) {
        report_failure("could not attach concurrent virtual gamepad");
        goto cleanup;
    }
    joystick = SDL_OpenJoystick(identifier);
    if (joystick == NULL) {
        report_failure("could not open concurrent virtual joystick");
        goto cleanup;
    }

    char error[256] = {0};
    if (!HelmSDLStart(error, (int32_t)sizeof(error))) {
        fprintf(stderr, "FAIL: HelmSDLStart: %s\n", error);
        goto cleanup;
    }
    bridge_started = true;

    atomic_store(&context.running, true);
    if (pthread_create(&sampler_thread, NULL, sample_analog_state, &context) != 0) {
        report_failure("could not start analog sampler thread");
        goto cleanup;
    }
    sampler_started = true;

    const Uint64 exercise_duration_ns = 1250000000ULL;
    const Uint64 event_interval_ns = 1000000000ULL / 60ULL;
    const Uint64 exercise_started_at = SDL_GetTicksNS();
    unsigned int iteration = 0;
    while (SDL_GetTicksNS() - exercise_started_at < exercise_duration_ns) {
        Sint16 axis = iteration % 2 == 0 ? 24000 : -24000;
        if (!SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_LEFTX, axis) ||
            !SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_RIGHTY, -axis)) {
            report_failure("could not update concurrent virtual axes");
            goto cleanup;
        }
        HelmSDLEvent event;
        for (int pump = 0; pump < 32 && HelmSDLPoll(&event); pump++) {
        }
        iteration++;
        SDL_DelayPrecise(event_interval_ns);
    }
    unsigned int connected_successful_samples =
        atomic_load(&context.successful_samples);
    unsigned int connected_failed_samples = atomic_load(&context.failed_samples);

    SDL_CloseJoystick(joystick);
    joystick = NULL;
    if (!SDL_DetachVirtualJoystick(identifier)) {
        report_failure("could not detach concurrent virtual gamepad");
        goto cleanup;
    }
    identifier = 0;
    bool saw_disconnect = false;
    const Uint64 disconnect_deadline = SDL_GetTicksNS() + 500000000ULL;
    while (SDL_GetTicksNS() < disconnect_deadline && !saw_disconnect) {
        HelmSDLEvent event;
        while (HelmSDLPoll(&event)) {
            if (event.kind == HELM_SDL_EVENT_DISCONNECTED) {
                saw_disconnect = true;
                break;
            }
        }
        SDL_DelayPrecise(1000000ULL);
    }
    if (!saw_disconnect) {
        report_failure("bridge did not deliver concurrent disconnect");
        goto cleanup;
    }
    SDL_DelayPrecise(50000000ULL);

    atomic_store(&context.running, false);
    (void)pthread_join(sampler_thread, NULL);
    sampler_started = false;

    double maximum_call_ms =
        (double)atomic_load(&context.maximum_call_ns) / 1000000.0;
    if (connected_successful_samples < 64 || connected_failed_samples != 0 ||
        maximum_call_ms > 50.0) {
        fprintf(
            stderr,
            "FAIL: concurrent bridge samples=%u connectedFailures=%u maxCall=%.2fms\n",
            connected_successful_samples,
            connected_failed_samples,
            maximum_call_ms);
        goto cleanup;
    }

    printf(
        "HELM_BRIDGE_CONCURRENCY_TESTS=PASS samples=%u maxCall=%.2fms disconnect=true\n",
        connected_successful_samples,
        maximum_call_ms);
    exit_code = 0;

cleanup:
    if (sampler_started) {
        atomic_store(&context.running, false);
        (void)pthread_join(sampler_thread, NULL);
    }
    if (bridge_started) {
        HelmSDLStop();
    }
    if (joystick != NULL) {
        SDL_CloseJoystick(joystick);
    }
    if (identifier != 0) {
        (void)SDL_DetachVirtualJoystick(identifier);
    }
    if (sdl_initialized) {
        SDL_Quit();
    }
    return exit_code;
}
