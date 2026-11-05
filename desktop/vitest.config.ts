import { defineConfig, mergeConfig } from "vitest/config";
import viteConfig from "./vite.config";

// One load ceiling for every desktop test. Vitest's 5000 ms default expired on
// the first Renders cases while the bound suite shared the machine. It stays
// above MainWindow's recent-identity execFileSync ceiling (90s * 8).
const LOAD_TEST_TIMEOUT_MS = 780_000;

// Only the app's own tests: the worker bundle copied under src-tauri/ ships skill tests for node.
export default mergeConfig(viteConfig, defineConfig({
  test: { include: ["src/**/*.test.{ts,tsx}"], testTimeout: LOAD_TEST_TIMEOUT_MS },
}));
