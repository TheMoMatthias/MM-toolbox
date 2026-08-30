# The window's typeface

`Manrope.ttf` is [Manrope](https://github.com/sharanda/manrope) by Mikhail Sharanda,
under the SIL Open Font License 1.1 — the full licence is in `OFL.txt` beside it,
which is the condition of shipping it. It may be bundled and redistributed; it may
not be sold on its own.

## Why a file at all

Everything Windows ships is either a system UI face (Segoe UI Variable — correct,
and so neutral it reads as "no decision was made") or has a flaw at the sizes this
window uses. Corbel defaults to old-style numerals, so `1` and `9` drop below the
cap line and a counter looks broken. Century Gothic is beautiful at 24px and
unreadable at 11px. Manrope is semi-geometric with genuinely good numerals, which
matters here because the project rail and the counts are numbers.

## 🔴 It is a VARIABLE font, and that is only fine because it was checked

WPF does not support variable-font *axes* — it cannot interpolate a weight. What it
does support is the font's **named instances**, and Manrope ships seven. Measured
on this machine before shipping it:

    families: 1  →  ./#Manrope
      ExtraLight · Light · Normal · Medium · SemiBold · Bold · ExtraBold
      (and the same seven as Oblique)

So one 165 KB file covers the whole weight scale. Had it exposed only one instance,
the window would have rendered every weight as Regular with synthesised bold — which
looks worse than the system font it replaced, and would have shipped silently.

🪤 `GlyphTypeface` on this file reports **ExtraLight**, because that is the variable
font's default instance. That is not what the window gets: a `FontFamily` resolves
through the named instances above. Do not "fix" the default — check
`GetFontFamilies(...).GetTypefaces()` instead, which is what the window actually uses.

## How the window loads it

`sessions-window.ps1` builds the family from this directory at startup and replaces
the `FontText` / `FontDisplay` / `FontSmall` resources with it. If the file is
missing or unreadable the window keeps the Segoe UI Variable stack the markup
declares, so a deleted font degrades to the old look rather than to Arial — and the
log says which one it got.
