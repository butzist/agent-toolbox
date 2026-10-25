{
  inputs,
  pkgs,
}: let
  # goose's flat extension shape, as goose itself writes it.
  ext = enabled: type: name: displayName: description: {
    inherit enabled type name description;
    display_name = displayName;
    bundled = true;
  };

  # MCP stdio extensions are addressed by store path so they resolve without
  # relying on PATH (also inside jails).
  mcpServer = name: package: args: {
    enabled = true;
    type = "stdio";
    inherit name args;
    cmd = "${package}/bin/${name}";
  };

  serenaArgs = ["start-mcp-server" "--context" "agent"];

  # Prepend `extraPackages` to PATH so they work even when the wrapper is
  # invoked through a renamed symlink (the symlinkJoin alone only exposes them
  # when the package itself is linked into the caller's profile).
  mkExtraPath = extraPackages:
    pkgs.lib.optionalString (extraPackages != []) ''
      export PATH=${pkgs.lib.makeBinPath extraPackages}''${PATH:+:$PATH}
    '';

  # Drop-in shell that pipes each `-c` command through `rtk rewrite`, then runs
  # the rewrite (or the original). goose has no command hook, but it runs tool
  # calls as `<GOOSE_SHELL> -c "<cmd>"` on unix, so pointing GOOSE_SHELL here
  # gives goose rtk's output filtering; opencode uses it via its `shell` option.
  # `rtk rewrite` exit codes: 0/3 rewrite, 1 no rewrite, 2 deny.
  mkRtkShell = {rtk ? pkgs.rtk}:
    pkgs.writeShellApplication {
      name = "rtk-shell";
      runtimeInputs = [pkgs.bash rtk];
      text = ''
        if [ "$#" -ge 2 ] && [ "$1" = "-c" ]; then
          cmd="$2"
          shift 2
          rc=0
          rewritten="$(rtk rewrite "$cmd" 2>/dev/null)" || rc=$?
          case "$rc" in
            0|3)
              if [ -n "$rewritten" ]; then
                cmd="$rewritten"
              fi
              ;;
            2)
              printf '%s\n' "''${rewritten:-rtk denied this command}" >&2
              exit 126
              ;;
          esac
          exec bash -c "$cmd" "$@"
        fi
        exec bash "$@"
      '';
    };

  defaultOpencodeConfig = {
    "$schema" = "https://opencode.ai/config.json";
    lsp = true;
    # Route agent shell calls through rtk.
    shell = "${mkRtkShell {}}/bin/rtk-shell";
    # opencode has its own LSP; serena is added for semantic retrieval/editing.
    mcp.serena = {
      type = "local";
      command = ["${pkgs.serena}/bin/serena"] ++ serenaArgs;
      enabled = true;
    };
  };

  defaultGooseConfig = {
    GOOSE_TELEMETRY_ENABLED = false;
    GOOSE_CONTEXT_LIMIT = 64000;
    GOOSE_AUTO_COMPACT_THRESHOLD = 0.63;
    GOOSE_THINKING_EFFORT = "medium";
    extensions = {
      todo = ext true "platform" "todo" "Todo" "Enable a todo list for goose so it can keep track of what it is doing";
      chatrecall = ext false "platform" "chatrecall" "Chat Recall" "Search past conversations and load session summaries for contextual memory";
      scheduler = ext true "platform" "scheduler" "Scheduler" "Create and manage scheduled recipe execution";
      extensionmanager = ext true "platform" "Extension Manager" "Extension Manager" "Enable extension management tools for discovering, enabling, and disabling extensions";
      tom = ext true "platform" "tom" "Top Of Mind" "Inject custom context into every turn via GOOSE_MOIM_MESSAGE_TEXT and GOOSE_MOIM_MESSAGE_FILE environment variables";
      skills = ext true "platform" "skills" "Skills" "Discover and provide skill instructions from filesystem and builtins";
      code_execution = ext false "platform" "code_execution" "Code Mode" "Goose will make extension calls through code execution, saving tokens";
      summon = ext true "platform" "summon" "Summon" "Load knowledge and delegate tasks to subagents";
      analyze = ext true "platform" "analyze" "Analyze" "Analyze code structure with tree-sitter: directory overviews, file details, symbol call graphs";
      apps = ext true "platform" "apps" "Apps" "Create and manage custom Goose apps through chat. Apps are HTML/CSS/JavaScript and run in sandboxed windows.";
      summarize = ext true "platform" "summarize" "Summarize" "Load files/directories and get an LLM summary in a single call";
      developer = ext true "builtin" "developer" "Developer" "Write and edit files, and execute shell commands";
      serena = mcpServer "serena" pkgs.serena serenaArgs;
      mcpls = mcpServer "mcpls" pkgs.mcpls [];
    };
  };
  # Default tools inside an agent jail. Deliberately no node/npm.
  defaultBasePackages = with pkgs; [
    bashInteractive
    coreutils
    git
    curl
    wget
    jq
    which
    ripgrep
    gnugrep
    gawkInteractive
    ps
    findutils
    gzip
    unzip
    gnutar
    diffutils
    gnused
    python3
    fd
    tree
    less
    file
  ];

  # Default sandbox permissions: network, shared timezone, isolated session,
  # the default tool packages, and the working dir (rw). `permissions` is a list
  # or `combinators -> list`; callers extend it, e.g.
  # `c: defaultOpencodePermissions c ++ [ (c.readonly "/nix/store") ]`.
  defaultPermissions = c: [
    c.network
    c.time-zone
    c.no-new-session
    (c.add-pkg-deps defaultBasePackages)
    c.mount-cwd
  ];
  defaultOpencodePermissions = c:
    defaultPermissions c ++ [(c.add-pkg-deps [pkgs.xdg-utils])];
  defaultGoosePermissions = c: defaultPermissions c;

  # Host-side env injection: reads each `envFromFile` path and exports it before
  # exec. Kept out of the agent packages so one env-free package can serve both
  # variants; mkJailedAgent forwards the vars into the jail instead of reading
  # the files there.
  mkEnvFromFile = {
    name,
    package,
    envFromFile ? {},
  }:
    if envFromFile == {}
    then package
    else
      (pkgs.writeShellScriptBin name ''
        ${pkgs.lib.concatStringsSep "\n" (
          pkgs.lib.mapAttrsToList (n: f: ''export ${n}="$(cat ${f})"'') envFromFile
        )}
        exec ${pkgs.lib.getExe package} "$@"
      '')
      .overrideAttrs (old: {
        meta = (old.meta or {}) // {mainProgram = name;};
      });

  # Build a jail with jail.nix directly. Because the agent is preconfigured (its
  # config is baked into the package) no host config/state dirs are bound: home
  # is a tmpfs, so state is discarded on exit. `envFromFile` vars are read into
  # the host environment by mkEnvFromFile; mkJailedAgent adds the jail.nix
  # try-fwd-env permissions so they are forwarded into the jail.
  mkJailedAgent = {
    name,
    package,
    permissions ? defaultPermissions,
    envFromFile ? {},
  }: let
    jail = inputs.jail-nix.lib.init pkgs;
    c = jail.combinators;
    # `permissions` is a list or a `combinators -> list` lambda (see jail.nix).
    # The package's bin is always on PATH: a prewrapped agent may bundle extra
    # packages next to itself (mkOpencode/mkGoose `extraPackages`).
    permList =
      (
        if pkgs.lib.isFunction permissions
        then permissions c
        else permissions
      )
      ++ [(c.add-path "${pkgs.lib.getBin package}/bin")]
      # Host-side launchers can append bwrap arguments without rebuilding the
      # agent. The value is split with normal shell word splitting, so paths
      # with spaces are not supported.
      ++ [
        (c.add-runtime ''
          if [ -n "''${JAIL_EXTRA_ARGS:-}" ]; then
            read -r -a jail_extra_args <<< "$JAIL_EXTRA_ARGS"
            RUNTIME_ARGS+=("''${jail_extra_args[@]}")
          fi
        '')
      ];
    fwdPermissions = map (v: c.try-fwd-env v) (pkgs.lib.attrNames envFromFile);
    jailed = jail name package (permList ++ fwdPermissions);
  in
    mkEnvFromFile {
      inherit name envFromFile;
      package = jailed;
    };
in rec {
  # Opinionated pieces used by the NixOS/devshell setup: FLAKE_ROOT, devshell
  # env forwarding, project-local persistent home, Herdr, git rebinding and
  # jail-level read approval.
  extras = import ./extras.nix {inherit pkgs;};

  inherit defaultGooseConfig defaultOpencodeConfig mkRtkShell;
  inherit mkJailedAgent mkEnvFromFile defaultBasePackages;
  inherit defaultPermissions defaultOpencodePermissions defaultGoosePermissions;
  # jail.nix combinators, already bound to the toolbox's pinned nixpkgs.
  combinators = (inputs.jail-nix.lib.init pkgs).combinators;
  jail = inputs.jail-nix.lib.init pkgs;

  # opencode wrapper: OPENCODE_CONFIG is merged between the global and project
  # configs, so the bundled config layers on top of whatever the user has.
  mkOpencode = {
    name ? "opencode",
    config ? defaultOpencodeConfig,
    package ? pkgs.opencode,
    extraPackages ? [],
  }: let
    configFile = (pkgs.formats.json {}).generate "opencode-config.json" config;
    wrapper = pkgs.writeShellScriptBin name ''
      ${mkExtraPath extraPackages}
      export OPENCODE_CONFIG=${configFile}
      # A background server would escape the jail's lifecycle and could be
      # shared across projects; keep opencode's server private to this run.
      # Utility subcommands reject --standalone, so only add it to the TUI,
      # run/mini, and TUI flags.
      standalone=0
      case "''${1:-}" in
        ""|run|mini|-*) standalone=1 ;;
        upgrade|update|acp|debug|auth|mcp|plugin|session|service|pair|serve) ;;
        *) standalone=1 ;;
      esac
      if [ "$standalone" = 1 ]; then
        for arg in "$@"; do
          if [ "$arg" = "--standalone" ]; then
            standalone=0
            break
          fi
        done
      fi
      if [ "$standalone" = 1 ]; then
        set -- --standalone "$@"
      fi
      exec ${pkgs.lib.getExe package} "$@"
    '';
  in
    (pkgs.symlinkJoin {
      inherit name;
      paths = [wrapper] ++ extraPackages;
    })
    .overrideAttrs (old: {
      meta = (old.meta or {}) // {mainProgram = name;};
    });

  # goose wrapper: goose has no config-path env var, so point XDG_CONFIG_HOME at
  # a store dir that holds goose/config.yaml. Config is read-only (goose
  # configure will not persist) and MCP children inherit XDG_CONFIG_HOME.
  mkGoose = {
    name ? "goose",
    config ? defaultGooseConfig,
    package ? pkgs.goose-cli,
    shell ? mkRtkShell {},
    extraPackages ? [],
  }: let
    configFile = (pkgs.formats.yaml {}).generate "goose-config.yaml" config;
    configHome = pkgs.runCommand "goose-config-home" {} ''
      mkdir -p $out/goose
      ln -s ${configFile} $out/goose/config.yaml
    '';
    wrapper = pkgs.writeShellScriptBin name ''
      ${mkExtraPath extraPackages}
      export XDG_CONFIG_HOME=${configHome}
      export GOOSE_SHELL=${shell}/bin/rtk-shell
      exec ${pkgs.lib.getExe package} "$@"
    '';
  in
    (pkgs.symlinkJoin {
      inherit name;
      paths = [wrapper] ++ extraPackages;
    })
    .overrideAttrs (old: {
      meta = (old.meta or {}) // {mainProgram = name;};
    });

  # Bundle a config-wrapped, env-free agent package with its variants. `withEnv`
  # adds envFromFile on the host, `free` renames that to `<name>-free`, and
  # `makeJailedWith` wraps the package in a jail, forwarding those vars instead
  # of reading the files there.
  mkAgent = {
    name,
    package,
    envFromFile ? {},
  }: let
    agentName = name;
    withEnv = mkEnvFromFile {inherit name package envFromFile;};
  in {
    inherit name package withEnv;
    free = pkgs.runCommand "${name}-free" {} ''
      mkdir -p $out/bin
      ln -s ${pkgs.lib.getExe withEnv} $out/bin/${name}-free
    '';
    makeJailedWith = {
      permissions ? defaultPermissions,
      name ? agentName,
    }:
      mkJailedAgent {inherit name package permissions envFromFile;};
  };

  # Jailed variants; the config-wrapped agent becomes the jail's exe. Override
  # `permissions` (list or `combinators -> list`) to change the sandbox.
  mkOpencodeJailed = {
    name ? "opencode-jailed",
    config ? defaultOpencodeConfig,
    package ? pkgs.opencode,
    permissions ? defaultOpencodePermissions,
    envFromFile ? {},
    extraPackages ? [],
  }: let
    agent = mkOpencode {inherit name config package extraPackages;};
  in
    mkJailedAgent {
      inherit name permissions envFromFile;
      package = agent;
    };

  mkGooseJailed = {
    name ? "goose-jailed",
    config ? defaultGooseConfig,
    package ? pkgs.goose-cli,
    permissions ? defaultGoosePermissions,
    envFromFile ? {},
    extraPackages ? [],
  }: let
    agent = mkGoose {inherit name config package extraPackages;};
  in
    mkJailedAgent {
      inherit name permissions envFromFile;
      package = agent;
    };
}
