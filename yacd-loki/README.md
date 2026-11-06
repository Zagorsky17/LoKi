# Local YACD panel

This source is adapted from [MetaCubeX/Yacd-meta at `24151c331027ff176b45ed417180c6f1220474a3`](https://github.com/MetaCubeX/Yacd-meta/tree/24151c331027ff176b45ed417180c6f1220474a3). Its package metadata declares MIT. The included MIT license text comes from [that repository's earlier commit `065069e`](https://github.com/MetaCubeX/Yacd-meta/blob/065069e5528f01c87e22b613913fb8e0df3b8d4a/LICENSE), because the pinned tree has no `LICENSE` file. The Inter and Roboto Mono font notices come from the pinned `@fontsource` packages, version 5.2.8.

The build collects dependency notices from rendered JavaScript modules, the reviewed Sass imports and injected Vite/Rolldown helpers. `licenses/THIRD_PARTY_INVENTORY.json` records the lockfile and notice hashes. The original package metadata is retained for the exact `use-asset` and `react-remove-scroll-bar` archives that omit a license file; supplemental permission text and the later upstream notice are identified separately. `licenses/sources.json` pins those supplements and the Flat Color Icons notice. These records preserve the available declarations; the complete binary-release source and license audit remains open.

On Linux, use Bun 1.4.0 with the committed lockfile:

```sh
bun install --frozen-lockfile
bun test tests
bun run typecheck
bun run lint
bun run build
bun third-party-notices.mjs
```

The build writes `public/`. Copy its `THIRD_PARTY_NOTICES.txt` and `THIRD_PARTY_INVENTORY.json` to `licenses/` when deliberately updating the reviewed bundle. Replace `luci-app-loki/root/usr/share/loki/yacd/` with the remaining files, then run `bun third-party-notices.mjs` to compare every file and reject stale notices, changed assets or extra objects. CI performs this comparison after a fresh build. The two notice files are installed once under `/usr/share/licenses/luci-app-loki/`.

The distributed panel stays outside the web server document root. The core gateway serves it only after LuCI write authorization. It uses the gateway on the current HTTPS host, without an arbitrary backend login or browser controller token.
