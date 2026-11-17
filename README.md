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
lib.mkHerdrWrapped     # herdr launcher that keeps herdr-auth-proxy running
lib.combinators        # jail.nix combinators bound to the toolbox's nixpkgs
lib.jail               # jail.nix init
lib.extras             # flake-root, devshell, persistent home, git, herdr env/auth
```

`lib` is a function of the consumer's package set (`lib pkgs`), so the jail,
its base tools and the combinators are built from the same nixpkgs as the agent
package; the flake has no nixpkgs input of its own.

`overlays.default` provides `mcpls` and `serena`. The `serena` wrapper clears
`PYTHONPATH` before exec, so a consumer launched from a Python dev shell cannot
shadow serena's own venv with another interpreter's site-packages.

## Building an agent

Everything agent-specific lives in your configuration. The shape is:

```nix
let
  atb = inputs.agent-toolbox.lib pkgs;
  agent = atb.mkAgent {
    name = "my-agent";
    package = myAgentPackage;          # wrapper with config baked in
    envFromFile.API_KEY = tokenPath;   # read on the host, forwarded into the jail
  };
in {
  inherit (agent) free;                # my-agent-free
  jailed = agent.makeJailedWith {
    permissions = c:
      atb.defaultPermissions c
      ++ (atb.extras.herdrEnv {}).permissions c;
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

## OOM

A jailed agent is expendable. `mkJailedAgent` writes `oom_score_adj=1000` (the
kernel OOM killer's maximum preference) to its own `/proc` entry before
bubblewrap starts, and every process inside the jail inherits it, so a runaway
agent is killed before the desktop session is. Raising the score needs no
privileges; lowering it does, so only values in `0..1000` are accepted.

Set `oomScoreAdjust = 0` to leave the inherited score alone; the `free` variant
is never adjusted.

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
- `herdrAuth` — the jailed variant of the above: masks every real Herdr socket
  with `/dev/null`, binds only herdr-auth-proxy's JWT-gated `auth.sock` into
  `$JAIL_HOME`, and replaces an inherited bootstrap token with an orchestrator
  token scoped to the agent's directory and workspace. `agentGrants` caps what
  the jail may grant the agents it spawns. Takes the proxy package and must be
  applied after `jailHome`/`persistHomePermissions`:

  ```nix
  (atb.extras.herdrAuth {herdrAuthProxy = myProxyPackage;}).permissions c
  ```

- `mkHerdrIntegration` — builds Herdr's integration assets for one agent
  (`herdr integration install <target>`), including the generated config files
  and plugin code. Herdr owns both; consumers do not rewrite them. Returns
  `{dir, permissions}`; apply `permissions` after
  `jailHome`/`persistHomePermissions`:

  ```nix
  let
    opencodeHerdr = atb.extras.mkHerdrIntegration {
      herdr = herdrPackage;
      target = "opencode";
      home = ".config/opencode";
    };
  in
  opencodeHerdr.permissions c
  ```

  For a host (non-jail) config, link the files from `integration.dir` instead,
  for example with `xdg.configFile`. Agent-specific settings that belong
  outside the integration (for example OpenCode CLI options) stay in the
  consumer's own agent wrapper.

## Herdr

`mkHerdrWrapped` returns a `herdr` launcher that starts
[herdr-auth-proxy](https://github.com/butzist/herdr-auth-proxy) alongside the
Herdr server, so the server inherits a bootstrap orchestrator token and every
other client has to authenticate. CLI subcommands still talk to Herdr's real
socket directly; `herdr server stop` keeps working when the running server has
no usable token.

```nix
home.packages = [
  (atb.mkHerdrWrapped {
    herdr = inputs.llm-agents.packages.${system}.herdr;
    herdrAuthProxy = inputs.herdr-auth-proxy.packages.${system}.default;
  })
  inputs.herdr-auth-proxy.packages.${system}.default
];
```

The wrapper only manages the proxy session. Herdr's own config, themes and
keymaps remain consumer-side; agent integrations can be prepared with
`mkHerdrIntegration` above.

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
atb.mkRtkShell { rtk = inputs.llm-agents.packages.${system}.rtk; }
```

## Notice

- `serena` is GPL-3.0-or-later. `solidlsp` remains MIT.
- The `serena` input tracks `main`; `flake.lock` is pinned to the `v2.0.0`
  release commit. Update deliberately with `nix flake update serena`.
- `mcpls` is a prebuilt binary and currently `x86_64-linux` only.
