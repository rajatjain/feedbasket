# FeedBasket development guide

## Code organization

- Before implementing a change, trace the existing workflow and look for modules, functions, and components you can reuse or extend.
- Keep logic close to the code that owns it. Share validation, state changes, and data access when several entry points need the same behavior.
- Extract a focused module or component when a pattern is repeated or likely to recur. Use the existing interfaces and keep the abstraction as small as the shared behavior.

## Tests

- Read the existing tests before adding coverage. Start with [test_backend.py](backend/tests/test_backend.py), [test_job_workflows.py](backend/tests/test_job_workflows.py), and [test_saved_updates.py](backend/tests/test_saved_updates.py).
- Prefer data-driven workflow tests. Use a temporary on-disk SQLite database, run the real migrations, seed realistic records, and exercise the real API and job logic. Assert both what the caller sees and what persists.
- Use the app's real HTTP routes through its test client. Run a disposable API server on a loopback port when the behavior depends on live HTTP, streaming, or restart and reconnect.
- Use the publisher data in [backend/tests/data](backend/tests/data) and serve it from a local HTTP test server when the workflow fetches feeds or articles. Keep the default suite reproducible. Use the existing opt-in live publisher tests for checks that need a public site.
- Exercise real implementations instead of mocks. Where a test needs to point the fetcher at a local publisher, keep that substitution at the network boundary so parsing, extraction, database writes, and job handling still run. Add focused unit tests where they help cover edge cases.
- Use temporary files and isolated accounts, and stop any services you start for a test. Run `uv run --locked pytest --cov=feedbasket` from `backend/`. Keep authentication excluded from coverage as configured in `pyproject.toml`.

## UI components

- Check the existing components before building a view. Start with [apps/design/README.md](apps/design/README.md), the Mac app's `Design.swift` and `LibraryComponents.swift`, and the Chrome popup's shared styles.
- Make a reusable component when a control, layout, or workflow is likely to appear again. Keep its appearance and interactions in one place so changes apply consistently.
- Use [apps/design/tokens.json](apps/design/tokens.json) for shared design values. Run `node apps/design/generate.mjs` from the repo root after editing tokens.
- Use the same components where the rendering technology allows it. For SwiftUI, WebView, and Chrome surfaces that render separately, share the display data and design values where practical.
- Check both light and dark mode and the supported accent colors when changing UI. Build the affected client using the commands in [README.md](README.md), and verify the affected workflow in the running UI when available.

## Design mockups

- Before creating a mockup, review the current UI and the workflow the change affects. Use the running app or a current screenshot as the visual reference, and check the relevant components in the repo.
- Build the mockup from the existing screen. Preserve the layout, navigation, control placement, and interaction patterns outside the requested change. Show how the new design fits the surrounding workflow.
- Use the assets and design tokens that ship with the app, including its logo, icons, typography, colors, and spacing. Use the actual assets in the mockup wherever they appear.
- Reuse existing components and their interaction states wherever they fit. When an existing component needs to support a new case, extend its design using the same patterns.
- Before sharing, compare the mockup with the current UI and check for unintended changes to branding, icons, spacing, or controls.
