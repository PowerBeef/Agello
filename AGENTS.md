# AGENTS.md

## Testing

- Test on the physical iPhone only. Do not use the simulator (no builds, tests, or screenshots there).
- Run suites with `scripts/device-harness.sh` (`unit`, `inference`, `files`, `ui`, `all`, plus opt-in `thinking`, `memory`, `calibrate`, `probes`). The iPhone must be connected and unlocked.
- Don't edit source files while a harness run is building: stage changes elsewhere and apply them after the run.
- Commit after each verified chunk; push only when asked.
