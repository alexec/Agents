// Paper v2's one icon set on the web page (#4996; specs/4926-paper-v2/spec.md, Icons): Lucide
// (ISC), from lucide-static at the version design/icons.json pins. `import x from "lucide:name"`
// is replaced at build time by the elements of that icon's SVG, as data (`[["path", {d: …}], …]`), so only
// the icons the page names are in the bundle, and src/views/Icon.tsx draws them as Preact
// elements: the page sets no innerHTML (test/lint.mjs, Trusted Types).
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

export const lucide = {
  name: "lucide",
  setup(build) {
    build.onResolve({ filter: /^lucide:/ }, (args) => ({ path: args.path.slice("lucide:".length), namespace: "lucide" }));
    build.onLoad({ filter: /.*/, namespace: "lucide" }, (args) => {
      if (!/^[a-z0-9-]+$/.test(args.path)) return { errors: [{ text: `"${args.path}" is not a Lucide icon's name` }] };
      let svg;
      try {
        svg = readFileSync(require.resolve(`lucide-static/icons/${args.path}.svg`), "utf8");
      } catch {
        return { errors: [{ text: `lucide-static has no icon "${args.path}"` }] };
      }
      // Each child of a Lucide SVG is one empty element (`<path d="…" />`): its tag and its attributes.
      const body = svg.slice(svg.indexOf(">", svg.indexOf("<svg")) + 1, svg.lastIndexOf("</svg>"));
      const icon = [...body.matchAll(/<([a-z]+)((?:\s+[a-z0-9-]+="[^"]*")*)\s*\/>/g)].map(([, tag, attributes]) =>
        [tag, Object.fromEntries([...attributes.matchAll(/([a-z0-9-]+)="([^"]*)"/g)].map(([, name, value]) => [name, value]))]);
      if (icon.length === 0) return { errors: [{ text: `lucide-static's ${args.path}.svg has no elements we can read` }] };
      return { contents: `export default ${JSON.stringify(icon)};`, loader: "js" };
    });
  },
};
