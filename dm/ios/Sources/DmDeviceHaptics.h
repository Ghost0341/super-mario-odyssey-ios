// A separate local-device sink; all state is owned by the feedback output queue.
#pragma once
#import <UIKit/UIKit.h>
#include "odyssey_feedback.h"
void dm_device_haptics_initialize(dispatch_queue_t queue, dispatch_queue_t diagnostics, dispatch_block_t changed);
void dm_device_haptics_context(BOOL foreground, BOOL controller, uint64_t now);
BOOL dm_device_haptics_enabled(void);
void dm_device_haptics_observe(dm_odyssey_feedback_event event, uint64_t now);
void dm_device_haptics_tick(uint64_t now, uint64_t frameAt);
UIButton *dm_device_haptics_settings_button(void);
UIMenu *dm_device_haptics_settings_menu(void);
BOOL dm_device_haptics_settings_supported(void);
BOOL dm_device_haptics_settings_enabled(void);
BOOL dm_device_haptics_settings_with_controller(void);
void dm_device_haptics_settings_set_enabled(BOOL enabled);
void dm_device_haptics_settings_set_with_controller(BOOL enabled);
