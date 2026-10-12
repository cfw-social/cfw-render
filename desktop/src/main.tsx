import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import PanelWindow from "./panel/PanelWindow";
import "./index.css";

const isPanel = window.location.hash.startsWith("#/panel");

createRoot(document.getElementById("root")!).render(
  <StrictMode>{isPanel ? <PanelWindow /> : <App />}</StrictMode>,
);
