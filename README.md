# skills-collection

Centralized repository for custom AI agent skills, third-party integrations, and profile definitions, managed via [skillm](https://github.com).

## Structure

- `custom/`: Custom skills developed from scratch.
- `third-party/`: External skills integrated via `git subtree` or manual import, allowing local customizations while preserving upstream sync capabilities.
- `profiles.toml`: Profile definitions for grouping skills by workflow or domain.

## Installation

Install skills from this collection using `skillm`:

```bash
skillm install tinchogb/skills-collection --global
```
