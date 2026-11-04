{
  description = "Jail, env-forwarding and Herdr plumbing for preconfigured AI agents";

  inputs = {
    # Tracks main; flake.lock is pinned to the v2.0.0 release commit. Bump with
    # `nix flake update serena` when you want to follow newer main.
    serena.url = "github:oraios/serena/main";

    # We drive the sandbox ourselves (no jailed-agents), so bind only what a
    # preconfigured agent needs.
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
  };

  outputs = {self, ...} @ inputs: let
    overlay = import ./overlays {inherit inputs;};
  in {
    # The caller supplies the package set, so the jail, its base tools and the
    # combinators are built from the same nixpkgs as the agent package.
    lib = pkgs: import ./lib {inherit inputs pkgs;};
    overlays.default = overlay;
  };
}
