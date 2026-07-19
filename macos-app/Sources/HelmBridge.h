#ifndef HELM_BRIDGE_H
#define HELM_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

enum {
    HELM_SDL_EVENT_NONE = 0,
    HELM_SDL_EVENT_CONNECTED = 1,
    HELM_SDL_EVENT_DISCONNECTED = 2,
    HELM_SDL_EVENT_BUTTON = 3,
    HELM_SDL_EVENT_RIGHT_Y = 4,
    HELM_SDL_EVENT_TOUCH_DOWN = 5,
    HELM_SDL_EVENT_TOUCH_MOVE = 6,
    HELM_SDL_EVENT_TOUCH_UP = 7,
    HELM_SDL_EVENT_ERROR = 8,
    HELM_SDL_EVENT_LEFT_STICK = 9,
    HELM_SDL_EVENT_TRIGGERS = 10
};

enum {
    HELM_BUTTON_UNKNOWN = 0,
    HELM_BUTTON_SOUTH = 1,
    HELM_BUTTON_EAST = 2,
    HELM_BUTTON_WEST = 3,
    HELM_BUTTON_NORTH = 4,
    HELM_BUTTON_BACK = 5,
    HELM_BUTTON_GUIDE = 6,
    HELM_BUTTON_START = 7,
    HELM_BUTTON_LEFT_STICK = 8,
    HELM_BUTTON_RIGHT_STICK = 9,
    HELM_BUTTON_LEFT_SHOULDER = 10,
    HELM_BUTTON_RIGHT_SHOULDER = 11,
    HELM_BUTTON_DPAD_UP = 12,
    HELM_BUTTON_DPAD_DOWN = 13,
    HELM_BUTTON_DPAD_LEFT = 14,
    HELM_BUTTON_DPAD_RIGHT = 15,
    HELM_BUTTON_MISC1 = 16,
    HELM_BUTTON_RIGHT_PADDLE1 = 17,
    HELM_BUTTON_LEFT_PADDLE1 = 18,
    HELM_BUTTON_RIGHT_PADDLE2 = 19,
    HELM_BUTTON_LEFT_PADDLE2 = 20,
    HELM_BUTTON_TOUCHPAD = 21,
    HELM_BUTTON_MISC2 = 22,
    HELM_BUTTON_MISC3 = 23,
    HELM_BUTTON_MISC4 = 24,
    HELM_BUTTON_MISC5 = 25,
    HELM_BUTTON_MISC6 = 26
};

enum {
    HELM_CONTROLLER_FAMILY_GENERIC = 0,
    HELM_CONTROLLER_FAMILY_PLAYSTATION = 1,
    HELM_CONTROLLER_FAMILY_XBOX = 2,
    HELM_CONTROLLER_FAMILY_NINTENDO = 3
};

typedef struct HelmSDLEvent {
    int32_t kind;
    int32_t button;
    int32_t pressed;
    int32_t finger;
    int32_t controller_family;
    int32_t connection;
    int32_t vendor_id;
    int32_t product_id;
    float x;
    float y;
    float value;
    char text[160];
} HelmSDLEvent;

typedef struct HelmSDLAnalogState {
    int32_t connected;
    float left_x;
    float left_y;
    float right_y;
    float left_trigger;
    float right_trigger;
} HelmSDLAnalogState;

bool HelmSDLStart(char *error_buffer, int32_t error_capacity);
bool HelmSDLPoll(HelmSDLEvent *event);
bool HelmSDLReadAnalogState(HelmSDLAnalogState *state);
void HelmSDLStop(void);
bool HelmSDLHasMicrophoneButton(void);
int32_t HelmSDLTouchpadCount(void);
int32_t HelmSDLConnectionState(void);
bool HelmSDLButtonPressed(int32_t button);
bool HelmSDLHasRumble(void);
bool HelmSDLRumble(uint16_t low_frequency, uint16_t high_frequency, uint32_t duration_ms);
void HelmSDLStopRumble(void);
bool HelmSecureInputEnabled(void);

#endif
