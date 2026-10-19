{
  description = "Configurable (optionally jailed) goose + opencode with serena/mcpls MCP servers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

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
    # Only the agent package itself can be overridden (`package = pkgs.opencode`).
    lib = import ./lib {inherit inputs pkgs;};
  in
    {
      inherit lib;
      overlays.default = overlay;
    }
    // inputs.flake-utils.lib.eachSystem [system] (_: {
      packages = rec {
        default = opencode;
        opencode = lib.mkOpencode {};
        goose = lib.mkGoose {};
        opencode-jailed = lib.mkOpencodeJailed {};
        goose-jailed = lib.mkGooseJailed {};
      };

      formatter = pkgs.alejandra;
    });
}
