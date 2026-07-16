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
    HELM_BUTTON_CROSS = 1,
    HELM_BUTTON_CIRCLE = 2,
    HELM_BUTTON_CREATE = 3,
    HELM_BUTTON_OPTIONS = 4,
    HELM_BUTTON_MICROPHONE = 5,
    HELM_BUTTON_TOUCHPAD = 6,
    HELM_BUTTON_DPAD_UP = 7,
    HELM_BUTTON_DPAD_DOWN = 8
};

typedef struct HelmSDLEvent {
    int32_t kind;
    int32_t button;
    int32_t pressed;
    int32_t finger;
    float x;
    float y;
    float value;
    char text[160];
} HelmSDLEvent;

bool HelmSDLStart(char *error_buffer, int32_t error_capacity);
bool HelmSDLPoll(HelmSDLEvent *event);
void HelmSDLStop(void);
bool HelmSDLHasMicrophoneButton(void);
int32_t HelmSDLTouchpadCount(void);
int32_t HelmSDLConnectionState(void);
bool HelmSecureInputEnabled(void);

#endif
