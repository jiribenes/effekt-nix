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
    # The main repo of the Effekt language itself, *without* its submodules
    effekt-src-repo = {
      url = "github:effekt-lang/effekt";
      flake = false;
    };
    # The Kiama repo as a separate input
    kiama-src-repo = {
      url = "github:effekt-lang/kiama";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, sbt-derivation, effekt-src-repo, kiama-src-repo }:
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
        } // pkgs.lib.optionalAttrs isMLtonSupported {
          ml = {
            name = "ml";
            buildInputs = [pkgs.mlton];
          };
        };

        # Meta information about the Effekt programming language
        effektMeta = {
          mainProgram = "effekt";
          description = "A research language with effect handlers and lightweight effect polymorphism";
          homepage = "https://effekt-lang.org/";
          license = pkgs.lib.licenses.mit;
        };

        # Creates an Effekt derivation from a prebuilt GitHub release
        buildEffektRelease = {
          version,
          sha256,
          backends ? [effektBackends.js]
        }:
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

            meta = effektMeta;
          };

        # Creates an Effekt derivation by building Effekt from (some) source
        buildEffektFromSource = {
          src,
          version,
          depsSha256, # SHA256 of the Scala dependencies
          backends ? [effektBackends.js],
        }:
          assert backends != []; # Ensure at least one backend is specified
          sbt-derivation.lib.mkSbtDerivation {
            inherit pkgs;
            pname = "effekt";
            inherit version;
            inherit src;

            nativeBuildInputs = [pkgs.nodejs pkgs.maven pkgs.makeWrapper pkgs.gnused];
            buildInputs = [pkgs.jre] ++ pkgs.lib.concatMap (b: b.buildInputs) backends;

            inherit depsSha256;
            depsArchivalStrategy = "copy";
            depsWarmupCommand = ''
              sbt assembleBinary
              sbt scalaCompilerBridgeBinaryJar
            '';

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

            meta = effektMeta;
          };

        # Builds an Effekt package
        buildEffektPackage = pkgs.lib.makeOverridable (
          {
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

            # Entry point is the program called ${pname}
            meta.mainProgram = pname;
          }
        );

        # Creates a dev-shell for an Effekt package / version & backends
        mkDevShell = {
          effekt ? null,
          effektVersion ? latestVersion,
          backends ? [effektBackends.js]
        }:
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
        autoPackages = pkgs.lib.mapAttrs' (version: _:
          pkgs.lib.nameValuePair "effekt_${builtins.replaceStrings ["."] ["_"] version}" (
            buildEffektRelease {
              inherit version;
              sha256 = effektVersions.${version};
              backends = builtins.attrValues effektBackends;
            }
          )
        ) effektVersions;

        # Automatically generated devshells for all 'effektVersions' with all backends
        autoDevShells = pkgs.lib.mapAttrs' (version: _:
          pkgs.lib.nameValuePair "effekt_${builtins.replaceStrings ["."] ["_"] version}" (
            mkDevShell {
              effektVersion = version;
              backends = builtins.attrValues effektBackends;
            }
          )
        ) effektVersions;

        # Quick alias for the latest pre-built Effekt derivation
        latestEffekt = autoPackages."effekt_${builtins.replaceStrings ["."] ["_"] latestVersion}";

        # Builds the nightly version of Effekt using the flake input
        nightlyEffekt = buildEffektFromSource {
          # src = effekt-src-repo;
          src = pkgs.runCommand "effekt-with-kiama" {} ''
            cp -r ${effekt-src-repo} $out
            chmod -R +w $out
            rm -rf $out/kiama
            cp -r ${kiama-src-repo} $out/kiama
          '';

          depsSha256 = "sha256-aXjkdjcJDaYSOPxWhRd71uhqAXJZsgGeaXwOuw5d3Pg=";

          backends = builtins.attrValues effektBackends;
          version = "0.99.99+nightly-${builtins.substring 0 8 effekt-src-repo.rev}";
        };
      in {
        # Helper functions and types for external use
        lib = {
          inherit buildEffektRelease buildEffektFromSource buildEffektPackage mkDevShell effektBackends isMLtonSupported;
        };

        # Automatically generated packages + latest version (as default)
        packages = autoPackages // {
          default = latestEffekt;
          effekt_nightly = nightlyEffekt;
        };

        # Development shells
        devShells = autoDevShells // {
          default = mkDevShell {
            effektVersion = latestVersion;
            backends = builtins.attrValues effektBackends;
          };
          effekt_nightly = mkDevShell {
            effekt = nightlyEffekt;
            backends = builtins.attrValues effektBackends;
          };
          compilerDev = compilerDevShell;
        };

        # Ready-to-run applications
        apps = {
          default = flake-utils.lib.mkApp {
            drv = latestEffekt;
            name = "effekt";
          };
        } // builtins.mapAttrs (name: pkg:
          flake-utils.lib.mkApp {
            drv = pkg;
            name = "effekt";
          }
        ) autoPackages;

        checks = {};
      }
    );
}
