import { useId } from "react";

/** A switch that is a real checkbox underneath: its name is just the label, the note is its description. */
export function Toggle({
  label,
  note,
  checked,
  disabled,
  onChange,
}: {
  label: string;
  note?: string;
  checked: boolean;
  disabled?: boolean;
  onChange: (on: boolean) => void;
}) {
  const id = useId();
  return (
    <div className={`flex items-start gap-4 px-4 py-3 ${disabled ? "opacity-55" : ""}`}>
      <div className="min-w-0 flex-1">
        <label htmlFor={id} className="block text-[13px] font-medium text-foreground">
          {label}
        </label>
        {note && (
          <p id={`${id}-note`} className="mt-0.5 text-xs leading-snug text-subtle">
            {note}
          </p>
        )}
      </div>
      <span className="relative mt-0.5 inline-flex shrink-0">
        <input
          id={id}
          type="checkbox"
          aria-describedby={note ? `${id}-note` : undefined}
          className="peer absolute inset-0 z-10 h-full w-full cursor-pointer opacity-0 disabled:cursor-default"
          checked={checked}
          disabled={disabled}
          onChange={(e) => onChange(e.target.checked)}
        />
        <span
          aria-hidden="true"
          className="h-5 w-9 rounded-full bg-input transition-colors duration-150 peer-checked:bg-primary peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-primary"
        />
        <span
          aria-hidden="true"
          className="pointer-events-none absolute top-0.5 left-0.5 h-4 w-4 rounded-full bg-white shadow-sm transition-transform duration-150 peer-checked:translate-x-4"
        />
      </span>
    </div>
  );
}
