# Contributing

Pick a small idea from [the roadmap](docs/ROADMAP.md), make it work locally, and open a pull request with what changed and what you tested. Screenshots are welcome for UI changes; use synthetic text.

Run the offline checks from the README. Model-dependent experiments should be opt-in and should record the exact model/backend used. Distinguish measured results from expected behavior.

Do not commit API keys, recordings, exported document packages, model weights, generated app bundles, local configuration, or benchmark dumps containing real documents. Use `.env.example` for configuration names and placeholders. The publication check is one safeguard, not a substitute for reviewing your diff.
