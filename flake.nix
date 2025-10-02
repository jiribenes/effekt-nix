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
  };

  outputs = { self, nixpkgs, flake-utils, sbt-derivation }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Load Effekt versions and their corresponding SHA256 hashes from 'releases.json'
        # If you want to add a new release version, just add it there.
        effektVersions = builtins.fromJSON (builtins.readFile ./releases.json);

        # Gets the newest version from 'effektVersions'
        latestVersion = builtins.head (builtins.sort (a: b: builtins.compareVersions a b > 0) (builtins.attrNames effektVersions));

        # Backend-specific processing functions
        backendUtils = {
          # Standard binary output processing
          standardBinary = pname: backend: mainFile: ''
            mv out/$(basename ${mainFile} .effekt) out/${pname}-${backend.outputName}
          '';

          # Web output processing
          webOutput = pname: backend: mainFile: ''
            mv "out/$(basename ${mainFile} .effekt).js" out/${pname}.js
            mv "out/$(basename ${mainFile} .effekt).html" out/${pname}.html
            sed -i 's/src="main.js"/src="${pname}.js"/' out/${pname}.html
          '';
        };

        # Available backends for Effekt
        effektBackends = {
          js = {
            name = "js";
            outputName = "js";
            buildInputs = [pkgs.nodejs];    # Needed for the compiler
            runtimeInputs = [pkgs.nodejs];  # Needed to run the programs
            processOutput = backendUtils.standardBinary;
            runtime = "node";
          };
          js-web = {
            name = "js-web";
            outputName = "js-web";
            buildInputs = [pkgs.nodejs];    # For tests, we currently use the 'js' backend
            runtimeInputs = [];             # Web output doesn't need runtime deps
            processOutput = backendUtils.webOutput;
            runtime = null;
          };
          js-bun = {
            name = "js";
            outputName = "js-bun";
            buildInputs = [pkgs.nodejs];    # Still need nodejs for compilation
            runtimeInputs = [pkgs.bun];     # But use bun for running
            processOutput = backendUtils.standardBinary;
            runtime = "bun";
          };
          llvm = {
            name = "llvm";
            outputName = "llvm";
            buildInputs = [pkgs.llvm pkgs.clang pkgs.libuv];  # Needed for compilation
            runtimeInputs = [pkgs.libuv pkgs.clang];          # Only libuv needed at runtime
            processOutput = backendUtils.standardBinary;
            runtime = null;
          };
          chez-callcc = {
            name = "chez-callcc";
            outputName = "chez-callcc";
            buildInputs = [pkgs.chez];
            runtimeInputs = [pkgs.chez];
            processOutput = backendUtils.standardBinary;
            runtime = "scheme";
          };
          chez-monadic = {
            name = "chez-monadic";
            outputName = "chez-monadic";
            buildInputs = [pkgs.chez];
            runtimeInputs = [pkgs.chez];
            processOutput = backendUtils.standardBinary;
            runtime = "scheme";
          };
        };

        # Meta information about the Effekt programming language
        effektMeta = {
          mainProgram = "effekt";
          description = "A language with lexical effect handlers and lightweight effect polymorphism";
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
              echo "Warming up: getting compiler bridge thingy"
              sbt scalaCompilerBridgeBinaryJar
              echo "Warming up: updating"
              sbt update
              echo "Warming up: FINISHED"
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
        buildEffektPackage =
          {
            pname,                                # package name
            version,                              # package version
            src,                                  # source of the package
            main,                                 # (relative) path to the entrypoint
            tests ? [],                           # (relative) paths to the tests
            effekt ? null,                        # the explicit Effekt derivation to use: uses latest release if not set
            effektVersion ? latestVersion,        # the Effekt version to use
            backends ? [effektBackends.js],       # Effekt backends to use -- first backend is the "default" one
            buildInputs ? [],                     # other build inputs required for the package
          }:
            assert backends != []; # Ensure at least one backend is specified
            let
              defaultBackend = builtins.head backends;
              effektBuild = if effekt != null then effekt else buildEffektRelease {
                version = effektVersion;
                sha256 = effektVersions.${effektVersion};
                inherit backends;
              };
            in
            pkgs.stdenv.mkDerivation {
              inherit pname version src;

              # Build-time only dependencies
              nativeBuildInputs = [
                effektBuild
                pkgs.gnused
                pkgs.makeWrapper
              ] ++ pkgs.lib.concatMap (b: b.buildInputs) backends;

              # Runtime dependencies for the build environment (needed for tests)
              buildInputs = buildInputs
                ++ pkgs.lib.concatMap (b: b.runtimeInputs) backends;

              buildPhase = ''
                mkdir -p out

                ${pkgs.lib.concatMapStrings (backend: ''
                  echo "Building with backend ${backend.name} file ${src}/${main}"
                  effekt --build --backend ${backend.name} ${src}/${main}

                  ${backend.processOutput pname backend "${src}/${main}"}

                  ${if backend.runtime != null then ''
                    echo "Setting runtime to ${backend.runtime}"
                    sed -i '1c#!/usr/bin/env ${backend.runtime}' out/${pname}-${backend.outputName}
                  '' else ""}
                '') backends}
              '';

              installPhase = ''
                mkdir -p $out/bin
                cp -r out/* $out/bin/

                # Wrap each backend's output with its runtime dependencies
                ${pkgs.lib.concatMapStrings (backend:
                  if backend.runtime != null || (backend.runtimeInputs != []) then ''
                    echo "Wrapping ${pname}-${backend.outputName} with runtime dependencies"
                    mv $out/bin/${pname}-${backend.outputName} $out/bin/${pname}-${backend.outputName}.unwrapped
                    makeWrapper $out/bin/${pname}-${backend.outputName}.unwrapped $out/bin/${pname}-${backend.outputName} \
                      --prefix PATH : ${pkgs.lib.makeBinPath backend.runtimeInputs}
                  '' else ""
                ) backends}

                # Create default symlink if not web backend
                ${if defaultBackend.runtime != null then ''
                  ln -s $out/bin/${pname}-${defaultBackend.outputName} $out/bin/${pname}
                '' else ""}
              '';

              # Note: fixupPhase with patchShebangs should run after our wrapping

              doCheck = tests != [];
              checkPhase = pkgs.lib.concatMapStrings (test:
                pkgs.lib.concatMapStrings (backend:
                  let
                    backendForCheck = if backend == effektBackends.js-web then effektBackends.js else backend;
                  in ''
                    mkdir -p $TMPDIR/testout

                    echo "Building test ${test} with backend ${backendForCheck.name}"
                    effekt --build --backend ${backendForCheck.name} --out $TMPDIR/testout ${src}/${test}

                    echo "Patching and wrapping the test"
                    ${if backendForCheck.runtime != null then ''
                      sed -i '1c#!/usr/bin/env ${backendForCheck.runtime}' $TMPDIR/testout/$(basename ${test} .effekt)
                    '' else ""}

                    mv $TMPDIR/testout/$(basename ${test} .effekt) $TMPDIR/testout/$(basename ${test} .effekt).unwrapped
                    makeWrapper $TMPDIR/testout/$(basename ${test} .effekt).unwrapped $TMPDIR/testout/$(basename ${test} .effekt) \
                      --prefix PATH : ${pkgs.lib.makeBinPath backendForCheck.runtimeInputs}

                    echo "Running the test:"
                    $TMPDIR/testout/$(basename ${test} .effekt)

                    rm -rf $TMPDIR/testout
                  ''
                ) backends
              ) tests;

              # Entry point is the program called ${pname}
              meta.mainProgram = pname;
            };

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
            buildInputs = [effektBuild]
              ++ pkgs.lib.concatMap (b: b.buildInputs) backends
              ++ pkgs.lib.concatMap (b: b.runtimeInputs) backends;
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

        # Helpful function to get an Effekt package given version and backends
        getEffekt =
          {
            version ? null,                 # Version as a string (leave null for the latest version)
            backends ? [effektBackends.js]  # Supported backends
          }:
            assert backends != []; # Ensure at least one backend is specified
            let
              selectedVersion = if version == null then latestVersion else version;
              sha256 = effektVersions.${selectedVersion} or null;
            in
              if sha256 == null
              then throw "Unsupported Effekt version: ${selectedVersion}"
              else buildEffektRelease {
                inherit backends;
                version = selectedVersion;
                inherit sha256;
              };

      in {
        # Helper functions and types for external use
        lib = {
          inherit buildEffektRelease buildEffektFromSource buildEffektPackage getEffekt mkDevShell effektBackends;
        };

        # Automatically generated packages + latest version (as default)
        packages = autoPackages // {
          default = latestEffekt;
        };

        # Development shells
        devShells = autoDevShells // {
          default = mkDevShell {
            effektVersion = latestVersion;
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

        checks = { };
      }
    );
}
