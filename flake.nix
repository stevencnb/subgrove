{
  description = "subgrove — parallel feature worktrees for a git superproject with submodules";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  # subgrove is a single self-contained shell script, so this builds straight
  # from source (no fetch/checksum needed): `nix run github:stevencnb/subgrove`
  # once pushed, or `nix build` / `nix run` from a checkout. Run `nix flake lock`
  # once to pin nixpkgs. A nixpkgs submission would instead use a
  # `fetchFromGitHub` derivation pinned to a release rev + sha256.
  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenvNoCC.mkDerivation {
          pname = "subgrove";
          version = "0.2.0"; # keep in sync with VERSION in ./subgrove
          src = self;
          nativeBuildInputs = [ pkgs.installShellFiles pkgs.makeWrapper ];
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            runHook preInstall
            install -Dm755 subgrove "$out/bin/subgrove"
            # Make the runtime tools subgrove shells out to available regardless
            # of the user's PATH. (patchShebangs in fixupPhase rewrites the
            # `/usr/bin/env bash` shebang to the build's bash.)
            wrapProgram "$out/bin/subgrove" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.coreutils pkgs.gawk pkgs.gnused ]}
            installShellCompletion --cmd subgrove \
              --bash completions/subgrove.bash \
              --zsh completions/_subgrove
            runHook postInstall
          '';
          meta = with nixpkgs.lib; {
            description = "Parallel feature worktrees for a git superproject with submodules";
            homepage = "https://github.com/stevencnb/subgrove";
            license = licenses.mit;
            mainProgram = "subgrove";
            platforms = platforms.unix;
          };
        };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.default}/bin/subgrove";
        };
      });
    };
}
