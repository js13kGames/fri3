import {
  js13kViteConfig,
  defaultViteBuildOptions,
  RoadrollerOptions,
  defaultRollupOptions,
  defaultTerserOptions,
} from "js13k-vite-plugins";
import { defineConfig, ConfigEnv, UserConfig } from "vite";
import { ViteMinifyPlugin } from "vite-plugin-minify";
import glsl from "vite-plugin-glsl";
import { zig } from "./vite-zig";

const createProdConfig = (): ConfigEnv => {
  defaultViteBuildOptions.assetsInlineLimit = 0;
  defaultViteBuildOptions.modulePreload = false;
  defaultViteBuildOptions.assetsDir = "";

  defaultTerserOptions.mangle = {
    properties: {
      regex: /^_[a-z]/,
    },
  };

  const js13kConfig: ConfigEnv = js13kViteConfig({
    roadrollerOptions: false,
    viteOptions: defaultViteBuildOptions,
    terserOptions: defaultTerserOptions,
  }) as ConfigEnv;

  (js13kConfig as any).rollupConfig = defaultRollupOptions;
  (js13kConfig as any).rollupConfig.output = {
    assetFileNames: "[name].[ext]",
    entryFileNames: "i.js",
    chunkFileNames: "[name].[ext]",
  };

  (js13kConfig as any).base = "";
//  (js13kConfig as any).server = { port: 8080, open: true };

  (js13kConfig as any).plugins.push(
    glsl({
      compress: true,
    }),
    zig(),
    ViteMinifyPlugin({
      includeAutoGeneratedTags: true,
      removeAttributeQuotes: true,
      removeComments: true,
      removeRedundantAttributes: true,
      removeScriptTypeAttributes: true,
      removeStyleLinkTypeAttributes: true,
      sortClassName: true,
      useShortDoctype: true,
      collapseWhitespace: true,
      collapseInlineTagWhitespace: true,
      removeEmptyAttributes: true,
      removeOptionalTags: true,
      sortAttributes: true,
    }),
    {
      name: "final-transformations",
      enforce: "post",
      renderChunk: async (code: string) => {
        return {
          code: code.replaceAll("const ", "let "),
          map: null,
        };
      },
      transformIndexHtml(html: string) {
        const regex = /<script crossorigin (.*?)/gi;
        const replacement = '<script $1';
        return html.replace(regex, replacement);
      },
    }
  );
  return js13kConfig;
};

export default defineConfig((env: ConfigEnv): UserConfig => {
  if(env.command == "serve") {
    return {
      base: "",
     // server: { port: 8080, open: true },
      plugins: [
        glsl(),
        zig(),
      ],
    };
  }

  return createProdConfig();
});
