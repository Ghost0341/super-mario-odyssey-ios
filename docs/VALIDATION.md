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
