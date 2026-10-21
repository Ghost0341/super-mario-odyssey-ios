# Validation and current limits

## Accepted physical-device behavior

- M5 iPad Pro 13-inch: 4:3 world/HUD proportions, gameplay, sound and controls.
- iPhone 17 Pro Max: 239:110 gameplay/HUD and sound/controls; generated
  presentation observed around 120 displayed FPS in a gameplay sample.
- DualSense: live motion consumed by the game; authored left/right rumble;
  backflips accepted by the player; five successive held-trigger long jumps
  all produced the intended recoil, including rolling follow-ups.
- Wall-jump and side-flip updates were installed along with frame generation;
  the player reported the update working well. This is not certification of
  every haptic event, level, cutscene, controller or long session.
- The original iPad save was preserved byte-for-byte across the cloud update.
  Its complete committed digest was imported and verified on the iPhone before
  guest boot. The phone also uploaded later game saves.

## Known limits

- Three thunder-effect geometry shaders remain unsupported in the original
  tested shader set. Full-game visual correctness isn't certified.
- Internal rendering is 1600×900. Camera/display aspect is separate from raster
  resolution. The two presets are explicit, not universal auto-layout.
- 120 FPS is optional frame interpolation, with the simulation at 60 Hz.
  Hardware support, latency, artifacts, heat and sustained performance vary.
- Cloud save capture failed intermittently on some phone commits. The included
  EINTR retry fix preserves all consistency guards and improves diagnostics;
  the actual failing device branch, a full live retest of that fix and the
  reverse phone-to-iPad handoff are still unverified.
- Xcode 27 is the tested build toolchain; deployment minimum is iOS 26. Other
  devices, low-memory phones, free-account signing and ad hoc signing are unverified.
- A clean source build/signing-helper check does not automatically install or
  replace the already tested apps. New packaged artifacts need their own live QA.

## Repository workflow verification

The portable workflow was exercised with Xcode 27.1 and the original local
cartridge XCI plus update 1.4.1 NSP, in an independent private work directory.
It rebuilt the extractor from source, extracted and integrity-checked the merged
game, rewrote all three modules, split 27,984 shaders, prepared the matching HUD,
compiled the app and packed a private IPA. The shader pass reused a verified
local cache: 27,981 were ready and the same three documented shaders failed.
This was a full input-to-IPA check, not a new cold compile of every shader.

Separate extracted-file builds produced both the iPad and iPhone variants. All
209 output archive hashes for each preset match the accepted local display
build, and the phone rewritten-module hash matches its accepted camera/haptic
module. The controller, cloud and interpolation runtime sources are unchanged
from the local port. Both variants were signed and strictly verified with an
existing development profile; the phone check included its CloudKit entitlements.
No device app was replaced during repository validation. Automatic creation of
a new developer team's profile is not covered by those signing checks.

A clean source clone passed the game-free suite: 24 Python tests, native
controller/observer/viewport checks, save-commit callback tests, 146 save-archive
checks, and 17 coordinator scenarios with 153 checks. GitHub Actions runs the
same game-free suite. Private inputs, caches, IPAs, signing receipts and logs
are not uploaded to GitHub.

## Game-free checks

```sh
python3 tools/check.py
```

The checks cover structural layout handling with synthetic archives, preset and
CloudKit configuration, exact-profile signing policy, controller transport and
effect policy, gameplay-observer guards, presentation geometry, save archive
integrity/atomic restore, and the production CloudKit coordinator with controlled
transport callbacks. No real cloud account or device is touched.

## Local input verification

With the virtual environment active, use the same personal files as the port:

```sh
python tools/odyssey.py --extracted-dir /path/to/merged-1.4.1 \
  --preset ipad --prepare-only --work /path/to/private-ipad-check
python tools/odyssey.py --extracted-dir /path/to/merged-1.4.1 \
  --preset iphone --prepare-only --work /path/to/private-iphone-check
```

Both commands validate all three module hashes and the rewritten camera/haptic
guards. They create and read back the 209 corrected layout archives, hash-check
the original sources after preparation, and write private receipts. They never
sign or install. Optional `--rewritten` reuses an already checked local rewrite.

Before any requested live update, save and close the app, take a stable backup,
preserve bundle/team identity, install, then compare every save file before
launch. Verify gameplay, round HUD elements, dialogue/loading transitions,
controller actions and foreground/background behavior. Test cloud handoffs one
direction at a time and distinguish acknowledged digests from merely queued work.
