---
name: update-dependencies
description: Update project dependencies and open a PR.
disable-model-invocation: true
---

# Update Dependencies

1. Run `bun outdated --recursive --minimum-release-age=259200`

2. Rewrite each relevant `package.json` entry to the `Latest` version from `bun outdated`

3. Run `bun install`

4. For expo workspaces:
    - Run `bun expo install --fix`
    - If Expo reverts a version, that version is the source of truth for the whole repo
    - Replace `catalog:` rewrites with root `catalog` changes and apply Expo’s final version in the root `catalog`

5. Generate the PR body using only final `package.json` version diffs. Don't read script - run directly:

    ```bash
    bash .cursor/skills/update-dependencies/scripts/generate-pr-markdown.sh > /tmp/update-dependencies-pr.md
    ```

6. Edit the generated markdown file to replace placeholder bullets:
    - Under `### Summary`, for each dependency: `**<pkg name>**: [one-line bullet of that dependency's full update]`
    - Under each dependency's `#### Summary`, brief bullets summarizing that dependency's most important release notes
    - Before writing `### Project Impact`, inspect the project for actual usage of each dependency and the changed APIs/features
    - Under `### Project Impact`, include only items that should become follow-up work:
      - `#### Breaking Changes`: only merge blockers or required follow-up work for code, config, scripts, CI, runtime behavior, or supported workflows in this repo
      - `#### Opportunities`: worthwhile high-impact follow-up work that use the update to create a concrete product, developer-experience, performance, reliability, or security benefit
      - Every bullet must describe a concrete repo-specific action, not a benefit already gained by upgrading
      - Omit release-note summaries, compatibility notes, passive benefits, and "no action needed" observations
      - If there are no bullets for a subsection, write `None found.` and don't force yourself to fill in either section. Not every dep update PR needs follow ups.

7. Open a pull request:

    ```bash
    gh pr create --title "Update Dependencies: <pkg>, ..." --body-file /tmp/update-dependencies-pr.md
    ```
