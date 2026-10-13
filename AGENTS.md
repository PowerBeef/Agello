# AGENTS.md

## Testing

- Test on the physical iPhone only. Do not use the simulator (no builds, tests, or screenshots there).
- Run suites with `scripts/device-harness.sh` (`unit`, `inference`, `files`, `ui`, `all`, plus opt-in `thinking`, `memory`, `calibrate`, `probes`). The iPhone must be connected and unlocked.
- Don't edit source files while a harness run is building: stage changes elsewhere and apply them after the run.
- Commit after each verified chunk; push only when asked.

## Project skills

Read the matching skill in `.opencode/skills/` before the work it covers:

- `irtchat-device-testing`: running and reading the harness, known failures.
- `irtchat-inference-rules`: before changing the engine, `AppState` generation, budgets, or helpers.
- `irtchat-litert-update`: updating the vendored LiteRT-LM.
- `irtchat-release`: TestFlight and App Store preparation.
