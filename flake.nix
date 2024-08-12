{
  description = "Nix interop for the Effekt programming language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    sbt-derivation = {
      url = "github:zaninime/sbt-derivation";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    # The main repo of the Effekt language itself, together with its submodules
    effekt-nightly = {
      flake = false;
      url = "git+https://github.com/effekt-lang/effekt?submodules=1&allRefs=1";
    };
  };

  outputs = { self, nixpkgs, flake-utils, sbt-derivation, effekt-nightly }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Effekt versions and their corresponding SHA256 hashes
        effektVersions = {
          "0.2.2" = "hYlJg/jpFK3FFze3udXa8lLysVOf7F0HtwALf13TcqM=";
          # NOTE: Add more versions here as needed
        };

        # Gets the newest version from 'effektVersions'
        latestVersion = builtins.head (builtins.sort (a: b: builtins.compareVersions a b > 0) (builtins.attrNames effektVersions));

        # Checks if MLton is available for the current system
        isMLtonSupported = builtins.elem system pkgs.mlton.meta.platforms;

        # Available backends for Effekt, depending on the current 'system'
        effektBackends = {
          js = {
            name = "js";
            buildInputs = [pkgs.nodejs];
          };
          llvm = {
            name = "llvm";
            buildInputs = [pkgs.llvm pkgs.libuv];
          };
          chez-callcc = {
            name = "chez-callcc";
            buildInputs = [pkgs.chez];
          };
          chez-monadic = {
            name = "chez-monadic";
            buildInputs = [pkgs.chez];
          };
          chez-lift = {
            name = "chez-lift";
            buildInputs = [pkgs.chez];
          };
        } // (if isMLtonSupported then {
          ml = {
            name = "ml";
            buildInputs = [pkgs.mlton];
          };
        } else {});

        # Creates an Effekt derivation from a prebuilt GitHub release
        buildEffektRelease = { version, sha256, backends ? [effektBackends.js] }:
          assert backends != []; # Ensure at least one backend is specified
          pkgs.stdenv.mkDerivation {
            pname = "effekt";
            inherit version;

            src = pkgs.fetchurl {
              url = "https://github.com/effekt-lang/effekt/releases/download/v${version}/effekt.tgz";
              inherit sha256;
            };

            nativeBuildInputs = [pkgs.makeWrapper];
            buildInputs = [pkgs.jre] ++ pkgs.lib.concatMap (b: b.buildInputs) backends;

            installPhase = ''
              mkdir -p $out/bin $out/lib
              mv bin/effekt $out/lib/effekt.jar
              mv libraries $out/libraries

              makeWrapper ${pkgs.jre}/bin/java $out/bin/effekt \
                --add-flags "-jar $out/lib/effekt.jar" \
                --prefix PATH : ${pkgs.lib.makeBinPath (pkgs.lib.concatMap (b: b.buildInputs) backends)}
            '';
          };

        # Creates an Effekt derivation by building Effekt from (some) source
        buildEffektFromSource = { src, backends ? [effektBackends.js], depsSha256 ? "Yzv6lcIpu8xYv3K7ymoJIcnqJWem1sUWGSQm8253SUw=", version ? "0.99.99+nightly" }:
          assert backends != []; # Ensure at least one backend is specified
          sbt-derivation.lib.mkSbtDerivation {
            inherit pkgs;
            pname = "effekt";
            inherit version;
            inherit src;

            inherit depsSha256;

            nativeBuildInputs = [pkgs.nodejs pkgs.maven pkgs.makeWrapper pkgs.gnused];
            buildInputs = [pkgs.jre] ++ pkgs.lib.concatMap (b: b.buildInputs) backends;

            # Change the version in build.sbt
            prePatch = ''
              sed -i 's/lazy val effektVersion = "[^"]*"/lazy val effektVersion = "${version}"/' build.sbt
            '';

            buildPhase = ''
              export MAVEN_OPTS="-Dmaven.repo.local=$out/.m2/repository"
              sbt assembleBinary
            '';

            installPhase = ''
              mkdir -p $out/bin $out/lib
              mv bin/effekt $out/lib/effekt.jar
              mv libraries $out/libraries

              makeWrapper ${pkgs.jre}/bin/java $out/bin/effekt \
                --add-flags "-jar $out/lib/effekt.jar" \
                --prefix PATH : ${pkgs.lib.makeBinPath (pkgs.lib.concatMap (b: b.buildInputs) backends)}
            '';
          };

        # Builds an Effekt package
        buildEffektPackage = {
          pname,                                # package name
          version,                              # package version
          src,                                  # source of the package
          main,                                 # (relative) path to the entrypoint
          tests ? [],                           # (relative) paths to the tests
          effekt ? null,                        # the explicit Effekt derivation to use: uses latest release if not set
          effektVersion ? latestVersion,        # the Effekt version to use
          effektBackends ? [effektBackends.js], # Effekt backends to use -- first backend is the "default" one
          buildInputs ? [],                     # other build inputs required for the package
        }:
          assert effektBackends != []; # Ensure at least one backend is specified
          let
            defaultBackend = builtins.head effektBackends;
            effektBuild = if effekt != null then effekt else buildEffektRelease {
              version = effektVersion;
              sha256 = effektVersions.${effektVersion};
              backends = effektBackends;
            };
          in
          pkgs.stdenv.mkDerivation {
            inherit pname version src;

            nativeBuildInputs = [effektBuild];
            inherit buildInputs;

            buildPhase = ''
              mkdir -p out
              ${pkgs.lib.concatMapStrings (backend: ''
                effekt --build --backend ${backend.name} ${main}
                mv out/$(basename ${main}) out/${pname}-${backend.name}
              '') effektBackends}
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp -r out/* $out/bin/
              ln -s $out/bin/${pname}-${defaultBackend.name} $out/bin/${pname}
            '';

            checkPhase = pkgs.lib.concatMapStrings (test:
              pkgs.lib.concatMapStrings (backend: ''
                echo "Running test ${test} with backend ${backend.name}"
                effekt --backend ${backend.name} ${test}
              '') effektBackends
            ) tests;

            doCheck = tests != [];
          };

        # Creates a dev-shell for an Effekt package / version & backends
        mkDevShell = { effekt ? null, effektVersion ? latestVersion, backends ? [effektBackends.js] }:
          let
            effektBuild = if effekt != null then effekt else buildEffektRelease {
              version = effektVersion;
              sha256 = effektVersions.${effektVersion};
              inherit backends;
            };
          in
          pkgs.mkShell {
            buildInputs = [effektBuild] ++ pkgs.lib.concatMap (b: b.buildInputs) backends;
          };

        # Development shell for Effekt compiler development
        compilerDevShell = pkgs.mkShell {
          buildInputs = with pkgs; [
            sbt jre maven scala_3
          ] ++ pkgs.lib.concatMap (b: b.buildInputs) (builtins.attrValues effektBackends);
        };

        # Automatically generated packages for all 'effektVersions' with all backends
        autoPackages = pkgs.lib.mapAttrs (version: _:
          buildEffektRelease {
            inherit version;
            sha256 = effektVersions.${version};
            backends = builtins.attrValues effektBackends;
          }
        ) effektVersions;

        # Builds the nightly version of Effekt using the flake input
        nightlyEffekt = buildEffektFromSource {
          src = effekt-nightly;
          backends = builtins.attrValues effektBackends;
        };

      in {
        # Helper functions and types for external use
        lib = {
          inherit buildEffektRelease buildEffektFromSource buildEffektPackage mkDevShell effektBackends isMLtonSupported;
        };

        # Automatically generated packages + latest version (as default) + nightly version
        packages = autoPackages // {
          default = autoPackages.${latestVersion};
          nightly = nightlyEffekt;
        };

        # Development shells
        devShells = {
          default = mkDevShell {
            effektVersion = latestVersion;
            backends = builtins.attrValues effektBackends;
          };
          nightly = mkDevShell {
            effekt = nightlyEffekt;
            backends = builtins.attrValues effektBackends;
          };
          compilerDev = compilerDevShell;
        };

        # Ready-to-run applications
        apps = {
          default = flake-utils.lib.mkApp {
            drv = autoPackages.${latestVersion};
            name = "effekt";
          };
        };

        checks = {};
      }
    );
}
