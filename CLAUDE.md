# CLAUDE.md

## Project Overview

This is a starter template repository for the **threetwentytwos** organization. It provides foundational CI/CD, security, and configuration infrastructure but does not yet contain application source code or a chosen technology stack.

## Repository Structure

```
th/
├── .github/
│   └── workflows/
│       └── blank.yml          # GitHub Actions CI workflow
├── scripts/
│   └── init-artifact.sh       # CI/CD artifact initialization script
├── CLAUDE.md                  # This file — guidance for AI assistants
├── SECURITY.md                # Security policy and vulnerability reporting
└── TEST_COVERAGE_ANALYSIS.md  # Testing strategy and coverage recommendations
```

## CI/CD

- **Platform:** GitHub Actions
- **Workflow:** `.github/workflows/blank.yml` — triggers on push and pull requests; runs on `ubuntu-latest`
- **Artifact script:** `scripts/init-artifact.sh` — sets up artifact directories, generates build metadata (JSON). Supports `--root DIR`, `--clean`, and `--help` flags.

## Testing Strategy

No test framework is configured yet. `TEST_COVERAGE_ANALYSIS.md` documents recommended coverage targets:

| Area                        | Target |
|-----------------------------|--------|
| Core business logic         | 90%+   |
| Authentication & auth       | 95%+   |
| API endpoints/handlers      | 80%+   |
| Database queries            | 80%+   |
| Data validation/parsing     | 90%+   |
| Utility functions           | 90%+   |
| Error handling              | 70%+   |

Recommended test distribution: ~70% unit, ~20% integration, ~10% end-to-end.

## Git Conventions

- **Default branch:** `master`
- **Branch naming:** `claude/<description>-<id>` (e.g., `claude/add-feature-xYz12`)
- **Commit messages:** imperative mood, present tense, concise first line (e.g., "Add basic CI workflow configuration")
- No `.gitignore` is configured yet — add one when a technology stack is chosen.

## Key Notes for AI Assistants

- There is no source code, build system, or dependency manifest yet. The technology stack has not been chosen.
- No linting, formatting, or editor configuration exists.
- No README exists — consider creating one when the project purpose is defined.
- The `SECURITY.md` uses a template versioning scheme (5.1.x, 4.0.x) that should be updated to reflect actual releases.
- When adding source code, also add a `.gitignore` appropriate for the chosen language/framework and update the CI workflow (`blank.yml`) with real build/test/deploy steps.
