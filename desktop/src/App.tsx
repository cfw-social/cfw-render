import { MainWindow } from "./main-window/MainWindow";
import { SetupScreen } from "./setup";

export default function App() {
  if (window.location.hash.startsWith("#/setup")) return <SetupScreen />;
  return <MainWindow />;
}
