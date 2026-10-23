# Production cloud-save coordinator tests

Run from the checkout:

```sh
sh dm/ios/tests/cloud_coordinator/run.sh
DM_CLOUD_TEST_SANITIZERS=address,undefined sh dm/ios/tests/cloud_coordinator/run.sh
DM_CLOUD_TEST_SANITIZERS=thread sh dm/ios/tests/cloud_coordinator/run.sh
```

The harness compiles the actual `DmCloudSave.m` and `DmSaveArchive.m` on macOS.
Only UIKit presentation/background-task objects, the container's account response,
and database operation delivery are replaced. Real Foundation files, real
`CKRecord`, `CKAsset`, `CKFetchRecordsOperation`, `CKModifyRecordsOperation`, the
production upload method, archive validation, restore, sync decisions and worker
coalescing all execute. The fake database asserts the production operation uses
`CKRecordSaveIfServerRecordUnchanged`, verifies the actual upload asset, and
rejects stale fixture record generations.

Seventeen scenarios cover first upload; fresh-phone preboot import; explicit
fresh-offline start and silent cached-offline start; unreadable local progress;
network/account errors; account changes; preserved divergent branches; explicit
boot conflict selection; missing-cloud explicit repair; CAS failure; metadata to
asset head changes; commits during upload; operation cancellation at expiration;
expiration during account lookup and foreground retry; a queued old background
completion; a commit arriving after the completion's busy check but before UIKit
ends its allowance; and the prohibition on importing over a mounted save.

`UIKitShim` prefixes all classes to avoid macOS private-framework class collisions.
Tests use isolated temporary Documents directories and never create a real
CloudKit container or database, contact an account, or mutate a device. The command
cleans its build directory; the successful test cleans every save fixture.

These tests validate the coordinator's local behavior and controlled callback
interleavings. They do not establish provisioning/CloudKit schema availability,
real iCloud delivery, or device background execution time. Long real network
timeouts are not exercised.

Persistence regressions use real Foundation atomic-write failures (a directory
at the state/journal file target), then repair the fixture and retry. They cover
account-pin failure, server-confirmed ancestry persistence with a newer commit,
newest-journal coalescing/restart, import state/journal recovery without blank
replacement, and account changes after a pending acknowledgement. Local data
is synthetic; no disk filling, real account or device is used.
