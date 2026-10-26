{pkgs}: let
  inherit (pkgs) lib;

  # JAIL_HOME is the path HOME points at inside the jail. Normally it is the
  # host home path; persistHomePermissions can move it to $FLAKE_ROOT/.home.
  jailHome = c: [
    (c.add-runtime ''
      JAIL_HOME="''${JAIL_HOME:-$HOME}"
      export JAIL_HOME
    '')
  ];
in rec {
  inherit jailHome;

  # Persist the jail home at $FLAKE_ROOT/.home when FLAKE_ROOT is set. HOME is
  # changed inside the jail, so config mounts must be rebound into JAIL_HOME
  # (see gitPermissions). Without FLAKE_ROOT the home stays a tmpfs.
  persistHomePermissions = c: [
    (c.add-runtime ''
      JAIL_HOME="$HOME"
      PERSIST_HOME_ARGS=()
      if [ -n "''${FLAKE_ROOT:-}" ] && [ -d "''${FLAKE_ROOT}" ]; then
        FLAKE_ROOT="$(realpath -e "''${FLAKE_ROOT}")"
        export FLAKE_ROOT
        mkdir -p "$FLAKE_ROOT/.home"
        JAIL_HOME="$FLAKE_ROOT/.home"
        PERSIST_HOME_ARGS=(--bind "$JAIL_HOME" "$JAIL_HOME")
        RUNTIME_ARGS+=(--setenv HOME "$JAIL_HOME")
      fi
      export JAIL_HOME
    '')
    (c.unsafe-add-raw-args "\"\${PERSIST_HOME_ARGS[@]}\"")
  ];

  # Bind $FLAKE_ROOT (or the cwd when unset) read-write.
  flakeRootPermissions = c: [
    (c.add-runtime ''
      if [ -d "''${FLAKE_ROOT:-$PWD}" ]; then
        FLAKE_ROOT="$(realpath -e "''${FLAKE_ROOT:-$PWD}")"
      else
        FLAKE_ROOT="$PWD"
      fi
      export FLAKE_ROOT
    '')
    (c.unsafe-add-raw-args "--bind \"$FLAKE_ROOT\" \"$FLAKE_ROOT\"")
    (c.try-fwd-env "FLAKE_ROOT")
  ];

  # Forward a project dev-shell environment. Activated by a direnv launcher
  # (AGENTS_FROM_DIRENV=1) or by a plain `nix develop` shell (IN_NIX_SHELL),
  # and prepends the devshell PATH without dropping the jail's own PATH.
  devshellPermissions = c: [
    (c.try-fwd-env "AGENTS_DEVSHELL_PATH")
    (c.wrap-entry (entry: ''
      if [ -n "''${AGENTS_DEVSHELL_PATH:-}" ]; then
        export PATH="''${AGENTS_DEVSHELL_PATH}:$PATH"
      fi
      ${entry}
    ''))
    (c.add-runtime ''
      if [ -z "''${AGENTS_DEVSHELL_PATH:-}" ] && [ -n "''${IN_NIX_SHELL:-}" ]; then
        AGENTS_DEVSHELL_PATH="$PATH"
        export AGENTS_DEVSHELL_PATH
      fi
      if [ "''${AGENTS_FROM_DIRENV:-}" = 1 ] || [ -n "''${IN_NIX_SHELL:-}" ]; then
        while IFS= read -r -d "" entry; do
          name="''${entry%%=*}"
          case "$name" in
            HOME|PATH|PWD|OLDPWD|SHLVL|_|TERM|LANG|LANGUAGE|LC_*|AGENTS_*|DIRENV_*|XDG_RUNTIME_DIR|XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_CACHE_HOME|XDG_STATE_HOME|SSH_AUTH_SOCK|GPG_AGENT_INFO|DBUS_SESSION_BUS_ADDRESS|DISPLAY|WAYLAND_DISPLAY|XAUTHORITY)
              continue
              ;;
          esac
          if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            RUNTIME_ARGS+=(--setenv "$name" "''${!name}")
          fi
        done < <(env -0)
      fi
    '')
  ];

  # Host git config, rebound into the jail home.
  gitPermissions = c:
    jailHome c
    ++ [
      (c.unsafe-add-raw-args "--ro-bind-try \"$HOME/.config/git\" \"$JAIL_HOME/.config/git\"")
    ];

  # Generic Herdr wiring: forward the pane/server environment Herdr injects so
  # agents with native Herdr support can report state. Agent-specific plugins or
  # extensions (opencode, pi, ...) belong to the consumer.
  herdrEnv = {enable ? true}: {
    permissions = c:
      lib.optionals enable [
        (c.try-fwd-env "HERDR_SOCKET_PATH")
        (c.try-fwd-env "HERDR_ENV")
        (c.try-fwd-env "HERDR_PANE_ID")
        (c.try-fwd-env "HERDR_WORKSPACE_ID")
        (c.try-fwd-env "HERDR_TAB_ID")
        (c.try-fwd-env "HERDR_BIN_PATH")
        (c.try-readonly (c.noescape "~/.config/herdr"))
      ];
  };
}
