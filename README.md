# agent-toolbox

A small, agent-agnostic library for running **preconfigured AI agent CLIs**
inside [jail.nix](https://git.sr.ht/~alexdavid/jail.nix) sandboxes, with
host-side secret injection and optional Herdr wiring.

It deliberately contains **no agent wrappers, no default configs and no
secrets**. Every agent CLI is a consumer-provided package: build the wrapper
that bakes your config, then hand it to `mkAgent` for the free/jailed variants.

The only packaged tools are the MCP servers that consumers commonly need:
[serena](https://github.com/oraios/serena) and
[mcpls](https://github.com/bug-ops/mcpls), exposed via the overlay.

## What you get

```
lib.mkAgent            # package -> { free, withEnv, makeJailedWith }
lib.mkEnvFromFile      # host-side secret wrapper (reads files, exports vars)
lib.mkJailedAgent      # jail.nix wrapper for an already-built package
lib.defaultPermissions # network + tz + base tools + rw cwd
lib.defaultBasePackages
lib.mkRtkShell         # drop-in shell that pipes -c commands through `rtk rewrite`
lib.combinators        # jail.nix combinators bound to the toolbox's nixpkgs
lib.jail               # jail.nix init
lib.extras             # flake-root, devshell, persistent home, git, herdr env
```

`overlays.default` provides `mcpls` and `serena`.

## Building an agent

Everything agent-specific lives in your configuration. The shape is:

```nix
let
  agent = atb.lib.mkAgent {
    name = "my-agent";
    package = myAgentPackage;          # wrapper with config baked in
    envFromFile.API_KEY = tokenPath;   # read on the host, forwarded into the jail
  };
in {
  inherit (agent) free;                # my-agent-free
  jailed = agent.makeJailedWith {
    permissions = c:
      atb.lib.defaultPermissions c
      ++ atb.lib.extras.herdrEnv.permissions c;
  };
}
```

- **Config is baked into the package.** The jail mounts the package closure, so
  no host config directory is needed. Use an environment variable or a
  read-only config dir in the store (opencode: `OPENCODE_CONFIG`, crush:
  `CRUSH_GLOBAL_CONFIG`, pi: `PI_CODING_AGENT_DIR`).
- **Secrets never enter the store.** `envFromFile = { NAME = path; }` exports
  the file's contents on the host and adds `try-fwd-env NAME`, so the value is
  forwarded into the jail at launch. No extra permission is needed.
- **The jail is ephemeral.** By default it mounts the working directory and the
  package closure; home is a tmpfs. Add mounts with `c.readonly` /
  `c.readwrite` or the extras below.
- **A host-side launcher can append arguments** with `JAIL_EXTRA_ARGS`
  (shell word splitting; paths with spaces are not supported).

## Extras

`lib.extras` collects opt-in jail fragments. Order matters: apply
`persistHomePermissions`, then `flakeRootPermissions`, then mounts that need to
land in `JAIL_HOME`.

- `persistHomePermissions` — creates `$FLAKE_ROOT/.home`, points the jail's
  `HOME` there, and persists state. Without `FLAKE_ROOT` home stays a tmpfs.
- `flakeRootPermissions` — binds `FLAKE_ROOT` (or the cwd) read-write.
- `devshellPermissions` — forwards a direnv / `nix develop` environment into
  the jail and prepends the devshell `PATH`.
- `gitPermissions` — rebinds the host `~/.config/git` into `JAIL_HOME`.
- `jailHome` — sets `JAIL_HOME` to `$HOME` unless `persistHomePermissions`
  already moved it.
- `herdrEnv` — forwards Herdr's pane/server environment
  (`HERDR_ENV`, `HERDR_SOCKET_PATH`, `HERDR_PANE_ID`, ...) and exposes the Herdr
  config directory read-only. Agents with native Herdr support (opencode,
  crush, pi) need only this; agent-specific plugins/extensions stay in the
  consumer.

## rtk

`lib.mkRtkShell` builds a shell that pipes `-c` commands through
`rtk rewrite` and runs the result. Point an agent at it when the agent lets you
override its shell. Supported by opencode (`shell` config), goose
(`GOOSE_SHELL`), pi (`shellPath`), and others. Agents with a native rtk hook
should use the hook instead; agents with an embedded shell (crush) cannot use
either.

The shell accepts an `rtk` argument, so you can use a newer rtk from another
flake:

```nix
atb.lib.mkRtkShell { rtk = inputs.nix-ai-tools.packages.${system}.rtk; }
```

## Notice

- `serena` is GPL-3.0-or-later. `solidlsp` remains MIT.
- The `serena` input tracks `main`; `flake.lock` is pinned to the `v2.0.0`
  release commit. Update deliberately with `nix flake update serena`.
- `mcpls` is a prebuilt binary and currently `x86_64-linux` only.
