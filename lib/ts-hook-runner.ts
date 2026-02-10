// ts-hook-runner.ts — Hatch TypeScript hooks dispatcher
// Usage: npx tsx ts-hook-runner.ts <hooks-file> <function-name> [...args]

import { resolve } from "path";
import { pathToFileURL } from "url";

async function main() {
  const [hooksPath, funcName, ...args] = process.argv.slice(2);

  if (!hooksPath || !funcName) {
    console.error("[error] Usage: ts-hook-runner.ts <hooks-file> <function-name> [...args]");
    process.exit(1);
  }

  const absPath = resolve(hooksPath);
  let hooks: Record<string, unknown>;
  try {
    hooks = await import(pathToFileURL(absPath).href);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[error] Failed to load hooks file: ${absPath}`);
    console.error(`[error] ${message}`);
    process.exit(1);
  }
  const fn = hooks[funcName];

  if (typeof fn !== "function") {
    console.error(`[error] Hook function not found: ${funcName}`);
    process.exit(1);
  }

  try {
    await fn(...args);
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[error] Hook '${funcName}' failed: ${message}`);
    process.exit(1);
  }
}

main();
