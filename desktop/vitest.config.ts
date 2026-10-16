import { defineConfig, mergeConfig } from "vitest/config";
import viteConfig from "./vite.config";

// Only the app's own tests: the worker bundle copied under src-tauri/ ships skill tests for node.
export default mergeConfig(viteConfig, defineConfig({ test: { include: ["src/**/*.test.{ts,tsx}"] } }));
