// One selected motion producer feeds the existing guest controller six-axis ABI.
#pragma once
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
void dm_motion_controller(GCController *controller, int foreground);
void dm_motion_orientation(UIInterfaceOrientation orientation);
NSDictionary *dm_motion_diagnostics(void);
UIButton *dm_motion_settings_button(void);
UIMenu *dm_motion_settings_menu(void);
BOOL dm_motion_settings_enabled(void);
void dm_motion_settings_set_enabled(BOOL enabled);
