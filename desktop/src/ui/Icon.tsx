import { createElement } from "react";
import { ICONS, type IconName } from "./icon-data";

export type { IconName };

/** Inline lucide icon, decorative by default (pair it with visible text or an aria-label on the control). */
export function Icon({ name, size = 16, strokeWidth = 2, className }: { name: IconName; size?: number; strokeWidth?: number; className?: string }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      className={`shrink-0 ${className ?? ""}`}
      data-icon={name}
    >
      {ICONS[name].map(([tag, attrs], i) => createElement(tag, { key: i, ...attrs }))}
    </svg>
  );
}
