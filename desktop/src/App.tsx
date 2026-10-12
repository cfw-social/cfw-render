import { NAV_ITEMS } from "./nav";

export default function App() {
  return (
    <div className="flex h-screen font-sans text-sm">
      <nav className="w-56 border-r border-neutral-200 bg-neutral-50 p-4">
        <ul className="space-y-2">
          {NAV_ITEMS.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      </nav>
      <main className="flex-1 p-6">CFW Render</main>
    </div>
  );
}
