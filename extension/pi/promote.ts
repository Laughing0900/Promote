// Promote: records what pi is doing on its tmux pane (@promote-status), so the sidebar status
// is exact instead of guessed from the screen. Does nothing outside tmux.
// Promote wrote this file to ~/.pi/agent/extensions/promote.ts and removes it when you turn
// pi off under Promote > Live Agent Status.
import { execFile } from "node:child_process";

const pane = process.env.TMUX_PANE;

function report(status?: string) {
  if (!pane) return;
  const args = status
    ? ["set-option", "-p", "-t", pane, "@promote-status", `pi ${status} ${Math.floor(Date.now() / 1000)}`]
    : ["set-option", "-p", "-u", "-t", pane, "@promote-status"];
  try { execFile("tmux", args, () => {}); } catch {}
}

export default function (pi: any) {
  let failed = false, aborted = false;
  const on = (event: string, handler: (e: any) => void) => {
    try { pi.on(event, async (e: any) => { try { handler(e); } catch {} }); } catch {}
  };
  report(); // a new pi in this pane: drop what the last one left
  on("agent_start", () => { failed = false; aborted = false; report("working"); });
  on("tool_execution_end", () => report("working"));
  on("message_end", (e) => {
    if (e.message?.role !== "assistant") return;
    failed = e.message.stopReason === "error";
    aborted = e.message.stopReason === "aborted";
  });
  on("agent_settled", (e) => report(failed && !(e.aborted || aborted) ? "failed" : "done"));
  // an extension asks you something in the terminal (pi 1.0 and later)
  on("ui_prompt_start", () => report("blocked"));
  on("ui_prompt_end", () => report("working"));
}
