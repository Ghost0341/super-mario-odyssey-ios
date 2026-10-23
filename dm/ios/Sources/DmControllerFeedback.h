// The selected physical controller owns buttons/feedback; DmMotion arbitrates gyro.
#pragma once
#import <GameController/GameController.h>
@class UIButton;
@class UIMenu;
void dm_controller_feedback_attach(GCController *controller);
void dm_controller_feedback_focus(int active);
void dm_controller_feedback_travel(float left, float right);
UIButton *dm_controller_feedback_device_settings_button(void);
UIMenu *dm_controller_feedback_device_settings_menu(void);
