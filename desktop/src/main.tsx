import { invoke } from "@tauri-apps/api/core";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import PanelWindow from "./panel/PanelWindow";
import "./index.css";

const isPanel = window.location.hash.startsWith("#/panel");

// [M3-06a] report new CFW Render crashes once per launch (the command checks
// the "Share crash reports" setting itself).
if (!isPanel) invoke("crash_scan").catch((e: unknown) => console.error("crash_scan", e));

createRoot(document.getElementById("root")!).render(
  <StrictMode>{isPanel ? <PanelWindow /> : <App />}</StrictMode>,
);
