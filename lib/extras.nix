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

  # JWT-gated Herdr access for jailed agents (complements herdrEnv, which
  # forwards the raw environment to trusted agents). Herdr's socket API has no
  # authentication, so the jail gets only herdr-auth-proxy's auth socket: every
  # real socket is masked with /dev/null, and the inherited bootstrap token is
  # replaced with an orchestrator token scoped to the agent's directory and
  # workspace. `agentGrants` caps what that token may grant to agents it spawns;
  # child spawns still have to request the grants they use (intersected with
  # this list). The default raises the orchestrator default
  # (agent_grants=["report_status"]), so spawned agents can read their own pane
  # and wait for their own output; the grantable name is `wait_own_output`, not
  # `wait_own_status`. `agentKinds` narrows the spawnable kinds (null = the
  # proxy's global list).
  #
  # Apply after jailHome/persistHomePermissions: the auth socket is bound into
  # $JAIL_HOME and its path is passed to the jail as HERDR_SOCKET_PATH.
  herdrAuth = {
    herdrAuthProxy,
    enable ? true,
    agentGrants ? ["report_status" "read_own_pane" "wait_own_output"],
    agentKinds ? null,
  }: let
    permJson =
      builtins.toJSON
      (
        {agent_grants = agentGrants;}
        // lib.optionalAttrs (agentKinds != null) {agent_kinds = agentKinds;}
      );
  in {
    permissions = c:
      lib.optionals enable [
        (c.add-runtime ''
          HERDR_AUTH_SOCKET="''${HERDR_AUTH_SOCKET:-}"
          if [ -z "$HERDR_AUTH_SOCKET" ]; then
            if [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
              HERDR_AUTH_SOCKET="$XDG_RUNTIME_DIR/herdr-auth-proxy/auth.sock"
            else
              HERDR_AUTH_SOCKET="''${XDG_STATE_HOME:-$HOME/.local/state}/herdr-auth-proxy/auth.sock"
            fi
          fi

          # FLAKE_ROOT can be the home directory, so Herdr's real sockets may be
          # visible in the jail through that bind. Always mask every known real
          # socket with /dev/null (a bind-mount is not a socket, so connect()
          # still fails); only the proxy's auth socket below is left reachable.
          herdr_config_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
          herdr_sockets=(
            "$herdr_config_dir/herdr.sock"
            "$herdr_config_dir/herdr-client.sock"
          )
          if [ -n "''${HERDR_SESSION:-}" ]; then
            herdr_sockets+=(
              "$herdr_config_dir/sessions/$HERDR_SESSION/herdr.sock"
              "$herdr_config_dir/sessions/$HERDR_SESSION/herdr-client.sock"
            )
          fi
          if [ -n "''${HERDR_SOCKET_PATH:-}" ]; then
            herdr_sockets+=("$HERDR_SOCKET_PATH")
            case "$HERDR_SOCKET_PATH" in
              *.sock) herdr_sockets+=("''${HERDR_SOCKET_PATH%.sock}-client.sock") ;;
            esac
          fi
          if [ -n "''${HERDR_CLIENT_SOCKET_PATH:-}" ]; then
            herdr_sockets+=("$HERDR_CLIENT_SOCKET_PATH")
          fi
          declare -A masked_herdr_sockets=()
          for socket in "''${herdr_sockets[@]}"; do
            if [ -z "$socket" ] || [ "$socket" = "$HERDR_AUTH_SOCKET" ] || [ -n "''${masked_herdr_sockets[$socket]:-}" ]; then
              continue
            fi
            masked_herdr_sockets[$socket]=1
            RUNTIME_ARGS+=(--ro-bind-try /dev/null "$socket")
          done

          if [ -S "$HERDR_AUTH_SOCKET" ]; then
            # Reuse only a pane-bound agent token. Decode without trusting the
            # payload: it still has to pass the proxy's signature check.
            jwt_role=""
            if [ -n "''${HERDR_AUTH_JWT:-}" ]; then
              jwt_role="$(printf '%s' "$HERDR_AUTH_JWT" | ${pkgs.jq}/bin/jq -Rr 'split(".")[1] | @base64d | fromjson | .role // empty' 2>/dev/null || true)"
              export HERDR_AUTH_JWT
            fi
            if [ "$jwt_role" != "agent" ]; then
              # The bootstrap token has no cwd/workspace of its own; an
              # orchestrator minted from it must name both. Use the agent's
              # current directory (mount-cwd binds it into the jail) and the
              # workspace the pane belongs to.
              herdr_cwd="$PWD"
              if [ -d "$herdr_cwd" ]; then
                herdr_cwd="$(cd "$herdr_cwd" && pwd -P)" || herdr_cwd=""
              else
                herdr_cwd=""
              fi
              if [ -n "$herdr_cwd" ] && [ -n "''${HERDR_WORKSPACE_ID:-}" ]; then
                HERDR_AUTH_JWT="$(${lib.getExe' herdrAuthProxy "herdr-auth"} --socket "$HERDR_AUTH_SOCKET" token mint \
                  --role orchestrator \
                  --sub "''${HERDR_PANE_ID:-''${USER:-orchestrator}}" \
                  --cwd "$herdr_cwd" \
                  --workspace "$HERDR_WORKSPACE_ID" \
                  --perm ${lib.escapeShellArg permJson} \
                  2>/dev/null | ${pkgs.jq}/bin/jq -r '.token // empty' 2>/dev/null || true)"
              fi
              if [ -z "''${HERDR_AUTH_JWT:-}" ]; then
                unset HERDR_AUTH_JWT
              fi
            fi
            install -d "$JAIL_HOME/.local/state/herdr-auth-proxy"
            RUNTIME_ARGS+=(
              --bind "$HERDR_AUTH_SOCKET" "$JAIL_HOME/.local/state/herdr-auth-proxy/auth.sock"
              --setenv HERDR_SOCKET_PATH "$JAIL_HOME/.local/state/herdr-auth-proxy/auth.sock"
              --setenv HERDR_AUTH_SOCKET "$JAIL_HOME/.local/state/herdr-auth-proxy/auth.sock"
            )
            if [ -n "''${HERDR_AUTH_JWT:-}" ]; then
              RUNTIME_ARGS+=(--setenv HERDR_AUTH_JWT "$HERDR_AUTH_JWT")
            fi
          fi
        '')
        (c.try-fwd-env "HERDR_ENV")
        (c.try-fwd-env "HERDR_PANE_ID")
        (c.try-fwd-env "HERDR_WORKSPACE_ID")
        (c.try-fwd-env "HERDR_TAB_ID")
        (c.try-fwd-env "HERDR_BIN_PATH")
      ];
  };

  # Build a Herdr agent integration from Herdr's own plugin assets. Herdr's
  # generated config is kept as-is; consumers can link the files from `dir`
  # (host) or apply `permissions` (jail). `home` is the config directory
  # relative to HOME (e.g. ".config/opencode"). Returns {dir, permissions};
  # apply `permissions` after jailHome/persistHomePermissions.
  mkHerdrIntegration = {
    herdr,
    target,
    home,
  }: let
    dir =
      pkgs.runCommand "herdr-${target}-integration" {
        nativeBuildInputs = [herdr];
      } ''
        mkdir -p home/${home}
        HOME=$TMPDIR/home XDG_CONFIG_HOME=$TMPDIR/home/.config \
          ${lib.getExe herdr} integration install ${target} >/dev/null
        mkdir -p $out
        cp -a home/${home}/. $out/
        chmod -R u+w $out
      '';
  in {
    inherit dir;
    permissions = c: [
      (c.wrap-entry (entry: ''
        target_dir="''${JAIL_HOME:-$HOME}/${home}"
        mkdir -p "$target_dir"
        cp -r --no-preserve=mode,ownership ${dir}/. "$target_dir/"
        chmod -R u+w "$target_dir"
        ${entry}
      ''))
    ];
  };
}
