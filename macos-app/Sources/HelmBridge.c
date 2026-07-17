#include "HelmBridge.h"

#include <Carbon/Carbon.h>
#include <CoreVideo/CoreVideo.h>
#include <SDL3/SDL.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdatomic.h>
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
static CVDisplayLinkRef cadence_display_link = NULL;
static HelmCadenceCallback cadence_callback = NULL;
static void *cadence_context = NULL;
static _Atomic bool cadence_delivery_pending = false;

static void deliver_cadence_on_main(void *unused) {
    (void)unused;
    atomic_store_explicit(&cadence_delivery_pending, false, memory_order_release);
    if (cadence_callback != NULL) {
        cadence_callback(cadence_context);
    }
}

static CVReturn cadence_display_callback(
    CVDisplayLinkRef display_link,
    const CVTimeStamp *now,
    const CVTimeStamp *output_time,
    CVOptionFlags flags_in,
    CVOptionFlags *flags_out,
    void *context) {
    (void)display_link;
    (void)now;
    (void)output_time;
    (void)flags_in;
    (void)flags_out;
    (void)context;
    bool was_pending = atomic_exchange_explicit(
        &cadence_delivery_pending,
        true,
        memory_order_acq_rel);
    if (!was_pending) {
        dispatch_async_f(dispatch_get_main_queue(), NULL, deliver_cadence_on_main);
    }
    return kCVReturnSuccess;
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
            if (is_supported_gamepad(gamepads[index])) {
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
        copy_controller_identity(output);
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
                    return true;
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
                    return true;
                }
                break;

            default:
                break;
        }
    }
    return false;
}

bool HelmSDLReadAnalogState(HelmSDLAnalogState *state) {
    if (state == NULL) {
        return false;
    }
    memset(state, 0, sizeof(*state));
    if (!initialized || active_gamepad == NULL) {
        return false;
    }

    SDL_UpdateGamepads();
    if (!SDL_GamepadConnected(active_gamepad)) {
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
    return true;
}

void HelmSDLStop(void) {
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

bool HelmSDLButtonPressed(int32_t button) {
    if (active_gamepad == NULL || button < HELM_BUTTON_SOUTH ||
        button > HELM_BUTTON_MISC6) {
        return false;
    }
    SDL_GamepadButton sdl_button = (SDL_GamepadButton)(button - 1);
    return SDL_GetGamepadButton(active_gamepad, sdl_button);
}

bool HelmSDLHasRumble(void) {
    if (active_gamepad == NULL) {
        return false;
    }
    SDL_PropertiesID properties = SDL_GetGamepadProperties(active_gamepad);
    return properties != 0 && SDL_GetBooleanProperty(
        properties,
        SDL_PROP_GAMEPAD_CAP_RUMBLE_BOOLEAN,
        false);
}

bool HelmSDLRumble(
    uint16_t low_frequency,
    uint16_t high_frequency,
    uint32_t duration_ms) {
    if (active_gamepad == NULL || duration_ms == 0 ||
        (low_frequency == 0 && high_frequency == 0) || !HelmSDLHasRumble()) {
        return false;
    }
    const uint32_t maximum_duration_ms = 250;
    if (duration_ms > maximum_duration_ms) {
        duration_ms = maximum_duration_ms;
    }
    return SDL_RumbleGamepad(
        active_gamepad,
        low_frequency,
        high_frequency,
        duration_ms);
}

void HelmSDLStopRumble(void) {
    stop_rumble();
}

bool HelmCadenceStart(HelmCadenceCallback callback, void *context) {
    HelmCadenceStop();
    if (callback == NULL) {
        return false;
    }
    cadence_callback = callback;
    cadence_context = context;
    atomic_store_explicit(&cadence_delivery_pending, false, memory_order_release);

    CVReturn status;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    status = CVDisplayLinkCreateWithActiveCGDisplays(&cadence_display_link);
    if (status == kCVReturnSuccess && cadence_display_link != NULL) {
        status = CVDisplayLinkSetOutputCallback(
            cadence_display_link,
            cadence_display_callback,
            NULL);
    }
    if (status == kCVReturnSuccess && cadence_display_link != NULL) {
        status = CVDisplayLinkStart(cadence_display_link);
    }
#pragma clang diagnostic pop
    if (status == kCVReturnSuccess) {
        return true;
    }
    HelmCadenceStop();
    return false;
}

void HelmCadenceStop(void) {
    cadence_callback = NULL;
    cadence_context = NULL;
    if (cadence_display_link != NULL) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CVDisplayLinkStop(cadence_display_link);
        CVDisplayLinkRelease(cadence_display_link);
#pragma clang diagnostic pop
        cadence_display_link = NULL;
    }
    atomic_store_explicit(&cadence_delivery_pending, false, memory_order_release);
}

bool HelmSecureInputEnabled(void) {
    return IsSecureEventInputEnabled();
}
