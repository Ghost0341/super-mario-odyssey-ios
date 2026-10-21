// The selected physical controller owns input, motion, and feedback together.
#pragma once
#import <GameController/GameController.h>
void dm_controller_feedback_attach(GCController *controller);
void dm_controller_feedback_focus(int active);
void dm_controller_feedback_travel(float left, float right);
