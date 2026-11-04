Inter Bold, the caption font (scripts/captions.py burns with it through an explicit fontsdir).

Inter 4.0 by The Inter Project Authors, SIL Open Font License 1.1 (fonts/OFL.txt).
File: the Latin subset of Inter Bold (weight 700) from the @fontsource/inter 5.2.8 package, which
ships it as WOFF. It is the same font data unpacked from WOFF into a plain TrueType file
(no outline or glyph was changed), so FFmpeg's libass can load it without WOFF support.

The recipe never downloads a font. If this file is missing the burn stops and says so.
