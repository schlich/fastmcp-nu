{
  description = "fastmcp-nu: MCP servers from annotated Nushell commands";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Copy only the files an output needs, so unrelated edits do not rebuild it.
      source =
        paths:
        lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions paths;
        };
    in
    {
      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.fastmcp-nu;

        fastmcp-nu = pkgs.stdenvNoCC.mkDerivation {
          pname = "fastmcp-nu";
          version = "0.1.0";
          src = source [
            ./bin
            ./fastmcp
            ./examples
          ];

          nativeBuildInputs = [ pkgs.makeWrapper ];
          # Lets patchShebangs point bin/fastmcp-nu at this nu for direct runs.
          buildInputs = [ pkgs.nushell ];
          dontBuild = true;

          # The CLI and the servers it starts (via $nu.current-exe) use the
          # pinned nu. http-nu (for --http) and sh and cat (for the stdout
          # guard) are appended to PATH, so the user's own copies win.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/share/fastmcp-nu
            cp -r bin fastmcp examples $out/share/fastmcp-nu/
            makeWrapper ${pkgs.nushell}/bin/nu $out/bin/fastmcp-nu \
              --add-flags "-n $out/share/fastmcp-nu/bin/fastmcp-nu" \
              --suffix PATH : ${
                lib.makeBinPath [
                  pkgs.http-nu
                  pkgs.bash
                  pkgs.coreutils
                ]
              }
            runHook postInstall
          '';

          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck
            export HOME=$TMPDIR
            $out/bin/fastmcp-nu inspect $out/share/fastmcp-nu/examples/weather.nu > manifest.json
            grep -q '"get-weather"' manifest.json
            runHook postInstallCheck
          '';

          meta = {
            description = "Build Model Context Protocol servers from annotated Nushell commands";
            mainProgram = "fastmcp-nu";
            license = lib.licenses.mit;
            inherit (pkgs.nushell.meta) platforms;
          };
        };
      });

      checks = forAllSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.default;

        # The whole suite, including stdio through the stdout guard, the
        # Node streaming client, and HTTP through http-nu on loopback.
        tests =
          pkgs.runCommand "fastmcp-nu-tests"
            {
              src = source [
                ./bin
                ./fastmcp
                ./examples
                ./tests
              ];
              nativeBuildInputs = [
                pkgs.nushell
                pkgs.http-nu
                pkgs.nodejs
                pkgs.bash
              ];
            }
            ''
              export HOME=$TMPDIR
              cd $src
              nu -n tests/run.nu
              touch $out
            '';
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.nushell
            pkgs.http-nu
            pkgs.nodejs
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
