{
  description = "Nix interop for the Effekt programming language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    sbt-derivation = {
      url = "github:zaninime/sbt-derivation";
      flake = false; # We only use its builder function
    };
  };

  outputs = { self, nixpkgs, sbt-derivation }:
    let
      # Systems supported by effekt-nix (also used by the template via 'lib.supportedSystems')
      supportedSystems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });

      # Builder function for sbt projects
      mkSbtDerivation = import sbt-derivation;

      # Load Effekt versions and their corresponding SHA256 hashes from 'releases.json'
      # If you want to add a new release version, just add it there.
      effektVersions = builtins.fromJSON (builtins.readFile ./releases.json);

      # Gets the newest version from 'effektVersions'
      latestVersion = builtins.head (builtins.sort (a: b: builtins.compareVersions a b > 0) (builtins.attrNames effektVersions));

      # Gets the name of the package for an Effekt version, e.g. 'effekt_0_79_0'
      versionAttrName = version: "effekt_${builtins.replaceStrings ["."] ["_"] version}";

      # Creates the helper functions and types for the given nixpkgs 'pkgs'
      mkLib = pkgs:
        let
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

          # Effekt searches for `clang-XY` on PATH.
          clangWithVersionAliases = pkgs.symlinkJoin {
            name = "clang-wrapped-with-aliases";
            paths = [ pkgs.clang ];
            postBuild = ''
              for v in 18 19 20 21; do
                if [ ! -e $out/bin/clang-$v ]; then
                  ln -sf $out/bin/clang $out/bin/clang-$v
                fi
              done
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
              buildInputs = [clangWithVersionAliases pkgs.libuv];  # Needed for compilation
              runtimeInputs = [pkgs.libuv];          # Only libuv needed at runtime
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

          # Selects backends from 'effektBackends' using the given function, e.g. 'bs: [bs.js bs.llvm]'
          selectBackends = backends:
            let
              selected =
                if builtins.isFunction backends
                then backends effektBackends
                else throw "Backends must be selected by a function, e.g. 'bs: [bs.js]' (available backends: ${pkgs.lib.concatStringsSep ", " (builtins.attrNames effektBackends)})";
            in
              assert pkgs.lib.assertMsg (selected != []) "At least one backend must be specified";
              selected;

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
            backends ? (bs: [bs.js]),
            jvmArgs ? ["-Xss32m"]
          }:
            let
              selectedBackends = selectBackends backends;
            in
            pkgs.stdenv.mkDerivation {
              pname = "effekt";
              inherit version;

              src = pkgs.fetchurl {
                url = "https://github.com/effekt-lang/effekt/releases/download/v${version}/effekt.tgz";
                inherit sha256;
              };

              nativeBuildInputs = [pkgs.makeWrapper];
              buildInputs = [pkgs.jre] ++ pkgs.lib.concatMap (b: b.buildInputs) selectedBackends;

              installPhase = ''
                mkdir -p $out/bin $out/lib
                mv bin/effekt $out/lib/effekt.jar
                mv libraries $out/libraries

                makeWrapper ${pkgs.jre}/bin/java $out/bin/effekt \
                  --add-flags "${pkgs.lib.concatStringsSep " " jvmArgs} -jar $out/lib/effekt.jar" \
                  --prefix PATH : ${pkgs.lib.makeBinPath (pkgs.lib.concatMap (b: b.buildInputs) selectedBackends)}
              '';

              meta = effektMeta;
            };

          # Creates an Effekt derivation by building Effekt from (some) source
          buildEffektFromSource = {
            src,
            version,
            depsSha256, # SHA256 of the Scala dependencies
            backends ? (bs: [bs.js]),
            jvmArgs ? ["-Xss32m"]
          }:
            let
              selectedBackends = selectBackends backends;
            in
            mkSbtDerivation {
              inherit pkgs;
              pname = "effekt";
              inherit version;
              inherit src;

              nativeBuildInputs = [pkgs.nodejs pkgs.maven pkgs.makeWrapper pkgs.gnused];
              buildInputs = [pkgs.jre] ++ pkgs.lib.concatMap (b: b.buildInputs) selectedBackends;

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
                  --add-flags "${pkgs.lib.concatStringsSep " " jvmArgs} -jar $out/lib/effekt.jar" \
                  --prefix PATH : ${pkgs.lib.makeBinPath (pkgs.lib.concatMap (b: b.buildInputs) selectedBackends)}
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
              backends ? (bs: [bs.js]),             # Effekt backends to use -- first backend is the "default" one
              jvmArgs ? ["-Xss32m"],                # JVM arguments for the compiler
              buildInputs ? [],                     # other build inputs required for the package
              extraEffektFlags ? [],                # extra flags passed to the Effekt compiler
            }:
              let
                selectedBackends = selectBackends backends;
                defaultBackend = builtins.head selectedBackends;
                effektBuild = if effekt != null then effekt else buildEffektRelease {
                  version = effektVersion;
                  sha256 = effektVersions.${effektVersion};
                  inherit backends jvmArgs;
                };
              in
              pkgs.stdenv.mkDerivation {
                inherit pname version src;

                # Build-time only dependencies
                nativeBuildInputs = [
                  effektBuild
                  pkgs.gnused
                  pkgs.makeWrapper
                ] ++ pkgs.lib.concatMap (b: b.buildInputs) selectedBackends;

                # Runtime dependencies for the build environment (needed for tests)
                buildInputs = buildInputs
                  ++ pkgs.lib.concatMap (b: b.runtimeInputs) selectedBackends;

                buildPhase = ''
                  mkdir -p out

                  ${pkgs.lib.concatMapStrings (backend: ''
                    echo "Building with backend ${backend.name} file ${src}/${main}"
                    effekt --build --backend ${backend.name} ${pkgs.lib.concatStringsSep " " extraEffektFlags} ${src}/${main}

                    ${backend.processOutput pname backend "${src}/${main}"}

                    ${if backend.runtime != null then ''
                      echo "Setting runtime to ${backend.runtime}"
                      sed -i '1c#!/usr/bin/env ${backend.runtime}' out/${pname}-${backend.outputName}
                    '' else ""}
                  '') selectedBackends}
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
                  ) selectedBackends}

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
                      effekt --build --backend ${backendForCheck.name} ${pkgs.lib.concatStringsSep " " extraEffektFlags} --out $TMPDIR/testout ${src}/${test}

                      # Patch the shebang before wrapping
                      patchShebangs $TMPDIR/testout/$(basename ${test} .effekt)

                      mv $TMPDIR/testout/$(basename ${test} .effekt) $TMPDIR/testout/$(basename ${test} .effekt).unwrapped
                      makeWrapper $TMPDIR/testout/$(basename ${test} .effekt).unwrapped $TMPDIR/testout/$(basename ${test} .effekt) \
                        --prefix PATH : ${pkgs.lib.makeBinPath backendForCheck.runtimeInputs}

                      echo "Running the test:"
                      $TMPDIR/testout/$(basename ${test} .effekt)

                      rm -rf $TMPDIR/testout
                    ''
                  ) selectedBackends
                ) tests;

                # Entry point is the program called ${pname}
                meta.mainProgram = pname;
              };

          # Creates a dev-shell for an Effekt package / version & backends
          mkDevShell = {
            effekt ? null,
            effektVersion ? latestVersion,
            backends ? (bs: [bs.js]),
            jvmArgs ? ["-Xss32m"]
          }:
            let
              selectedBackends = selectBackends backends;
              effektBuild = if effekt != null then effekt else buildEffektRelease {
                version = effektVersion;
                sha256 = effektVersions.${effektVersion};
                inherit backends jvmArgs;
              };
            in
            pkgs.mkShell {
              buildInputs = [effektBuild]
                ++ pkgs.lib.concatMap (b: b.buildInputs) selectedBackends
                ++ pkgs.lib.concatMap (b: b.runtimeInputs) selectedBackends;
            };

          # Helpful function to get an Effekt package given version and backends
          getEffekt =
            {
              version ? null,                 # Version as a string (leave null for the latest version)
              backends ? (bs: [bs.js]),       # Supported backends
              jvmArgs ? ["-Xss32m"]           # JVM arguments for the compiler
            }:
              let
                selectedVersion = if version == null then latestVersion else version;
                sha256 = effektVersions.${selectedVersion} or null;
              in
                if sha256 == null
                then throw "Unsupported Effekt version: ${selectedVersion}"
                else buildEffektRelease {
                  inherit backends jvmArgs;
                  version = selectedVersion;
                  inherit sha256;
                };

        in {
          inherit buildEffektRelease buildEffektFromSource buildEffektPackage getEffekt mkDevShell effektBackends;
        };
    in {
      # Helper functions and types for external use (see 'mkLib')
      lib = {
        inherit mkLib supportedSystems;
      };

      # Automatically generated packages + latest version (as default)
      packages = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
          effektLib = mkLib pkgs;

          # Automatically generated packages for all 'effektVersions' with all backends
          autoPackages = pkgs.lib.mapAttrs' (version: _:
            pkgs.lib.nameValuePair (versionAttrName version) (
              effektLib.buildEffektRelease {
                inherit version;
                sha256 = effektVersions.${version};
                backends = bs: builtins.attrValues bs;
              }
            )
          ) effektVersions;
        in
        autoPackages // {
          default = autoPackages.${versionAttrName latestVersion};
        }
      );

      # Development shells
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
          effektLib = mkLib pkgs;

          # Automatically generated devshells for all 'effektVersions' with all backends
          autoDevShells = pkgs.lib.mapAttrs' (version: _:
            pkgs.lib.nameValuePair (versionAttrName version) (
              effektLib.mkDevShell {
                effektVersion = version;
                backends = bs: builtins.attrValues bs;
              }
            )
          ) effektVersions;
        in
        autoDevShells // {
          default = autoDevShells.${versionAttrName latestVersion};

          # Development shell for Effekt compiler development
          compilerDev = pkgs.mkShell {
            buildInputs = with pkgs; [
              sbt jre maven scala_3
            ] ++ pkgs.lib.concatMap (b: b.buildInputs) (builtins.attrValues effektLib.effektBackends);
          };
        }
      );

      checks = forAllSystems (system: { });
    };
}
