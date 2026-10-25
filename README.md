# agent-toolbox

Configurable, optionally jailed [goose](https://github.com/aaif-goose/goose) and
[opencode](https://opencode.ai), wired to the
[serena](https://github.com/oraios/serena) and
[mcpls](https://github.com/bug-ops/mcpls) MCP servers and to
[rtk](https://github.com/rtk-ai/rtk) for token-filtered command output.

This flake packages the agent CLIs, the MCP servers, and a default agent config,
and exposes them as plain packages, as jailed (bubblewrap) packages, and as an
overlay. It contains **no secrets** — API keys are injected at launch (see
*Secrets*).

## Packages

```
packages.x86_64-linux.opencode        # opencode + config wrapper
packages.x86_64-linux.goose           # goose + config wrapper
packages.x86_64-linux.opencode-jailed # same, run inside a jail.nix sandbox
packages.x86_64-linux.goose-jailed
```

Each CLI package is a `symlinkJoin` containing the upstream binary (from
`pkgs.opencode` / `pkgs.goose-cli`) plus a small wrapper that links the bundled
configuration:

- **opencode**: sets `OPENCODE_CONFIG` to the generated config. opencode merges
  that between its global and project configs.
- **goose**: goose reads `XDG_CONFIG_HOME/goose/config.yaml` and has no
  config-path env var, so the wrapper sets `XDG_CONFIG_HOME` to a store dir that
  holds `goose/config.yaml`. The config is read-only as a result.

Both wrappers also put `serena`, `mcpls` and the language servers on `PATH`.

## Configuration

The default configs are exported and every constructor takes a `config` argument:

```nix
{
  inputs.agent-toolbox.url = "github:butzist/agent-toolbox";
}
```

The library pins its own nixpkgs, so you do not pass one; the `pkgs` below is
your own nixpkgs, used only for `lib` and for packages you add yourself:

```nix
# build only what you need, with your own config merged over the defaults
(let
  atb = inputs.agent-toolbox;
  pkgs = import inputs.nixpkgs { inherit system; };
in {
  packages.${system}.my-opencode = atb.lib.mkOpencode {
    config = pkgs.lib.recursiveUpdate atb.lib.defaultOpencodeConfig {
      model = "opencode-go/deepseek-v4.1-flash";
    };
    extraPackages = [ pkgs.nixd ];
  };

  packages.${system}.my-goose = atb.lib.mkGoose {
    config = pkgs.lib.recursiveUpdate atb.lib.defaultGooseConfig {
      extensions.developer.enabled = false;
    };
  };
})
```

`mkOpencode` / `mkGoose` arguments: `name` (executable/wrapper name, default
`opencode` / `goose`), `config`, `package` (override the upstream binary, e.g.
`pkgs.opencode`), `extraPackages` (extra packages on the wrapper's `PATH`), and
(for `mkGoose`) `shell`. They produce env-free packages; secrets and jailing are
composed on top with `mkEnvFromFile` / `mkAgent`.

## rtk (token filtering)

RTK has no hook for goose, but goose runs tool calls as
`<GOOSE_SHELL> -c "<cmd>"` on unix, so `lib.mkRtkShell` provides a drop-in shell
that pipes each `-c` command through `rtk rewrite` and runs the result (falling
back to the original; `rtk rewrite` denial is turned into a non-zero exit).

- **goose**: `mkGoose` sets `GOOSE_SHELL` to the rtk shell by default.
- **opencode**: the default opencode config sets `shell` to the rtk shell. (RTK
  also has a native opencode plugin; this uses the shell path instead so it works
  with any rtk version that has `rewrite`.)

Override with `shell = null`-style by passing your own `shell`, or drop the
`shell` key from the opencode `config`.

## Jailed variants

`mkOpencodeJailed` / `mkGooseJailed` / `mkJailedAgent` build the sandbox with
[jail.nix](https://git.sr.ht/~alexdavid/jail.nix) directly. They take `name`,
`config`, `package`, `extraPackages`, `permissions` (a list or a
`combinators -> list` lambda, extending `defaultOpencodePermissions` /
`defaultGoosePermissions`), and `envFromFile`. `envFromFile = { NAME = path; }`
reads `path` into `NAME` in the host environment in a wrapper, then forwards it
into the jail with `try-fwd-env` (the secret never enters the store) — no
per-variable `try-fwd-env` permission is needed in `permissions`.

`mkJailedAgent` always adds the prewrapped package's `bin` to the jail `PATH`.
A host-side wrapper can append extra bwrap arguments without rebuilding the
agent by setting `JAIL_EXTRA_ARGS` (shell word splitting, so paths with spaces
are not supported). Since `mkOpencode` / `mkGoose` merge `extraPackages` into
that package, the same composable definition works for both jailed and free
variants:

`mkAgent` bundles one env-free package with both variants, and `mkEnvFromFile`
is the host-side secret wrapper it uses:

```nix
let
  agent = atb.lib.mkAgent {
    name = "opencode";
    package = atb.lib.mkOpencode {
      extraPackages = [ pkgs.nixd ];
    };
    envFromFile.OPENCODE_API_KEY = tokenPath;       # read on the host
  };
in {
  free = agent.free;                               # `opencode-free` runCommand
  withEnv = agent.withEnv;                         # `opencode` + host env
  jailed = agent.makeJailedWith {
    name = "opencode-jailed";                      # optional, defaults to `name`
    permissions = atb.lib.defaultOpencodePermissions;
  };                                               # forwards env into the jail
}
```

The convenience constructors take the same arguments directly:

```nix
atb.lib.mkOpencodeJailed {
  extraPackages = [ pkgs.nixd ];
}
```

The jail is **ephemeral**: the only host path mounted by default is the working
directory (`mount-cwd`). The config is baked into the package and its store
closure is bound by `bind-nix-store-runtime-closure`; home is a tmpfs, so runtime
state is discarded on exit. Mount specific host dirs read-only/read-write by
extending `permissions` (e.g. `c.readonly`, `c.readwrite`).

**Secrets** are never in the store. Inject them at launch from the host:

```nix
atb.lib.mkGooseJailed {
  permissions = c:
    atb.lib.defaultGoosePermissions c
    ++ [ (c.readonly "/run/user") ];      # agenix lives under /run/user
  envFromFile.OPENCODE_API_KEY = tokenPath;       # read on the host, forwarded
}
```

## NixOS / devshell extras

`lib.extras` collects the opinionated pieces shared by the NixOS and devshell
setup:

- `persistHomePermissions` — when `FLAKE_ROOT` is set, creates
  `$FLAKE_ROOT/.home`, points the jail's `HOME` at it, and persists state there.
  Without `FLAKE_ROOT` the home stays an ephemeral tmpfs.
- `flakeRootPermissions` — binds `FLAKE_ROOT` (or the cwd) read-write.
- `devshellPermissions` — forwards the direnv / `nix develop` environment into
  the jail and prepends the devshell `PATH`.
- `gitPermissions` — rebinds the host `~/.config/git` into `JAIL_HOME/.config/git`.
- `herdr { enable, package }` — forwards the Herdr socket/env and copies the
  matching OpenCode plugin into the jail.
- `allowAllReads config` — auto-approves reads of everything visible inside the
  jail; it does not widen the jail's mounts.
- `jailHome` — sets `JAIL_HOME` to `$HOME` unless `persistHomePermissions`
  already moved it.

Permission order matters: apply `persistHomePermissions`, then
`flakeRootPermissions`, then `gitPermissions` and any other mounts that need to
land in `JAIL_HOME`.

## Notice

- `serena` is GPL-3.0-or-later. `solidlsp` remains MIT.
- The `serena` input tracks `main`; `flake.lock` is pinned to the `v2.0.0`
  release commit. Update deliberately with `nix flake update serena`.
- `goose-cli` / `mcpls` are prebuilt binaries and currently `x86_64-linux` only.
