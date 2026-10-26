{
  inputs,
  pkgs,
}: let
  # Drop-in shell that pipes each `-c` command through `rtk rewrite`, then runs
  # the rewrite (or the original). Agents that let you override their shell
  # (opencode's `shell`, pi's `shellPath`, goose's `GOOSE_SHELL`, ...) can
  # point at it; agents with a native rtk hook should use that instead.
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
  # `c: defaultPermissions c ++ [ (c.readonly "/nix/store") ]`.
  defaultPermissions = c: [
    c.network
    c.time-zone
    c.no-new-session
    (c.add-pkg-deps defaultBasePackages)
    c.mount-cwd
  ];

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
    # The package's bin is always on PATH: a wrapped agent may bundle extra
    # packages next to itself.
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
  # Opinionated jail/launcher pieces shared by NixOS and devshell setups:
  # FLAKE_ROOT, devshell env forwarding, project-local persistent home, git
  # rebinding, Herdr env and jail home.
  extras = import ./extras.nix {inherit pkgs;};

  inherit mkRtkShell defaultBasePackages defaultPermissions;
  inherit mkEnvFromFile mkJailedAgent;
  # jail.nix combinators, already bound to the toolbox's pinned nixpkgs.
  combinators = (inputs.jail-nix.lib.init pkgs).combinators;
  jail = inputs.jail-nix.lib.init pkgs;

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
}
