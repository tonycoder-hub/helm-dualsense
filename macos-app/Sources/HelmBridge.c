#include "HelmBridge.h"

#include <Carbon/Carbon.h>
#include <SDL3/SDL.h>
#include <stdio.h>
#include <string.h>

static SDL_Gamepad *active_gamepad = NULL;
static bool initialized = false;
static bool pending_connected = false;
static bool pending_left_stick = false;
static bool pending_triggers = false;
static float left_stick_x = 0.0f;
static float left_stick_y = 0.0f;
static float left_trigger = 0.0f;
static float right_trigger = 0.0f;

static void clear_event(HelmSDLEvent *event) {
    memset(event, 0, sizeof(*event));
}

static void copy_text(char *destination, size_t capacity, const char *source) {
    if (capacity == 0) {
        return;
    }
    if (source == NULL) {
        source = "";
    }
    snprintf(destination, capacity, "%s", source);
}

static bool event_matches_active(SDL_JoystickID instance_id) {
    return active_gamepad != NULL && SDL_GetGamepadID(active_gamepad) == instance_id;
}

static bool is_dualsense(SDL_JoystickID instance_id) {
    return SDL_GetGamepadTypeForID(instance_id) == SDL_GAMEPAD_TYPE_PS5;
}

static float normalized_axis(Sint16 value) {
    return value < 0 ? (float)value / 32768.0f : (float)value / 32767.0f;
}

static float normalized_trigger(Sint16 value) {
    return value <= 0 ? 0.0f : (float)value / 32767.0f;
}

static void reset_left_stick(void) {
    left_stick_x = 0.0f;
    left_stick_y = 0.0f;
    pending_left_stick = false;
}

static void reset_triggers(void) {
    left_trigger = 0.0f;
    right_trigger = 0.0f;
    pending_triggers = false;
}

static bool open_gamepad(SDL_JoystickID instance_id) {
    if (active_gamepad != NULL) {
        return true;
    }
    if (!is_dualsense(instance_id)) {
        return false;
    }
    active_gamepad = SDL_OpenGamepad(instance_id);
    if (active_gamepad == NULL) {
        return false;
    }
    left_stick_x = normalized_axis(
        SDL_GetGamepadAxis(active_gamepad, SDL_GAMEPAD_AXIS_LEFTX));
    left_stick_y = normalized_axis(
        SDL_GetGamepadAxis(active_gamepad, SDL_GAMEPAD_AXIS_LEFTY));
    left_trigger = normalized_trigger(
        SDL_GetGamepadAxis(active_gamepad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER));
    right_trigger = normalized_trigger(
        SDL_GetGamepadAxis(active_gamepad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER));
    pending_left_stick = true;
    pending_triggers = true;
    pending_connected = true;
    return true;
}

static int32_t semantic_button(Uint8 button) {
    switch ((SDL_GamepadButton)button) {
        case SDL_GAMEPAD_BUTTON_SOUTH:
            return HELM_BUTTON_CROSS;
        case SDL_GAMEPAD_BUTTON_EAST:
            return HELM_BUTTON_CIRCLE;
        case SDL_GAMEPAD_BUTTON_BACK:
            return HELM_BUTTON_CREATE;
        case SDL_GAMEPAD_BUTTON_START:
            return HELM_BUTTON_OPTIONS;
        case SDL_GAMEPAD_BUTTON_MISC1:
            return HELM_BUTTON_MICROPHONE;
        case SDL_GAMEPAD_BUTTON_TOUCHPAD:
            return HELM_BUTTON_TOUCHPAD;
        case SDL_GAMEPAD_BUTTON_DPAD_UP:
            return HELM_BUTTON_DPAD_UP;
        case SDL_GAMEPAD_BUTTON_DPAD_DOWN:
            return HELM_BUTTON_DPAD_DOWN;
        default:
            return HELM_BUTTON_UNKNOWN;
    }
}

bool HelmSDLStart(char *error_buffer, int32_t error_capacity) {
    if (initialized) {
        return true;
    }

    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_PS5, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_ENHANCED_REPORTS, "auto");

    if (!SDL_Init(SDL_INIT_GAMEPAD | SDL_INIT_EVENTS)) {
        copy_text(error_buffer, (size_t)error_capacity, SDL_GetError());
        return false;
    }
    initialized = true;

    int count = 0;
    SDL_JoystickID *gamepads = SDL_GetGamepads(&count);
    if (gamepads != NULL) {
        for (int index = 0; index < count; index++) {
            if (is_dualsense(gamepads[index])) {
                if (!open_gamepad(gamepads[index])) {
                    copy_text(error_buffer, (size_t)error_capacity, SDL_GetError());
                    SDL_free(gamepads);
                    return false;
                }
                break;
            }
        }
    }
    SDL_free(gamepads);
    return true;
}

bool HelmSDLPoll(HelmSDLEvent *output) {
    if (!initialized || output == NULL) {
        return false;
    }
    clear_event(output);

    if (pending_connected && active_gamepad != NULL) {
        pending_connected = false;
        output->kind = HELM_SDL_EVENT_CONNECTED;
        copy_text(output->text, sizeof(output->text), SDL_GetGamepadName(active_gamepad));
        return true;
    }

    if (pending_left_stick && active_gamepad != NULL) {
        pending_left_stick = false;
        output->kind = HELM_SDL_EVENT_LEFT_STICK;
        output->x = left_stick_x;
        output->y = left_stick_y;
        return true;
    }

    if (pending_triggers && active_gamepad != NULL) {
        pending_triggers = false;
        output->kind = HELM_SDL_EVENT_TRIGGERS;
        output->x = left_trigger;
        output->y = right_trigger;
        return true;
    }

    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        switch (event.type) {
            case SDL_EVENT_GAMEPAD_ADDED:
                if (active_gamepad == NULL && is_dualsense(event.gdevice.which)) {
                    if (open_gamepad(event.gdevice.which)) {
                        pending_connected = false;
                        output->kind = HELM_SDL_EVENT_CONNECTED;
                        copy_text(output->text, sizeof(output->text), SDL_GetGamepadName(active_gamepad));
                    } else {
                        output->kind = HELM_SDL_EVENT_ERROR;
                        copy_text(output->text, sizeof(output->text), SDL_GetError());
                    }
                    return true;
                }
                break;

            case SDL_EVENT_GAMEPAD_REMOVED:
                if (event_matches_active(event.gdevice.which)) {
                    SDL_CloseGamepad(active_gamepad);
                    active_gamepad = NULL;
                    reset_left_stick();
                    reset_triggers();
                    output->kind = HELM_SDL_EVENT_DISCONNECTED;
                    return true;
                }
                break;

            case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
            case SDL_EVENT_GAMEPAD_BUTTON_UP:
                if (event_matches_active(event.gbutton.which)) {
                    int32_t button = semantic_button(event.gbutton.button);
                    if (button != HELM_BUTTON_UNKNOWN) {
                        output->kind = HELM_SDL_EVENT_BUTTON;
                        output->button = button;
                        output->pressed = event.gbutton.down ? 1 : 0;
                        return true;
                    }
                }
                break;

            case SDL_EVENT_GAMEPAD_AXIS_MOTION:
                if (event_matches_active(event.gaxis.which)) {
                    if (event.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX ||
                        event.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY) {
                        float value = normalized_axis(event.gaxis.value);
                        if (event.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX) {
                            left_stick_x = value;
                        } else {
                            left_stick_y = value;
                        }
                        output->kind = HELM_SDL_EVENT_LEFT_STICK;
                        output->x = left_stick_x;
                        output->y = left_stick_y;
                        return true;
                    }
                    if (event.gaxis.axis == SDL_GAMEPAD_AXIS_RIGHTY) {
                        output->kind = HELM_SDL_EVENT_RIGHT_Y;
                        output->value = normalized_axis(event.gaxis.value);
                        return true;
                    }
                    if (event.gaxis.axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER ||
                        event.gaxis.axis == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) {
                        float value = normalized_trigger(event.gaxis.value);
                        if (event.gaxis.axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER) {
                            left_trigger = value;
                        } else {
                            right_trigger = value;
                        }
                        output->kind = HELM_SDL_EVENT_TRIGGERS;
                        output->x = left_trigger;
                        output->y = right_trigger;
                        return true;
                    }
                }
                break;

            case SDL_EVENT_GAMEPAD_TOUCHPAD_DOWN:
            case SDL_EVENT_GAMEPAD_TOUCHPAD_MOTION:
            case SDL_EVENT_GAMEPAD_TOUCHPAD_UP:
                if (event_matches_active(event.gtouchpad.which)) {
                    output->kind = event.type == SDL_EVENT_GAMEPAD_TOUCHPAD_DOWN
                        ? HELM_SDL_EVENT_TOUCH_DOWN
                        : event.type == SDL_EVENT_GAMEPAD_TOUCHPAD_UP
                            ? HELM_SDL_EVENT_TOUCH_UP
                            : HELM_SDL_EVENT_TOUCH_MOVE;
                    output->finger = event.gtouchpad.finger;
                    output->x = event.gtouchpad.x;
                    output->y = event.gtouchpad.y;
                    output->value = event.gtouchpad.pressure;
                    return true;
                }
                break;

            default:
                break;
        }
    }
    return false;
}

void HelmSDLStop(void) {
    if (active_gamepad != NULL) {
        SDL_CloseGamepad(active_gamepad);
        active_gamepad = NULL;
    }
    pending_connected = false;
    reset_left_stick();
    reset_triggers();
    if (initialized) {
        SDL_QuitSubSystem(SDL_INIT_GAMEPAD | SDL_INIT_EVENTS);
        initialized = false;
    }
}

bool HelmSDLHasMicrophoneButton(void) {
    return active_gamepad != NULL &&
        SDL_GamepadHasButton(active_gamepad, SDL_GAMEPAD_BUTTON_MISC1);
}

int32_t HelmSDLTouchpadCount(void) {
    return active_gamepad == NULL ? 0 : SDL_GetNumGamepadTouchpads(active_gamepad);
}

int32_t HelmSDLConnectionState(void) {
    return active_gamepad == NULL ? -1 : (int32_t)SDL_GetGamepadConnectionState(active_gamepad);
}

bool HelmSecureInputEnabled(void) {
    return IsSecureEventInputEnabled();
}
