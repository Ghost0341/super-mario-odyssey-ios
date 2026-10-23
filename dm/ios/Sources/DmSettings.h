// Deliberate gear entry point; custom settings never overlay gameplay as buttons.
#pragma once
#import <UIKit/UIKit.h>
void dm_settings_present(UIViewController *presenter);
void dm_settings_apply_boot_preferences(void);
void dm_gamepad_settings_visible(BOOL visible);
