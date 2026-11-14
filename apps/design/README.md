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

The FeedBasket mark is in `icons/`. The Mac sidebar and Chrome popup pair the light and dark versions with a rounded lowercase wordmark in the active accent color. Chrome’s toolbar uses blue and gray variants for connectivity. The Mac bundle uses the light ICNS in Finder and switches the running app’s Dock icon with the app theme.
