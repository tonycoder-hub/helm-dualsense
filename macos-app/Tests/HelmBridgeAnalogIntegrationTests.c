#include "HelmBridge.h"

#include <SDL3/SDL.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static const Uint16 kVirtualVendor = 0x1209;
static const Uint16 kVirtualProduct = 0x484D;

static void report_failure(const char *message) {
    fprintf(stderr, "FAIL: %s (%s)\n", message, SDL_GetError());
}

static bool nearly_equal(float actual, float expected, float tolerance) {
    return fabsf(actual - expected) <= tolerance;
}

int main(void) {
    int exit_code = 1;
    bool sdl_initialized = false;
    SDL_JoystickID identifier = 0;
    SDL_Joystick *joystick = NULL;

    if (!SDL_SetHint(
            SDL_HINT_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT,
            "0x1209/0x484D")) {
        report_failure("could not isolate the virtual controller VID/PID");
        goto cleanup;
    }
    if (!SDL_Init(SDL_INIT_GAMEPAD | SDL_INIT_EVENTS)) {
        report_failure("could not initialize SDL for the virtual controller");
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
    description.name = "Helm Analog Integration Fixture";

    identifier = SDL_AttachVirtualJoystick(&description);
    if (identifier == 0) {
        report_failure("could not attach the virtual gamepad");
        goto cleanup;
    }

    SDL_UpdateJoysticks();
    int gamepad_count = 0;
    SDL_JoystickID *gamepads = SDL_GetGamepads(&gamepad_count);
    bool isolated_virtual_gamepad = gamepads != NULL && gamepad_count == 1 &&
        gamepads[0] == identifier && SDL_IsJoystickVirtual(identifier);
    SDL_free(gamepads);
    if (!isolated_virtual_gamepad) {
        fprintf(
            stderr,
            "FAIL: virtual fixture is not the unique eligible gamepad "
            "count=%d virtual=%d\n",
            gamepad_count,
            SDL_IsJoystickVirtual(identifier));
        goto cleanup;
    }

    joystick = SDL_OpenJoystick(identifier);
    if (joystick == NULL) {
        report_failure("could not open the virtual joystick");
        goto cleanup;
    }

    char error[256] = {0};
    if (!HelmSDLStart(error, (int32_t)sizeof(error))) {
        fprintf(stderr, "FAIL: HelmSDLStart: %s\n", error);
        goto cleanup;
    }

    if (!SDL_SetJoystickVirtualAxis(
            joystick,
            SDL_GAMEPAD_AXIS_LEFT_TRIGGER,
            SDL_JOYSTICK_AXIS_MIN) ||
        !SDL_SetJoystickVirtualAxis(
            joystick,
            SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
            SDL_JOYSTICK_AXIS_MIN)) {
        report_failure("could not set released virtual triggers");
        goto cleanup;
    }
    HelmSDLAnalogState state;
    if (!HelmSDLReadAnalogState(&state) || state.left_trigger != 0.0f ||
        state.right_trigger != 0.0f) {
        report_failure("released virtual triggers did not normalize to zero");
        goto cleanup;
    }

    if (!SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_LEFTX, 24575) ||
        !SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_LEFTY, -16384) ||
        !SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_RIGHTY, 8192) ||
        // Virtual joystick trigger axes use the raw -32768...32767 range;
        // SDL_GetGamepadAxis remaps that to the documented 0...32767 range.
        !SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, 0) ||
        !SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, 32767)) {
        report_failure("could not set virtual analog axes");
        goto cleanup;
    }

    if (!HelmSDLReadAnalogState(&state)) {
        report_failure("Helm did not read the attached virtual gamepad");
        goto cleanup;
    }
    if (!state.connected || !nearly_equal(state.left_x, 0.75f, 0.001f) ||
        !nearly_equal(state.left_y, -0.5f, 0.001f) ||
        !nearly_equal(state.right_y, 0.25f, 0.001f) ||
        !nearly_equal(state.left_trigger, 0.5f, 0.001f) ||
        !nearly_equal(state.right_trigger, 1.0f, 0.001f)) {
        fprintf(
            stderr,
            "FAIL: unexpected analog state connected=%d left=(%.4f,%.4f) rightY=%.4f "
            "triggers=(%.4f,%.4f)\n",
            state.connected,
            state.left_x,
            state.left_y,
            state.right_y,
            state.left_trigger,
            state.right_trigger);
        goto cleanup;
    }

    for (int sample = 0; sample < 256; sample++) {
        Sint16 left_x = (sample % 2 == 0) ? 12000 : -12000;
        Sint16 right_y = (sample % 3 == 0) ? 22000 : -22000;
        if (!SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_LEFTX, left_x) ||
            !SDL_SetJoystickVirtualAxis(joystick, SDL_GAMEPAD_AXIS_RIGHTY, right_y) ||
            !HelmSDLReadAnalogState(&state)) {
            report_failure("continuous analog polling failed");
            goto cleanup;
        }
        float expected_left_x = left_x < 0 ? (float)left_x / 32768.0f
                                           : (float)left_x / 32767.0f;
        float expected_right_y = right_y < 0 ? (float)right_y / 32768.0f
                                             : (float)right_y / 32767.0f;
        if (!nearly_equal(state.left_x, expected_left_x, 0.001f) ||
            !nearly_equal(state.right_y, expected_right_y, 0.001f)) {
            report_failure("a polled stick sample was stale or quantized");
            goto cleanup;
        }
    }

    exit_code = 0;

cleanup:
    if (sdl_initialized) {
        HelmSDLStop();
    }
    if (joystick != NULL) {
        SDL_CloseJoystick(joystick);
    }
    if (identifier != 0 && !SDL_DetachVirtualJoystick(identifier)) {
        report_failure("could not detach the virtual gamepad");
        exit_code = 1;
    }
    SDL_Quit();
    if (exit_code == 0) {
        puts("HELM_BRIDGE_ANALOG_INTEGRATION_TESTS=PASS samples=256");
    }
    return exit_code;
}
