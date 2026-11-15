#!/usr/bin/env node
// Generates seccomp/opencode.json from the vendored Docker default profile.
//
// Why: Docker's default profile allows a syscall group with argument filters
// (mount, ptrace, bpf, ...). `security_opt: seccomp=...` REPLACES the default,
// so the only safe way to tighten it is to start from the default, strip the
// names we refuse outright, and append one EPERM rule. Denying a syscall that
// Docker already allows with filters is the only way to deny it completely.
//
// Run: node scripts/gen-seccomp.mjs          # rewrite seccomp/opencode.json
//      node scripts/gen-seccomp.mjs --check  # exit 1 if it is out of date
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const source = join(root, "seccomp", "docker-default.json");
const target = join(root, "seccomp", "opencode.json");

// Denied outright (EPERM). Each entry is either an escape primitive, a kernel
// attack surface, or a persistence/impersonation vector. Anything a normal
// JS/TS build (node, npm, pnpm, git, tar) needs is absent from this list.
export const DENIED = [
  // mount / namespace / handle tricks
  "mount", "umount2", "pivot_root", "chroot", "setns", "unshare",
  "open_tree", "move_mount", "fsopen", "fsconfig", "fsmount", "mount_setattr",
  "name_to_handle_at", "open_by_handle_at",
  // process inspection and memory access
  "ptrace", "process_vm_readv", "process_vm_writev", "kcmp", "pidfd_getfd",
  "process_madvise", "lookup_dcookie",
  // kernel attack surface
  "bpf", "perf_event_open", "userfaultfd", "io_uring_setup", "io_uring_enter",
  "io_uring_register", "kexec_load", "kexec_file_load", "init_module",
  "finit_module", "delete_module", "create_module", "query_module",
  // keyring, privilege and audit surface
  "keyctl", "add_key", "request_key", "syslog", "quotactl",
  "iopl", "ioperm", "acct", "vhangup",
  // host identity, clock and swap: a container has no business changing these
  "sethostname", "setdomainname", "settimeofday", "stime", "clock_settime",
  "clock_adjtime", "adjtimex", "swapon", "swapoff", "reboot",
  // device nodes and fanotify
  "mknod", "mknodat", "fanotify_init", "fanotify_mark",
];

export function build(profile, denied = DENIED) {
  const deny = new Set(denied);
  const syscalls = profile.syscalls
    .map((rule) => {
      if (rule.action !== "SCMP_ACT_ALLOW") return rule;
      const names = rule.names.filter((name) => !deny.has(name));
      return { ...rule, names };
    })
    .filter((rule) => rule.names.length > 0);

  const stillAllowed = syscalls
    .filter((rule) => rule.action === "SCMP_ACT_ALLOW")
    .flatMap((rule) => rule.names);
  const overlap = stillAllowed.filter((name) => deny.has(name));
  if (overlap.length > 0) {
    throw new Error(`denied syscalls still allowed: ${overlap.join(", ")}`);
  }

  return {
    ...profile,
    syscalls: [
      ...syscalls,
      { names: [...denied].sort(), action: "SCMP_ACT_ERRNO", errnoRet: 1 },
    ],
  };
}

function main(argv) {
  const profile = JSON.parse(readFileSync(source, "utf8"));
  const output = `${JSON.stringify(build(profile), null, 2)}\n`;
  if (argv.includes("--check")) {
    let current = "";
    try {
      current = readFileSync(target, "utf8");
    } catch {
      console.error(`seccomp: ${target} is missing; run node scripts/gen-seccomp.mjs`);
      process.exit(1);
    }
    if (current !== output) {
      console.error("seccomp: seccomp/opencode.json is out of date; regenerate it");
      process.exit(1);
    }
    console.log("seccomp: profile is up to date");
    return;
  }
  writeFileSync(target, output);
  const allowed = build(profile).syscalls
    .filter((rule) => rule.action === "SCMP_ACT_ALLOW")
    .reduce((sum, rule) => sum + rule.names.length, 0);
  console.log(`seccomp: wrote ${target} (${allowed} allowed, ${DENIED.length} denied)`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2));
}
