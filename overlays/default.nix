{
  inputs,
  ...
}: final: prev: let
  system = prev.stdenv.hostPlatform.system;
in {
  # Prebuilt musl release binary: statically linked, so no compile and no
  # patchelf/lib fixups.
  goose-cli = prev.stdenvNoCC.mkDerivation {
    pname = "goose-cli";
    version = "1.55.0";

    src = prev.fetchurl {
      url = "https://github.com/aaif-goose/goose/releases/download/v1.55.0/goose-x86_64-unknown-linux-musl.tar.gz";
      hash = "sha256-+t4Ue9XrwCDs6gVFOwkFOX8euwHuPeLzZ4VwxcNQLtc=";
    };

    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 goose $out/bin/goose
      runHook postInstall
    '';

    meta = {
      description = "An open source AI agent CLI";
      homepage = "https://github.com/aaif-goose/goose";
      license = prev.lib.licenses.asl20;
      mainProgram = "goose";
      platforms = ["x86_64-linux"];
    };
  };

  # Universal MCP-to-LSP bridge (prebuilt binary, same approach as goose-cli).
  mcpls = prev.stdenvNoCC.mkDerivation {
    pname = "mcpls";
    version = "0.7.0";

    src = prev.fetchurl {
      url = "https://github.com/bug-ops/mcpls/releases/download/v0.7.0/mcpls-x86_64-unknown-linux-gnu.tar.gz";
      hash = "sha256-2swTJNbAEOtjEYBxXgm5hPFLzH+uoHmk015BFtdJUVo=";
    };

    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 mcpls $out/bin/mcpls
      runHook postInstall
    '';

    meta = {
      description = "Universal MCP-to-LSP bridge exposing language servers as MCP tools";
      homepage = "https://github.com/bug-ops/mcpls";
      license = prev.lib.licenses.asl20;
      mainProgram = "mcpls";
      platforms = ["x86_64-linux"];
    };
  };

  # serena ships its own uv2nix flake; reuse it instead of rebuilding its
  # Python closure here.
  serena = inputs.serena.packages.${system}.serena;
}
