# Working on this port

This is an Odyssey-focused source snapshot of nxnative. Preserve upstream MIT
and third-party attribution; see docs/PROVENANCE.md. Public installation must
work without an AI assistant. Keep numbered installation steps at the bottom of
README.md, and keep flags/examples synchronized with the actual tools.

## Boundaries

- Never commit or publish ROMs, NSP/XCI/NCA, extracted ExeFS/RomFS, rewritten
  game modules, translated game shaders, fonts/icons extracted or copied from
  another product, saves, keys, certificates, provisioning profiles, signed apps,
  IPAs, private logs, account identifiers or device inventories.
- Game inputs and generated outputs must be outside this repository, even if
  ignored. `tools/audit_repo.py` checks the index; do not bypass it.
- Use the player's own keys; never print key values. Do not download game files.
- Default cloud sync stays off. Never bake a contributor's bundle/container,
  developer team, device ID, absolute home path or signing identity into source.
- Do not replace/reinstall a device app unless requested. Preserve bundle ID,
  signing team and byte-verified save backups for any requested device update.
- Do not claim a simulator, compile, mock, telemetry command, or CI pass proves
  physical gameplay, performance, adaptive-trigger feel, or real iCloud delivery.

## Implementation

- Exact supported title: 0100000000010000, update 1.4.1/v393216; module hashes
  and build IDs are in docs/INPUTS.md. Address-based changes fail closed on
  different builds and expected instruction bytes. Do not weaken those gates.
- Per-game values belong in dm/games/<title-id>/game.tsv. Display camera and HUD
  must be corrected together. iPad and iPhone preparation must not mutate inputs.
- Preserve 60 Hz simulation. Generated 120 FPS presentation is optional and must
  be described as interpolation. Never call it native 120 FPS rendering.
- Never hold the presentation mutex across Metal/drawable calls or frame-generator
  property calls; preserve cancellation, reservation and queue ownership rules.
- Haptics follow authored vibration and verified gameplay events. Maintain
  lifecycle/disconnect/expiry guards and the rolling follow-up long-jump path.
- Save sync publishes only complete committed snapshots. Keep integrity checks,
  account pinning, compare-and-swap cloud writes, conflict backups, explicit
  conflict choices, and preboot-only import. Never overwrite a mounted save.
- Keep changes scoped and preserve unrelated work. Source and docs are English.

## Validation

Run `python3 tools/check.py` before committing. It runs game-free layout,
configuration, signing-policy, haptic, observer, viewport, archive and CloudKit
coordinator checks. Record any unsupported platform or skipped live check.
Use docs/VALIDATION.md for optional local-file checks; never check in fixtures
copied from a game. A clean clone must pass game-free tests.

For shader-chain changes, follow the upstream procedure: regenerate dmsh_chain.h,
rebuild affected Mac/iOS shaders, regenerate c1_full.tsv/cb_extent.tsv, then
rebuild the host. The bundled translator matches dmsh_chain.lock; recompiling
it arbitrarily changes fingerprints. Review the actual affected profiles.

Before publishing, run `python3 tools/audit_repo.py`, inspect the staged diff and
file list, and verify no build/signing artifacts are tracked. Do not create
game-bearing Actions artifacts or Releases. Use the human's configured Git
identity for commits. Commit/push only within the user's requested scope.
