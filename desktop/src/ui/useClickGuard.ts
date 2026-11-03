import { useCallback, useEffect, useRef } from "react";

/**
 * Runs a toggle at most once per `ms`. Pause and Resume swap in place the moment one is
 * clicked, so the second click of a double-click lands on the button that just replaced it
 * and would undo the first. Clicks inside the window are dropped.
 */
export function useClickGuard(ms = 800): (fn: () => void) => void {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
    },
    [],
  );
  return useCallback(
    (fn: () => void) => {
      if (timer.current) return;
      timer.current = setTimeout(() => {
        timer.current = null;
      }, ms);
      fn();
    },
    [ms],
  );
}
