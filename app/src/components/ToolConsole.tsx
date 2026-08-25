import { useEffect, useRef } from "react";
import clsx from "clsx";
import "./ToolConsole.css";

export interface ToolConsoleLine {
  stream: string;
  line: string;
}

interface ToolConsoleProps {
  lines: ToolConsoleLine[];
  className?: string;
}

/**
 * Scrolling monospace output pane for a streamed `tool.run` - the shared
 * visual/behavioral pattern (auto-scroll to bottom, stderr tinted ember)
 * originally built for the Control Center's ToolRunDialog, factored out so
 * the widget's Quick Actions panel can show the same live console inline.
 * Renders nothing when there's no output yet, so callers can mount it
 * unconditionally.
 */
export function ToolConsole({ lines, className }: ToolConsoleProps) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    ref.current?.scrollTo({ top: ref.current.scrollHeight });
  }, [lines]);

  if (lines.length === 0) return null;

  return (
    <div className={clsx("tool-console", className)} ref={ref}>
      {lines.map((l, i) => (
        <div key={i} className={l.stream === "stderr" ? "tool-console__line tool-console__line--err" : "tool-console__line"}>
          {l.line}
        </div>
      ))}
    </div>
  );
}
