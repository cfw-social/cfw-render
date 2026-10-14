import type { ButtonHTMLAttributes, ReactNode } from "react";
import { Icon, type IconName } from "./Icon";
import markUrl from "../assets/mark.png";

export const MARK_URL = markUrl;

type Variant = "primary" | "secondary" | "ghost" | "danger";
type Size = "sm" | "md" | "lg";

const VARIANT: Record<Variant, string> = {
  primary: "bg-primary text-white border-primary hover:bg-primary-hover hover:border-primary-hover",
  secondary: "bg-white text-foreground border-input hover:bg-secondary",
  ghost: "bg-transparent text-muted-foreground border-transparent hover:bg-secondary",
  danger: "bg-white text-destructive border-input hover:bg-failed-bg",
};
const SIZE: Record<Size, string> = {
  sm: "h-7 px-2.5 text-xs gap-1.5",
  md: "h-[34px] px-3.5 text-[13px] gap-1.5",
  lg: "h-[38px] px-[18px] text-[13px] gap-2",
};

export function Button({
  variant = "secondary",
  size = "md",
  icon,
  busy,
  className,
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; size?: Size; icon?: IconName; busy?: boolean }) {
  return (
    <button
      type="button"
      {...rest}
      className={`inline-flex shrink-0 items-center justify-center whitespace-nowrap rounded-[8px] border font-medium transition-colors duration-150 disabled:pointer-events-none disabled:opacity-45 ${VARIANT[variant]} ${SIZE[size]} ${className ?? ""}`}
    >
      {busy ? <Icon name="loader-circle" size={14} className="animate-spin" /> : icon ? <Icon name={icon} size={size === "sm" ? 13 : 14} /> : null}
      {children}
    </button>
  );
}

export type Tone = "ok" | "warn" | "idle" | "bad" | "info";
const PILL: Record<Tone, string> = {
  ok: "bg-success-bg text-success",
  warn: "bg-warn-bg text-warn",
  idle: "bg-secondary text-muted-foreground",
  bad: "bg-failed-bg text-failed",
  info: "bg-info-bg text-info",
};
const DOT: Record<Tone, string> = {
  ok: "bg-emerald-500",
  warn: "bg-amber-500",
  idle: "bg-zinc-400",
  bad: "bg-red-600",
  info: "bg-blue-500",
};

export function Dot({ tone, className }: { tone: Tone; className?: string }) {
  return <span aria-hidden="true" className={`inline-block h-[7px] w-[7px] shrink-0 rounded-full ${DOT[tone]} ${className ?? ""}`} />;
}

export function Pill({ tone, dot, children }: { tone: Tone; dot?: boolean; children: ReactNode }) {
  return (
    <span className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-[3px] text-[11px] leading-tight font-semibold ${PILL[tone]}`}>
      {dot && <Dot tone={tone} />}
      {children}
    </span>
  );
}

export function SectionLabel({ children, className }: { children: ReactNode; className?: string }) {
  return <h2 className={`text-[11px] font-semibold uppercase tracking-[0.05em] text-faint ${className ?? ""}`}>{children}</h2>;
}

export function Card({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={`rounded-[10px] border border-border bg-card ${className ?? ""}`}>{children}</div>;
}

export function ProgressBar({ pct, label }: { pct: number; label: string }) {
  return (
    <div
      className="h-1.5 overflow-hidden rounded-full bg-secondary"
      role="progressbar"
      aria-label={label}
      aria-valuenow={pct}
      aria-valuemin={0}
      aria-valuemax={100}
    >
      <div className="h-full rounded-full bg-primary" style={{ width: `${pct}%` }} />
    </div>
  );
}
