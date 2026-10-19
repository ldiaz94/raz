import { build } from "esbuild";

await build({
  entryPoints: ["worker.ts"],
  outfile: "dist/worker.mjs",
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
});
