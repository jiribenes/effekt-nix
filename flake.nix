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
          # Where a backend's launcher and artifacts live, defining the layout
          launcherName = pname: backend: "${pname}-${backend.outputName}";
          backendDir = pname: backend: "$out/libexec/${pname}/${backend.outputName}";
          launcherPath = pname: backend: "${backendDir pname backend}/${launcherName pname backend}";

          # Wraps a backend's launcher into '$out/bin/<pname>-<backend>' with its runtime dependencies
          wrapLauncher = pname: backend: ''
            makeWrapper ${launcherPath pname backend} $out/bin/${launcherName pname backend} \
              --prefix PATH : ${pkgs.lib.makeBinPath backend.runtimeInputs}
          '';

          # Installs a backend's artifacts; runs inside that backend's build directory
          backendUtils = {
            # Effekt produces launchers that read files next to themselves ('require("./x.js")', '$SCRIPT_DIR/x.ss')
            standardBinary = pname: backend: mainFile: ''
              mkdir -p $out/libexec/${pname}
              cp -r . ${backendDir pname backend}
              mv ${backendDir pname backend}/$(basename ${mainFile} .effekt) ${launcherPath pname backend}
              ${wrapLauncher pname backend}
            '';

            # Self-contained native binaries: the executable is the only artifact we keep
            nativeBinary = pname: backend: mainFile: ''
              mkdir -p ${backendDir pname backend}
              cp $(basename ${mainFile} .effekt) ${launcherPath pname backend}
              ${wrapLauncher pname backend}
            '';

            # Web output: the '.js'/'.html' pair is the output, so it goes to '$out/share'
            webOutput = pname: backend: mainFile: ''
              mkdir -p $out/share/${pname}
              cp "$(basename ${mainFile} .effekt).js" $out/share/${pname}/${pname}.js
              cp "$(basename ${mainFile} .effekt).html" $out/share/${pname}/${pname}.html
              sed -i "s|src=\"$(basename ${mainFile} .effekt).js\"|src=\"${pname}.js\"|" $out/share/${pname}/${pname}.html
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
              compilerEnv = {};
              processOutput = backendUtils.standardBinary;
              producesExecutable = true;
            };
            js-web = {
              name = "js-web";
              outputName = "js-web";
              buildInputs = [pkgs.nodejs];    # For tests, we currently use the 'js' backend
              runtimeInputs = [];             # Web output doesn't need runtime deps
              compilerEnv = {};
              processOutput = backendUtils.webOutput;
              producesExecutable = false;     # Produces a '.js'/'.html' pair for the browser
            };
            llvm = {
              name = "llvm";
              outputName = "llvm";
              buildInputs = [clangWithVersionAliases pkgs.llvm pkgs.libuv]; # Supporting older versions of Effekt that used `llc`/`opt`
              runtimeInputs = [pkgs.libuv];                                 # Only libuv needed at runtime
              compilerEnv = { # Explicitly add libuv to CPATH and LIBRARY_PATH env vars
                CPATH = pkgs.lib.makeIncludePath [pkgs.libuv];
                LIBRARY_PATH = pkgs.lib.makeLibraryPath [pkgs.libuv];
              };
              processOutput = backendUtils.nativeBinary;
              producesExecutable = true;
            };
            chez-callcc = {
              name = "chez-callcc";
              outputName = "chez-callcc";
              buildInputs = [pkgs.chez];
              runtimeInputs = [pkgs.chez];
              compilerEnv = {};
              processOutput = backendUtils.standardBinary;
              producesExecutable = true;
            };
            chez-monadic = {
              name = "chez-monadic";
              outputName = "chez-monadic";
              buildInputs = [pkgs.chez];
              runtimeInputs = [pkgs.chez];
              compilerEnv = {};
              processOutput = backendUtils.standardBinary;
              producesExecutable = true;
            };
            chez-cps = {
              name = "chez-cps";
              outputName = "chez-cps";
              buildInputs = [pkgs.chez];
              runtimeInputs = [pkgs.chez];
              compilerEnv = {};
              processOutput = backendUtils.standardBinary;
              producesExecutable = true;
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

          # 'makeWrapper' arguments for the environment the selected backends need (see 'compilerEnv')
          mkCompilerEnvArgs = selectedBackends:
            let
              # Backends declare a search path per variable, e.g. 'CPATH = "/nix/store/...-libuv-dev/include"'
              merged = pkgs.lib.zipAttrsWith (_: pkgs.lib.concatStringsSep ":") (map (b: b.compilerEnv) selectedBackends);
            in
              pkgs.lib.concatStrings (pkgs.lib.mapAttrsToList (name: path: " --prefix ${name} : \"${path}\"") merged);

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
                  --prefix PATH : ${pkgs.lib.makeBinPath (pkgs.lib.concatMap (b: b.buildInputs) selectedBackends)}${mkCompilerEnvArgs selectedBackends}
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
                  --prefix PATH : ${pkgs.lib.makeBinPath (pkgs.lib.concatMap (b: b.buildInputs) selectedBackends)}${mkCompilerEnvArgs selectedBackends}
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
              nativeBuildInputs ? [],               # build-time-only tools
              effektFlags ? [],                     # flags passed to the Effekt compiler, such as ["--no-optimize"]
              preBuild ? "",                        # runs before the Effekt build
              postBuild ? "",                       # runs after the Effekt build
              meta ? {},                            # package metadata
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

                # Hooks for projects that need to do something around the Effekt build
                inherit preBuild postBuild;

                # Build-time only dependencies
                nativeBuildInputs = nativeBuildInputs ++ [
                  effektBuild
                  pkgs.gnused
                  pkgs.makeWrapper
                ] ++ pkgs.lib.concatMap (b: b.buildInputs) selectedBackends;

                # Runtime dependencies for the build environment (needed for tests)
                buildInputs = buildInputs
                  ++ pkgs.lib.concatMap (b: b.runtimeInputs) selectedBackends;

                # Each backend builds into its own directory, or they overwrite each other's files (see 'UPSTREAM.md')
                buildPhase = ''
                  runHook preBuild

                  ${pkgs.lib.concatMapStrings (backend: ''
                    echo "Building with backend ${backend.name} file ${src}/${main}"
                    effekt --build --backend ${backend.name} ${pkgs.lib.escapeShellArgs effektFlags} --out build/${backend.outputName} ${src}/${main}
                  '') selectedBackends}

                  runHook postBuild
                '';

                installPhase = ''
                  runHook preInstall

                  mkdir -p $out/bin

                  # Each backend installs its own artifacts, from inside its build directory
                  ${pkgs.lib.concatMapStrings (backend: ''
                    ( cd build/${backend.outputName}
                      ${backend.processOutput pname backend "${src}/${main}"} )
                  '') selectedBackends}

                  # Entry point is the default (first) backend, if it produces an executable at all
                  ${pkgs.lib.optionalString defaultBackend.producesExecutable ''
                    ln -s $out/bin/${launcherName pname defaultBackend} $out/bin/${pname}
                  ''}

                  runHook postInstall
                '';

                doCheck = tests != [];
                checkPhase = ''
                  runHook preCheck

                  ${pkgs.lib.concatMapStrings (test:
                    pkgs.lib.concatMapStrings (backend:
                      let
                        # The web backend produces no executable, so its tests run on 'js'
                        backendForCheck = if backend == effektBackends.js-web then effektBackends.js else backend;
                      in ''
                        echo "Building test ${test} with backend ${backendForCheck.name}"
                        effekt --build --backend ${backendForCheck.name} ${pkgs.lib.escapeShellArgs effektFlags} --out $TMPDIR/testout/${backendForCheck.outputName} ${src}/${test}

                        echo "Running the test:"
                        ( export PATH=${pkgs.lib.makeBinPath backendForCheck.runtimeInputs}''${PATH:+:}$PATH
                          $TMPDIR/testout/${backendForCheck.outputName}/$(basename ${test} .effekt) )

                        rm -rf $TMPDIR/testout/${backendForCheck.outputName}
                      ''
                    ) selectedBackends
                  ) tests}

                  runHook postCheck
                '';

                # Anything the caller passes in 'meta' wins over our 'mainProgram'
                meta = pkgs.lib.optionalAttrs defaultBackend.producesExecutable {
                  mainProgram = pname;
                } // meta;
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

      # Builds *and runs* a hello world with each backend; the fixture is in `./tests/hello`
      checks = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
          effektLib = mkLib pkgs;

          # A package built from './tests/hello' with the given backends
          mkCheckPackage = name: backends: effektLib.buildEffektPackage {
            pname = "check-${name}";
            version = "0.0.0";
            src = ./tests/hello;
            main = "main.effekt";
            tests = ["test.effekt"];
            inherit backends;
          };

          # Runs every executable the package installed and checks what it prints
          runCheck = name: backends: expected:
            let package = mkCheckPackage name backends;
            in pkgs.runCommand "check-${name}" {} ''
              for exe in ${package}/bin/*; do
                echo "running $exe"
                "$exe" | grep -q "${expected}" || { echo "unexpected output from $exe"; exit 1; }
              done
              touch $out
            '';

          # One check per backend that produces an executable
          perBackend = pkgs.lib.mapAttrs (name: _: runCheck name (_: [effektLib.effektBackends.${name}]) "Hello from effekt-nix!")
            (pkgs.lib.filterAttrs (_: b: b.producesExecutable) effektLib.effektBackends);
        in
        perBackend // {
          # Two backends whose artifacts used to overwrite each other in a shared output directory.
          both-chez = runCheck "both-chez" (bs: [bs.chez-callcc bs.chez-monadic]) "Hello from effekt-nix!";

          # The web backend produces no executable, so its '.js'/'.html' pair is the deliverable
          js-web =
            let package = mkCheckPackage "js-web" (bs: [bs.js-web]);
            in pkgs.runCommand "check-js-web" {} ''
              test -f ${package}/share/check-js-web/check-js-web.js
              grep -q 'src="check-js-web.js"' ${package}/share/check-js-web/check-js-web.html
              touch $out
            '';

          # Some projects like 'community/effekt-rejit' generate files before the Effekt build itself.
          hooks =
            let package = effektLib.buildEffektPackage {
              pname = "check-hooks";
              version = "0.0.0";
              src = ./tests/hello;
              main = "main.effekt";
              backends = bs: [bs.js];
              preBuild = ''mkdir -p build/js && echo "preBuild ran" > build/js/hook-marker.txt'';
              postBuild = ''echo "postBuild ran" >> build/js/hook-marker.txt'';
            };
            in pkgs.runCommand "check-hooks" {} ''
              ${pkgs.lib.getExe package} | grep -q "Hello from effekt-nix!"
              grep -q "preBuild ran" ${package}/libexec/check-hooks/js/hook-marker.txt
              grep -q "postBuild ran" ${package}/libexec/check-hooks/js/hook-marker.txt
              touch $out
            '';
        }
      );
    };
}
