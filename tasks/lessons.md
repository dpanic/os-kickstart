# Lessons Learned

## Releases

- **Always use `tooling/release.sh`** for creating releases. Never use `gh release create` manually.
  - The script handles: version auto-increment, clean tree check, build, test, tag creation, and push.
  - GitHub Actions picks up the tag and creates the release automatically.
  - Learned: 2026-03-29 — manually created v1.1.0 instead of using the existing release script.

## AppArmor Monitor

- **`aa-status --json` uses a flat dict, not nested mode dicts.** Structure is `{"profiles": {"name": "mode"}}`, NOT `{"profiles": {"enforce": {...}, "complain": {...}}}`.
  - Always count by iterating values, not by sub-key lookup.
  - Use the same parsing method (JSON or text) for both baseline and current to avoid mismatches.
  - Learned: 2026-03-29 — false positive tampering alert because baseline parsed as 0/0 due to wrong JSON structure assumption, while current used grep -c on text output returning 2/2.
