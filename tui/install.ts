/**
 * Builds the argv used by the TUI to install the privileged daemon.
 * Exported so tests can pin the sudo/root branches without spawning anything.
 */
export function installArgv(isRoot: boolean, bin: string): string[] {
  return isRoot ? [bin, "install"] : ["sudo", bin, "install"]
}
