# Twemoji Country Flags provenance

`TwemojiCountryFlags.woff2` is unchanged from the published
[`country-flag-emoji-polyfill` 0.1.8 npm artifact](https://registry.npmjs.org/country-flag-emoji-polyfill/-/country-flag-emoji-polyfill-0.1.8.tgz).
It is a country-flag subset of Twemoji Mozilla. LoKi does not modify these font bytes.

| File | SHA-256 |
| --- | --- |
| npm tarball | `9682bbff0e201fee118803997d7fda872c2edad3fdef3a3aa1263249ca2c9468` |
| `TwemojiCountryFlags.woff2` | `9f04f14429bb6a9f415c7a4dd902a918d7e81a4f7526c415496fdb063954e3b8` |
| [Unmodified upstream LICENSE.md](UPSTREAM_LICENSE.md) | `aa92b722615382b3f4d3e3a8049abe55ccac3a62ccd0c7902dd9c23588dabdb2` |

The upstream license distinguishes MIT for the TalkJS code from CC BY 4.0
for the Twemoji artwork. [The artwork attribution](LICENSE.md) is retained.
The package-level MIT declaration does not assign MIT to the artwork.

The verified match concerns the published WOFF2 artifact. The upstream font
script obtains a Mozilla TTF through a mutable latest-release URL and then
runs `pyftsubset`; its exact TTF and tool version are not pinned there.
Reproduction of that TTF-to-WOFF2 build has not been verified.
