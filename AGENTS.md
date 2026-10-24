# Repository instructions

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing this repository. Use the existing architecture and shared checks; keep changes limited to the requested behavior.

- Make reasonable reversible implementation decisions without repeated confirmation. Explain consequential assumptions and genuine blockers.
- Preserve unrelated changes. Keep current contracts, tests and generated plugin files consistent.
- Use `python3 scripts/check.py` for full device-free validation; select narrower checks only when justified by scope and report what was not run.
- Device acceptance is separate and explicit. Never replay uncertain phone input, expose private captures or treat host tests as physical-device evidence.
- Keep process reports and raw evidence in `.local/`; public docs describe durable behavior. Use the commit and PR conventions in CONTRIBUTING.md.
