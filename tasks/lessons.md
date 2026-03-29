# Lessons Learned

## Releases

- **Always use `tooling/release.sh`** for creating releases. Never use `gh release create` manually.
  - The script handles: version auto-increment, clean tree check, build, test, tag creation, and push.
  - GitHub Actions picks up the tag and creates the release automatically.
  - Learned: 2026-03-29 — manually created v1.1.0 instead of using the existing release script.
