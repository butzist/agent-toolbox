{
  description = "Jail, env-forwarding and Herdr plumbing for preconfigured AI agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Tracks main; flake.lock is pinned to the v2.0.0 release commit. Bump with
    # `nix flake update serena` when you want to follow newer main.
    serena.url = "github:oraios/serena/main";

    # We drive the sandbox ourselves (no jailed-agents), so bind only what a
    # preconfigured agent needs.
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
  };

  outputs = {self, ...} @ inputs: let
    overlay = import ./overlays {inherit inputs;};
    system = "x86_64-linux";
    pkgs = import inputs.nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [overlay];
    };
    # lib closes over the toolbox's pinned nixpkgs, so consumers do not pass one.
    # Only the wrapped package can be overridden by the caller.
    lib = import ./lib {inherit inputs pkgs;};
  in {
    inherit lib;
    overlays.default = overlay;
    formatter.x86_64-linux = pkgs.alejandra;
  };
}
