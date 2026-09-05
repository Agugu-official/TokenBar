## Features

- **TokenBar speaks Simplified Chinese.** [#268](https://github.com/Nanako0129/TokenBar/pull/268) — thanks @Agugu-official

  简体中文 joins English and 繁體中文 under Settings → Language. The catalog covers 488 strings: tabs, dashboard cards, quota windows, statistics, charts, contribution tooltips, settings, and the menu-bar item. As with the other two languages, the choice takes effect on the next launch, because macOS resolves the interface language once at startup.

  It is reviewed copy rather than a character conversion of the Traditional Chinese catalog. Terminology, counters and word order were adapted, and a sentence Chinese reorders is translated as one unit rather than assembled from parts, so a paginated list reads 再显示 7 项 · 已显示 20／共 27 项.

  Some values are built while the app runs — window titles, the pagination line, token totals, streak lengths, the usage-loading error — and those never reached the translation table at all. They do now, in every language. Traditional Chinese sees it too: a quota card that read "Session 時間窗" now reads 工作階段 時間窗.

## Fixes

- **Each menu-bar color swatch now opens its own editor.** [#268](https://github.com/Nanako0129/TokenBar/pull/268) — thanks @Agugu-official

  The Font color section that arrived in 1.15.0 shows three swatches — normal, low, very low — and all three shared a single popover anchored to the row containing them. Whichever swatch you clicked, the editor's arrow pointed at the middle one. Each swatch now anchors its own.

- **Three Traditional Chinese strings were still falling back to English.** [#270](https://github.com/Nanako0129/TokenBar/pull/270)

  The usage-loading error, the "show more" pagination line and the OAuth quota label had no Traditional Chinese entries. Both Chinese catalogs now carry the same 488 keys.
