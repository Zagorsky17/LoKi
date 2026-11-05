# Local YACD panel

This source is adapted from [MetaCubeX/Yacd-meta at `24151c331027ff176b45ed417180c6f1220474a3`](https://github.com/MetaCubeX/Yacd-meta/tree/24151c331027ff176b45ed417180c6f1220474a3). Its package metadata declares MIT. The included MIT license text comes from [that repository's earlier commit `065069e`](https://github.com/MetaCubeX/Yacd-meta/blob/065069e5528f01c87e22b613913fb8e0df3b8d4a/LICENSE), because the pinned tree has no `LICENSE` file. The Inter and Roboto Mono font notices come from the pinned `@fontsource` packages, version 5.2.8. Other bundled dependency notices still need review before a binary release.

On Linux, use Bun 1.4.0 with the committed lockfile:

```sh
bun install --frozen-lockfile
bun test tests
bun run typecheck
bun run lint
bun run build
```

The build writes `public/`. The distributed files live in `luci-app-loki/root/usr/share/loki/yacd/`, outside the web server document root. After rebuilding, replace that directory with the new `public/` files and verify identical names and SHA-256 hashes. The core gateway serves them only after LuCI write authorization. The panel uses the gateway on the current HTTPS host; it has no arbitrary backend login or browser controller token.
