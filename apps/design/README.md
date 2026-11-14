# FeedBasket components

`tokens.json` owns the shared light and dark palettes, accent colors, typography sizes, spacing, and corner radius. Run `node apps/design/generate.mjs` after an edit. The generated CSS and Swift files are checked in so the Mac client can build without Node.js.

| Component | Chrome | macOS |
| --- | --- | --- |
| Surface and appearance | `popup.css` and `tokens.css` | `BasketAppearance` and `BasketStyle` in `Design.swift` |
| Primary and secondary buttons | `button` and `button.primary` | `BasketButton` |
| Connection status | `connection` in the popup | `BasketStatus` |
| Fields and pickers | Shared `input` and `select` styles | Native SwiftUI controls under `BasketAppearance` |
| Library rows and feed actions | | `LibraryComponents.swift` |
| Reader controls | | `Reader.swift` |

The Mac sidebar uses the transparent basket and papers from Chrome’s extension icon beside the rounded lowercase wordmark in the active accent color. The Chrome popup pairs the wordmark with its own light and dark artwork. Chrome’s toolbar shows the transparent mark with a bright blue basket for reachable and a muted blue basket for offline. The Mac bundle uses the light ICNS in Finder and switches the running app’s Dock icon with the app theme.
