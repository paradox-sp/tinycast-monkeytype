# Usage

Run `npm run dev` after building to open the standalone window. Tinycast is only needed for extension installation and launcher integration; see [development.md](development.md).

## Practice modes

- Quotes: **All, Short, Medium, Long, Extra Long**.
- Timed: **15, 30, 45, 60 seconds**; timed practice uses extra-long passages.
- First-run defaults: **All quotes** and **30 seconds**.
- Type against the fixed displayed passage. Incorrect positions color the **target letters**, not replacement characters. Non-space input cannot advance across a target space.
- Backspace can correct the current/error word; a correctly completed word is locked after its following space. Paste and caret navigation are disabled.
- Live WPM and the timed countdown appear in the footer’s bottom-left area, beside a compact circular progress indicator. There is no above-footer completion bar.
- Results show WPM, accuracy, elapsed time, correct/incorrect character counts, and passage source.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘R | Restart the same passage |
| ⌘N | Select a new random passage while practicing |
| ⌘Return | Select a new passage from results |
| ⌘M | Switch quote/time families, restoring the last selected mode |
| ⌘P | Focus/open the mode picker |
| ⌘K | Open/close actions |
| Esc | Close actions; return from results; otherwise close the window |
| ⌘Q | Quit the helper |

Returning to an inactive practice window restarts its current passage. The clock does not pause while inactive.

On results, **Start New Practice** keeps keyboard focus without an outline. Keyboard activation remains enabled.

## Quotes and updates

The app downloads [Monkeytype’s public English collection](https://raw.githubusercontent.com/monkeytypegame/monkeytype/master/frontend/static/quotes/english.json) when opened and keeps it in memory until quitting. Internet access is required; a failed download shows an error and manual retry.

New practice randomly selects from the loaded collection; repeats are possible. Restart keeps the same passage. Quit and reopen to download the current upstream collection; there is no continuous refresh while the window is open. Updates depend on upstream contributions, not a scheduled content feed.

The collection mixes passages from different sources. There are no separate story/lyrics/movie APIs or content-type filters. Each results card displays the supplied source attribution, if available. Quote contents retain their respective authors’ rights.

## Preferences and appearance

Mode selections persist in the helper’s existing UserDefaults domain, `app.tinycast.typing-practice.helper`, which remains unchanged across the project rename. Quote and timed families remember their own selection.

The window uses native Liquid Glass and follows **Tinycast’s actual System, Light, or Dark choice**. Changes apply while practice is open without relaunching or clearing typed text. System follows macOS automatically; Light/Dark stay aligned with Tinycast’s explicit choice.

The helper reads only Tinycast’s appearance preference and never changes host settings. A fresh direct launch without Tinycast follows macOS. This does not embed Tinycast’s internal views or automatically inherit future/custom host themes.
