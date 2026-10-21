# Claude project guide

Read [AGENTS.md](AGENTS.md) first; its boundaries and validation requirements
apply here too. This repo must remain useful to humans without an AI assistant.

Start with README.md, docs/INPUTS.md, docs/INSTALL.md, docs/VALIDATION.md and
docs/PROVENANCE.md. Player commands live in tools/odyssey.py and
tools/sign_install.py; shared runtime and rewriting live in dm/.

Use `python3 tools/check.py` and `python3 tools/audit_repo.py`. Game assets,
generated game code/shaders, keys, profiles, saves and IPAs stay outside this
checkout and must never enter Git history or public build artifacts. Cloud
support is opt-in and uses the builder's own container. Do not weaken exact-build,
save-integrity, or controller lifecycle guards to make a check pass.

Keep installation instructions as the final section of README.md. Verify real
CLI behavior before documenting it. Distinguish unit-test/compile proof from
physical gameplay, haptic feel, performance and end-to-end save-sync proof.
