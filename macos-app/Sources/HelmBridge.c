#include "HelmBridge.h"

#include <Carbon/Carbon.h>
#include <SDL3/SDL.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
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
static int32_t active_controller_family = HELM_CONTROLLER_FAMILY_GENERIC;
static int32_t active_connection = SDL_JOYSTICK_CONNECTION_UNKNOWN;
static Uint16 active_vendor_id = 0;
static Uint16 active_product_id = 0;
static pthread_mutex_t bridge_mutex = PTHREAD_MUTEX_INITIALIZER;

static void lock_bridge(void) {
    (void)pthread_mutex_lock(&bridge_mutex);
}

static void unlock_bridge(void) {
    (void)pthread_mutex_unlock(&bridge_mutex);
}

static void stop_rumble(void) {
    if (active_gamepad != NULL) {
        (void)SDL_RumbleGamepad(active_gamepad, 0, 0, 0);
    }
}

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

static bool is_supported_gamepad(SDL_JoystickID instance_id) {
    switch (SDL_GetGamepadTypeForID(instance_id)) {
        case SDL_GAMEPAD_TYPE_STANDARD:
        case SDL_GAMEPAD_TYPE_XBOX360:
        case SDL_GAMEPAD_TYPE_XBOXONE:
        case SDL_GAMEPAD_TYPE_PS4:
        case SDL_GAMEPAD_TYPE_PS5:
        case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO:
            return true;
        default:
            return false;
    }
}

static int32_t controller_family(SDL_GamepadType type) {
    switch (type) {
        case SDL_GAMEPAD_TYPE_PS4:
        case SDL_GAMEPAD_TYPE_PS5:
            return HELM_CONTROLLER_FAMILY_PLAYSTATION;
        case SDL_GAMEPAD_TYPE_XBOX360:
        case SDL_GAMEPAD_TYPE_XBOXONE:
            return HELM_CONTROLLER_FAMILY_XBOX;
        case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO:
        case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT:
        case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT:
        case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR:
            return HELM_CONTROLLER_FAMILY_NINTENDO;
        default:
            return HELM_CONTROLLER_FAMILY_GENERIC;
    }
}

static void copy_controller_identity(HelmSDLEvent *event) {
    event->controller_family = active_controller_family;
    event->connection = active_connection;
    event->vendor_id = (int32_t)active_vendor_id;
    event->product_id = (int32_t)active_product_id;
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
    if (!is_supported_gamepad(instance_id)) {
        return false;
    }
    active_gamepad = SDL_OpenGamepad(instance_id);
    if (active_gamepad == NULL) {
        return false;
    }
    active_controller_family = controller_family(SDL_GetGamepadType(active_gamepad));
    active_connection = (int32_t)SDL_GetGamepadConnectionState(active_gamepad);
    active_vendor_id = SDL_GetGamepadVendor(active_gamepad);
    active_product_id = SDL_GetGamepadProduct(active_gamepad);
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
    if (button >= (Uint8)SDL_GAMEPAD_BUTTON_COUNT) {
        return HELM_BUTTON_UNKNOWN;
    }
    return (int32_t)button + 1;
}

bool HelmSDLStart(char *error_buffer, int32_t error_capacity) {
    lock_bridge();
    if (initialized) {
        unlock_bridge();
        return true;
    }

    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_PS5, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_ENHANCED_REPORTS, "auto");

    if (!SDL_Init(SDL_INIT_GAMEPAD | SDL_INIT_EVENTS)) {
        copy_text(error_buffer, (size_t)error_capacity, SDL_GetError());
        unlock_bridge();
        return false;
    }
    initialized = true;

    int count = 0;
    SDL_JoystickID *gamepads = SDL_GetGamepads(&count);
    if (gamepads != NULL) {
        for (int index = 0; index < count; index++) {
            if (is_supported_gamepad(gamepads[index])) {
                if (!open_gamepad(gamepads[index])) {
                    copy_text(error_buffer, (size_t)error_capacity, SDL_GetError());
                    SDL_free(gamepads);
                    unlock_bridge();
                    return false;
                }
                break;
            }
        }
    }
    SDL_free(gamepads);
    unlock_bridge();
    return true;
}

bool HelmSDLPoll(HelmSDLEvent *output) {
    if (output == NULL) {
        return false;
    }
    clear_event(output);

    lock_bridge();
    if (!initialized) {
        unlock_bridge();
        return false;
    }
    if (pending_connected && active_gamepad != NULL) {
        pending_connected = false;
        output->kind = HELM_SDL_EVENT_CONNECTED;
        copy_controller_identity(output);
        copy_text(output->text, sizeof(output->text), SDL_GetGamepadName(active_gamepad));
        unlock_bridge();
        return true;
    }

    if (pending_left_stick && active_gamepad != NULL) {
        pending_left_stick = false;
        output->kind = HELM_SDL_EVENT_LEFT_STICK;
        output->x = left_stick_x;
        output->y = left_stick_y;
        unlock_bridge();
        return true;
    }

    if (pending_triggers && active_gamepad != NULL) {
        pending_triggers = false;
        output->kind = HELM_SDL_EVENT_TRIGGERS;
        output->x = left_trigger;
        output->y = right_trigger;
        unlock_bridge();
        return true;
    }
    unlock_bridge();

    SDL_Event event;
    int processed_events = 0;
    const int maximum_events_per_poll = 256;
    while (processed_events < maximum_events_per_poll && SDL_PollEvent(&event)) {
        processed_events++;
        bool produced_output = false;
        lock_bridge();
        if (!initialized) {
            unlock_bridge();
            return false;
        }
        switch (event.type) {
            case SDL_EVENT_GAMEPAD_ADDED:
                if (active_gamepad == NULL && is_supported_gamepad(event.gdevice.which)) {
                    if (open_gamepad(event.gdevice.which)) {
                        pending_connected = false;
                        output->kind = HELM_SDL_EVENT_CONNECTED;
                        copy_controller_identity(output);
                        copy_text(output->text, sizeof(output->text), SDL_GetGamepadName(active_gamepad));
                    } else {
                        output->kind = HELM_SDL_EVENT_ERROR;
                        copy_text(output->text, sizeof(output->text), SDL_GetError());
                    }
                    produced_output = true;
                }
                break;

            case SDL_EVENT_GAMEPAD_REMOVED:
                if (event_matches_active(event.gdevice.which)) {
                    stop_rumble();
                    SDL_CloseGamepad(active_gamepad);
                    active_gamepad = NULL;
                    reset_left_stick();
                    reset_triggers();
                    output->kind = HELM_SDL_EVENT_DISCONNECTED;
                    copy_controller_identity(output);
                    produced_output = true;
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
                        produced_output = true;
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
                    }
                    if (event.gaxis.axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER ||
                        event.gaxis.axis == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) {
                        float value = normalized_trigger(event.gaxis.value);
                        if (event.gaxis.axis == SDL_GAMEPAD_AXIS_LEFT_TRIGGER) {
                            left_trigger = value;
                        } else {
                            right_trigger = value;
                        }
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
                    produced_output = true;
                }
                break;

            default:
                break;
        }
        unlock_bridge();
        if (produced_output) {
            return true;
        }
    }
    return false;
}

bool HelmSDLReadAnalogState(HelmSDLAnalogState *state) {
    if (state == NULL) {
        return false;
    }
    memset(state, 0, sizeof(*state));
    lock_bridge();
    if (!initialized || active_gamepad == NULL) {
        unlock_bridge();
        return false;
    }

    SDL_UpdateGamepads();
    if (!SDL_GamepadConnected(active_gamepad)) {
        unlock_bridge();
        return false;
    }

    state->connected = 1;
    state->left_x = normalized_axis(
        SDL_GetGamepadAxis(active_gamepad, SDL_GAMEPAD_AXIS_LEFTX));
    state->left_y = normalized_axis(
        SDL_GetGamepadAxis(active_gamepad, SDL_GAMEPAD_AXIS_LEFTY));
    state->right_y = normalized_axis(
        SDL_GetGamepadAxis(active_gamepad, SDL_GAMEPAD_AXIS_RIGHTY));
    state->left_trigger = normalized_trigger(
        SDL_GetGamepadAxis(active_gamepad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER));
    state->right_trigger = normalized_trigger(
        SDL_GetGamepadAxis(active_gamepad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER));
    unlock_bridge();
    return true;
}

void HelmSDLStop(void) {
    lock_bridge();
    if (active_gamepad != NULL) {
        stop_rumble();
        SDL_CloseGamepad(active_gamepad);
        active_gamepad = NULL;
    }
    pending_connected = false;
    reset_left_stick();
    reset_triggers();
    active_controller_family = HELM_CONTROLLER_FAMILY_GENERIC;
    active_connection = SDL_JOYSTICK_CONNECTION_UNKNOWN;
    active_vendor_id = 0;
    active_product_id = 0;
    if (initialized) {
        SDL_QuitSubSystem(SDL_INIT_GAMEPAD | SDL_INIT_EVENTS);
        initialized = false;
    }
    unlock_bridge();
}

bool HelmSDLHasMicrophoneButton(void) {
    lock_bridge();
    bool result = active_gamepad != NULL &&
        SDL_GamepadHasButton(active_gamepad, SDL_GAMEPAD_BUTTON_MISC1);
    unlock_bridge();
    return result;
}

int32_t HelmSDLTouchpadCount(void) {
    lock_bridge();
    int32_t result = active_gamepad == NULL ? 0 : SDL_GetNumGamepadTouchpads(active_gamepad);
    unlock_bridge();
    return result;
}

int32_t HelmSDLConnectionState(void) {
    lock_bridge();
    int32_t result = active_gamepad == NULL
        ? -1
        : (int32_t)SDL_GetGamepadConnectionState(active_gamepad);
    unlock_bridge();
    return result;
}

bool HelmSDLButtonPressed(int32_t button) {
    lock_bridge();
    if (active_gamepad == NULL || button < HELM_BUTTON_SOUTH ||
        button > HELM_BUTTON_MISC6) {
        unlock_bridge();
        return false;
    }
    SDL_GamepadButton sdl_button = (SDL_GamepadButton)(button - 1);
    bool result = SDL_GetGamepadButton(active_gamepad, sdl_button);
    unlock_bridge();
    return result;
}

static bool has_rumble_locked(void) {
    if (active_gamepad == NULL) {
        return false;
    }
    SDL_PropertiesID properties = SDL_GetGamepadProperties(active_gamepad);
    return properties != 0 && SDL_GetBooleanProperty(
        properties,
        SDL_PROP_GAMEPAD_CAP_RUMBLE_BOOLEAN,
        false);
}

bool HelmSDLHasRumble(void) {
    lock_bridge();
    bool result = has_rumble_locked();
    unlock_bridge();
    return result;
}

bool HelmSDLRumble(
    uint16_t low_frequency,
    uint16_t high_frequency,
    uint32_t duration_ms) {
    lock_bridge();
    if (active_gamepad == NULL || duration_ms == 0 ||
        (low_frequency == 0 && high_frequency == 0) || !has_rumble_locked()) {
        unlock_bridge();
        return false;
    }
    const uint32_t maximum_duration_ms = 250;
    if (duration_ms > maximum_duration_ms) {
        duration_ms = maximum_duration_ms;
    }
    bool result = SDL_RumbleGamepad(
        active_gamepad,
        low_frequency,
        high_frequency,
        duration_ms);
    unlock_bridge();
    return result;
}

void HelmSDLStopRumble(void) {
    lock_bridge();
    stop_rumble();
    unlock_bridge();
}

bool HelmSecureInputEnabled(void) {
    return IsSecureEventInputEnabled();
}
