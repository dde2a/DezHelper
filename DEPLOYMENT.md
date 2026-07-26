# Automated deployment

The release workflow publishes tagged versions to GitHub Releases and
CurseForge with the BigWigsMods packager.

## One-time GitHub configuration

In the repository, open **Settings → Secrets and variables → Actions**.

Create this repository variable:

- `CURSEFORGE_PROJECT_ID`: the numeric project ID shown on the CurseForge
  project page.

Create this repository secret:

- `CF_API_TOKEN`: a CurseForge API token created from the CurseForge
  authors dashboard.

The built-in `GITHUB_TOKEN` is supplied automatically by GitHub Actions.

Upload `Media/icon.png` as the project avatar on CurseForge.

## Publishing a release

1. Update `## Version` in `DezHelper.toc`.
2. Update `CHANGELOG.md`.
3. Commit and push the changes.
4. Create and push a matching tag:

   `git tag v1.0.0`

   `git push origin v1.0.0`

The workflow verifies that the tag matches the TOC version, builds the ZIP,
creates a GitHub release, and uploads the same package to CurseForge.
