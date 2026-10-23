// Three native switches behind the deliberate gear; advanced values stay stored.
#import "DmSettings.h"
#import "DmMotion.h"
#import "DmDeviceHaptics.h"
#include "game_profile.h"

static NSString *const framegenKey=@"DmFrameGeneration";
static BOOL explicitFramegenEnvironment;
void dm_settings_apply_boot_preferences(void) {
    explicitFramegenEnvironment=getenv("DM_FRAMEGEN")!=NULL;
    NSNumber *saved=[NSUserDefaults.standardUserDefaults objectForKey:framegenKey];
    if (saved&&!explicitFramegenEnvironment) setenv("DM_FRAMEGEN",saved.boolValue?"1":"0",0);
}
@interface DmSettingsVC : UITableViewController <UIAdaptivePresentationControllerDelegate>
@end
@implementation DmSettingsVC
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"Settings";
    self.tableView.rowHeight=76;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section; return 3;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    static NSString *const titles[]={@"Gyro",@"Device haptics",@"Also with controller"};
    NSInteger row=indexPath.row;
    BOOL supported=dm_device_haptics_settings_supported();
    BOOL haptics=dm_device_haptics_settings_enabled();
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=titles[row]; cell.selectionStyle=UITableViewCellSelectionStyleNone;
    cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.numberOfLines=0;
    if (row==1&&!supported) cell.detailTextLabel.text=@"Unavailable on this device";
    else if (row==2) cell.detailTextLabel.text=supported?@"Device vibration while a controller is connected":@"Requires device haptics";
    UISwitch *toggle=[UISwitch new]; toggle.tag=row;
    toggle.enabled=row==0||(supported&&(row==1||haptics));
    toggle.on=row==0?dm_motion_settings_enabled():supported&&(row==1?haptics:dm_device_haptics_settings_with_controller());
    toggle.accessibilityLabel=titles[row]; toggle.accessibilityHint=cell.detailTextLabel.text;
    [toggle addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView=toggle; return cell;
}
- (void)changed:(UISwitch *)toggle {
    if (toggle.tag==0) dm_motion_settings_set_enabled(toggle.on);
    else if (toggle.tag==1) dm_device_haptics_settings_set_enabled(toggle.on);
    else dm_device_haptics_settings_set_with_controller(toggle.on);
    [self.tableView reloadData];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:^{ dm_gamepad_settings_visible(NO); }]; }
- (void)presentationControllerDidDismiss:(UIPresentationController *)controller {
    (void)controller;dm_gamepad_settings_visible(NO);
}
@end
void dm_settings_present(UIViewController *presenter) {
    if (!presenter||!presenter.view.window||presenter.presentedViewController) return;
    DmSettingsVC *settings=[[DmSettingsVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:settings];
    navigation.modalPresentationStyle=UIModalPresentationPageSheet;
    navigation.preferredContentSize=CGSizeMake(420,390);
    navigation.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];
    navigation.sheetPresentationController.prefersGrabberVisible=YES;
    navigation.presentationController.delegate=settings;
    dm_gamepad_settings_visible(YES);
    [presenter presentViewController:navigation animated:YES completion:nil];
}
