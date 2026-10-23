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

      versionSuffix = builtins.replaceStrings ["."] ["_"]; # '0.79.0' ~> '0_79_0'

      # Gets the name of the package for an Effekt version, e.g. 'effekt_0_79_0'
      versionAttrName = version: "effekt_${versionSuffix version}";

      # Creates the helper functions and types for the given nixpkgs 'pkgs'
      mkLib = pkgs:
        let
          # Where a backend's launcher and artifacts live, defining the layout
          launcherName = pname: backend: "${pname}-${backend.name}";
          backendDir = pname: backend: "$out/libexec/${pname}/${backend.name}";
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
              extension = ".js";
              minVersion = "0.3.0";           # Note: 0.2.2 works, but its launcher hardcodes an absolute build path
              buildInputs = [pkgs.nodejs];    # Needed for the compiler
              runtimeInputs = [pkgs.nodejs];  # Needed to run the programs
              compilerEnv = {};
              processOutput = backendUtils.standardBinary;
              producesExecutable = true;
            };
            js-web = {
              name = "js-web";
              extension = ".js";
              minVersion = "0.14.0";          # Note: until this version, '--build' exits with 1 after writing the page
              buildInputs = [pkgs.nodejs];    # For tests, we currently use the 'js' backend
              runtimeInputs = [];             # Web output doesn't need runtime deps
              compilerEnv = {};
              processOutput = backendUtils.webOutput;
              producesExecutable = false;     # Produces a '.js'/'.html' pair for the browser
            };
            llvm = {
              name = "llvm";
              extension = ".ll";
              minVersion = "0.2.2";
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
              extension = ".ss";
              minVersion = "0.2.2";
              buildInputs = [pkgs.chez];
              runtimeInputs = [pkgs.chez];
              compilerEnv = {};
              processOutput = backendUtils.standardBinary;
              producesExecutable = true;
            };
            chez-monadic = {
              name = "chez-monadic";
              extension = ".ss";
              minVersion = "0.2.2";
              buildInputs = [pkgs.chez];
              runtimeInputs = [pkgs.chez];
              compilerEnv = {};
              processOutput = backendUtils.standardBinary;
              producesExecutable = true;
            };
            chez-cps = {
              name = "chez-cps";
              extension = ".ss";
              minVersion = "0.54.0";
              buildInputs = [pkgs.chez];
              runtimeInputs = [pkgs.chez];
              compilerEnv = {};
              processOutput = backendUtils.standardBinary;
              producesExecutable = true;
            };
          };

          # The backends an Effekt version actually supports
          backendsFor = version: pkgs.lib.mapAttrs (name: backend:
            if pkgs.lib.versionAtLeast version backend.minVersion
            then backend
            else throw "The '${name}' backend needs Effekt ${backend.minVersion} or newer (selected: ${version})"
          ) effektBackends;

          # All backends that exist in an Effekt version, as a list (for 'all backends' packages)
          availableBackends = version:
            builtins.attrValues (pkgs.lib.filterAttrs (_: b: pkgs.lib.versionAtLeast version b.minVersion) effektBackends);

          # Selects backends for an Effekt version using the given function, e.g. 'bs: [bs.js bs.llvm]'
          selectBackends = version: backends:
            let
              available = backendsFor version;
              selected =
                if builtins.isFunction backends
                then backends available
                else throw "Backends must be selected by a function, e.g. 'bs: [bs.js]' (available backends: ${pkgs.lib.concatStringsSep ", " (builtins.attrNames effektBackends)})";
            in
              assert pkgs.lib.assertMsg (builtins.isList selected && builtins.all builtins.isAttrs selected) "'backends' must select a list of backends, e.g. 'bs: [bs.js]'";
              assert pkgs.lib.assertMsg (selected != []) "At least one backend must be specified";
              map (b: available.${b.name}) selected;

          # Selects a single backend for an Effekt version using the given function, e.g. 'bs: bs.llvm'
          selectBackend = version: backend:
            let
              available = backendsFor version;
              selected =
                if builtins.isFunction backend
                then backend available
                else throw "A backend must be selected by a function, e.g. 'bs: bs.js' (available backends: ${pkgs.lib.concatStringsSep ", " (builtins.attrNames effektBackends)})";
            in
              assert pkgs.lib.assertMsg (builtins.isAttrs selected) "'backend' must select a single backend, e.g. 'bs: bs.js'";
              available.${selected.name};

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
              selectedBackends = selectBackends version backends;
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
              selectedBackends = selectBackends version backends;
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

              # Change the requested version in the compiler.
              prePatch = ''
                versionFile=project/EffektVersion.scala
                grep -q 'lazy val effektVersion = "[^"]*"' "$versionFile" \
                  || { echo "effekt-nix: cannot stamp the version: no 'effektVersion' assignment in $versionFile" >&2; exit 1; }
                sed -i 's/lazy val effektVersion = "[^"]*"/lazy val effektVersion = "${version}"/' "$versionFile"
              '';

              # Effekt has Scala identifiers outside ASCII (e.g., 'sealed trait ω' in util/Control.scala).
              LANG = "C.UTF-8";
              LC_ALL = "C.UTF-8";

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

          # Resolves the compiler and its backends from the arguments that packages and dev-shells share
          # Note: the defaults here have to be in sync with its call sites!
          resolveEffekt = { effekt ? null, effektVersion ? latestVersion, backends ? (bs: [bs.js]), jvmArgs ? ["-Xss32m"], ... }:
            let # TODO(jiribenes): should this be a `rec` instead?
              effektBuild = if effekt != null then effekt else getEffekt {
                version = effektVersion;
                inherit backends jvmArgs;
              };
            in {
              inherit effektBuild;
              # The compiler knows its own version, so gating also works for a custom build
              selectedBackends = selectBackends (effektBuild.version or effektVersion) backends;
            };

          ## Primitives for projects that need more control than 'buildEffektPackage' offers.

          # Compiles a single entry point with a single backend, '$out' being exactly what the compiler emitted.
          # 'mode = "compile"' stops at the backend representation (e.g. 'main.ll'), "build" adds a launcher.
          compile = {
            effekt ? null,              # the explicit Effekt derivation to use: uses latest release if not set
            effektVersion ? latestVersion,
            jvmArgs ? ["-Xss32m"],      # JVM arguments for the compiler
            src,                        # the project's source tree
            main,                       # (relative) path to the entry point
            backend,                    # selects a single backend, e.g. 'bs: bs.llvm'
            mode ? "build",
            effektFlags ? [],
            includes ? [],              # extra import roots, relative to 'src'
            effektLibraries ? [],       # other Effekt libraries; their paths become import roots
            moduleName ? null,          # the entry point's 'module' name, if it differs from its file name
            pname ? null,
            version ? "0.0.0",
          }@args:
            let
              inherit (resolveEffekt args) effektBuild;
              selectedBackend = selectBackend (effektBuild.version or effektVersion) backend;

              includeArgs = pkgs.lib.concatMap (i: ["--includes" (toString i)]) (includes ++ effektLibraries);

              # Effekt names its output after the module path:
              # so it's the 'module' declaration, else the file name up to the first '.'
              modulePath = if moduleName != null then moduleName else builtins.head (pkgs.lib.splitString "." (baseNameOf main));
              artifactName = builtins.replaceStrings ["-"] ["_"] (pkgs.lib.last (pkgs.lib.splitString "/" modulePath));
            in
            pkgs.stdenv.mkDerivation {
              pname = if pname != null then pname else "${artifactName}-${selectedBackend.name}";
              inherit version src;

              nativeBuildInputs = [effektBuild] ++ selectedBackend.buildInputs;
              # 'patchShebangs' looks up the launcher's interpreter ('#!/usr/bin/env node') in 'buildInputs' only
              buildInputs = selectedBackend.runtimeInputs;

              buildPhase = ''
                runHook preBuild
                effekt --${mode} --backend ${selectedBackend.name} \
                  ${pkgs.lib.escapeShellArgs (includeArgs ++ effektFlags)} \
                  --out $out ${main}
                [ -f $out/${artifactName}${selectedBackend.extension} ] \
                  || { echo "effekt-nix: expected '${artifactName}${selectedBackend.extension}' from '${main}'; if it declares another 'module', pass 'moduleName'" >&2; exit 1; }
                runHook postBuild
              '';

              # The compiler creates and fills '$out' itself, so there is nothing left to install
              dontInstall = true;

              passthru = { backend = selectedBackend; inherit mode artifactName; };
            };

          # Turn compiled artifacts into a runnable program
          wrap = {
            pname,
            version ? "0.0.0",
            compiled,                   # a derivation produced by 'compile'
            makeWrapperArgs ? [],
          }:
            let inherit (compiled.passthru) backend artifactName; in
            assert pkgs.lib.assertMsg (compiled.passthru.mode == "build")
              "wrap needs a 'compile' with mode = \"build\" (got \"${compiled.passthru.mode}\")";
            assert pkgs.lib.assertMsg backend.producesExecutable
              "the '${backend.name}' backend produces no executable, so 'wrap' does not apply -- use 'mkSite'";
            pkgs.stdenv.mkDerivation {
              inherit pname version;

              dontUnpack = true;
              nativeBuildInputs = [pkgs.makeWrapper];

              installPhase = ''
                runHook preInstall

                # The launcher reads files next to itself ('require("./main.js")'), so the compiler's output stays together
                mkdir -p $out/libexec $out/bin
                cp -r ${compiled} $out/libexec/${pname}

                makeWrapper $out/libexec/${pname}/${artifactName} $out/bin/${pname} \
                  --prefix PATH : ${pkgs.lib.makeBinPath backend.runtimeInputs} \
                  ${pkgs.lib.escapeShellArgs makeWrapperArgs}

                runHook postInstall
              '';

              meta.mainProgram = pname;
            };

          # A website backend's output as a publishable site root, of real files: 'serve' answers a symlink with 404
          mkSite = {
            pname,
            version ? "0.0.0",
            compiled,                   # a derivation produced by 'compile' with a website backend
            extraFiles ? [],            # project files copied into the site root; later entries win
          }:
            let inherit (compiled.passthru) backend artifactName; in
            assert pkgs.lib.assertMsg (compiled.passthru.mode == "build")
              "mkSite needs a 'compile' with mode = \"build\" (got \"${compiled.passthru.mode}\")";
            assert pkgs.lib.assertMsg (!backend.producesExecutable)
              "mkSite expects a website backend (e.g. 'js-web') but '${backend.name}' produces an executable ~> use 'wrap'";
            pkgs.stdenv.mkDerivation {
              inherit pname version;

              dontUnpack = true;
              dontFixup = true;

              installPhase = ''
                runHook preInstall

                mkdir -p $out
                cp -r --no-preserve=mode ${compiled}/. $out/

                mv $out/${artifactName}.html $out/index.html

                # Add extra files / directories
                ${pkgs.lib.concatMapStrings (f: ''
                  if [ -d ${f} ]; then
                    cp -r --no-preserve=mode ${f}/. $out/
                  else
                    cp --no-preserve=mode ${f} $out/
                  fi
                '') (map (f: pkgs.lib.escapeShellArg "${f}") extraFiles)}

                runHook postInstall
              '';
            };

          # Serves a built site
          serveSite = {
            site,                       # a derivation produced by 'mkSite'
            name ? "serve",
            listen ? "8080",            # a port, 'tcp://host:port', or 'unix:/path/to.sock'
          }:
            pkgs.writeShellApplication {
              inherit name;
              runtimeInputs = [pkgs.serve];
              text = ''
                exec serve --no-clipboard --listen "${listen}" ${site}
              '';
            };

          # Builds an Effekt package, can be overriden as `package.override { ... }`
          buildEffektPackage = pkgs.lib.makeOverridable (
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
            }@args:
              let
                inherit (resolveEffekt args) selectedBackends effektBuild;
                defaultBackend = builtins.head selectedBackends;
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
                    effekt --build --backend ${backend.name} ${pkgs.lib.escapeShellArgs effektFlags} --out build/${backend.name} ${src}/${main}
                  '') selectedBackends}

                  runHook postBuild
                '';

                installPhase = ''
                  runHook preInstall

                  mkdir -p $out/bin

                  # Each backend installs its own artifacts, from inside its build directory
                  ${pkgs.lib.concatMapStrings (backend: ''
                    ( cd build/${backend.name}
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
                        effekt --build --backend ${backendForCheck.name} ${pkgs.lib.escapeShellArgs effektFlags} --out $TMPDIR/testout/${backendForCheck.name} ${src}/${test}

                        patchShebangs $TMPDIR/testout/${backendForCheck.name}

                        echo "Running the test:"
                        ( export PATH=${pkgs.lib.makeBinPath backendForCheck.runtimeInputs}''${PATH:+:}$PATH
                          $TMPDIR/testout/${backendForCheck.name}/$(basename ${test} .effekt) )

                        rm -rf $TMPDIR/testout/${backendForCheck.name}
                      ''
                    ) selectedBackends
                  ) tests}

                  runHook postCheck
                '';

                # Anything the caller passes in 'meta' wins over our 'mainProgram'
                meta = pkgs.lib.optionalAttrs defaultBackend.producesExecutable {
                  mainProgram = pname;
                } // meta;
              });

          # Creates a dev-shell for an Effekt package / version & backends
          mkDevShell = {
            effekt ? null,
            effektVersion ? latestVersion,
            backends ? (bs: [bs.js]),
            jvmArgs ? ["-Xss32m"]
          }@args:
            let
              inherit (resolveEffekt args) selectedBackends effektBuild;
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
          inherit buildEffektRelease buildEffektFromSource buildEffektPackage getEffekt mkDevShell effektBackends availableBackends compile wrap mkSite serveSite;
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
                backends = _: effektLib.availableBackends version;
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
                backends = _: effektLib.availableBackends version;
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
          perBackend = pkgs.lib.mapAttrs (name: _: runCheck name (bs: [bs.${name}]) "Hello from effekt-nix!")
            (pkgs.lib.filterAttrs (_: b: b.producesExecutable) effektLib.effektBackends);

          # Checks for the primitives ('compile', 'wrap', 'mkSite', 'serveSite')
          compiledFor = backendName: effektLib.compile {
            src = ./tests/hello;
            main = "main.effekt";
            backend = bs: bs.${backendName};
          };

          ## 'compile' and 'wrap' produce a runnable program
          primitiveChecks.compile-wrap =
            let program = effektLib.wrap { pname = "check-wrap"; compiled = compiledFor "js"; };
            in pkgs.runCommand "check-compile-wrap" {} ''
              ${pkgs.lib.getExe program} | grep -q "Hello from effekt-nix!"
              touch $out
            '';

          ## The output is named after the module: '-' becomes '_' ('my-game.effekt' ~> 'my_game')
          primitiveChecks.wrap-module-name =
            let program = effektLib.wrap {
              pname = "check-wrap-module-name";
              compiled = effektLib.compile {
                src = pkgs.writeTextDir "my-game.effekt" ''def main() = println("Hello from effekt-nix!")'';
                main = "my-game.effekt";
                backend = bs: bs.js;
              };
            };
            in pkgs.runCommand "check-wrap-module-name" {} ''
              ${pkgs.lib.getExe program} | grep -q "Hello from effekt-nix!"
              touch $out
            '';

          ## A 'module' declaration wins over the file name, and needs 'moduleName' (or fails early)
          renamedSrc = pkgs.writeTextDir "my-main.effekt" ''
            module renamed

            def main() = println("Hello from effekt-nix!")
          '';
          primitiveChecks.compile-module-name =
            let compiled = effektLib.compile { src = renamedSrc; main = "my-main.effekt"; moduleName = "renamed"; backend = bs: bs.js; };
            in pkgs.runCommand "check-compile-module-name" {} ''
              test -f ${compiled}/renamed.js
              touch $out
            '';
          primitiveChecks.compile-module-name-mismatch =
            let failure = pkgs.testers.testBuildFailure (effektLib.compile { src = renamedSrc; main = "my-main.effekt"; backend = bs: bs.js; });
            in pkgs.runCommand "check-compile-module-name-mismatch" {} ''
              grep -q "pass 'moduleName'" ${failure}/testBuildFailure.log
              touch $out
            '';

          ## 'compile' and 'mkSite' produce a site root of real files (see 'mkSite')
          primitiveChecks.mkSite =
            let site = effektLib.mkSite { pname = "check-site"; compiled = compiledFor "js-web"; }; in
            pkgs.runCommand "check-mkSite" {} ''
              test -f ${site}/index.html || { echo "no index.html at the site root"; exit 1; }
              test -L ${site}/index.html && { echo "index.html is a symlink; sites must be real files"; exit 1; }
              grep -q 'src="main.js"' ${site}/index.html
              test -f ${site}/main.js
              touch $out
            '';

          ## The page is named after the module too (see 'compile-module-name')
          primitiveChecks.mkSite-module-name =
            let site = effektLib.mkSite {
              pname = "check-site-module-name";
              compiled = effektLib.compile { src = renamedSrc; main = "my-main.effekt"; moduleName = "renamed"; backend = bs: bs.js-web; };
            };
            in pkgs.runCommand "check-mkSite-module-name" {} ''
              grep -q 'src="renamed.js"' ${site}/index.html
              test -f ${site}/renamed.js
              touch $out
            '';

          ## Serves the page and its assets for real
          # A socket in the build's own $TMPDIR, not a fixed port, so parallel builds cannot collide.
          primitiveChecks.serveSite =
            let
              site = effektLib.mkSite {
                pname = "check-served";
                compiled = compiledFor "js-web";
                extraFiles = [./tests/hello];        # an asset that must ship alongside the page
              };
              server = effektLib.serveSite {
                inherit site;
                name = "check-serve";
                listen = "unix:$SOCKET";
              };
            in pkgs.runCommand "check-serveSite" { nativeBuildInputs = [pkgs.curl]; } ''
              export SOCKET="$(mktemp -u -t effekt-site.XXXXXX.sock)"
              ${pkgs.lib.getExe server} &
              trap 'kill %1 2>/dev/null || true' EXIT

              # wait for the socket to appear rather than sleeping a fixed amount
              for _ in $(seq 1 100); do
                [ -S "$SOCKET" ] && break
                sleep 0.1
              done
              [ -S "$SOCKET" ] || { echo "server never created $SOCKET"; exit 1; }

              get() { curl -fsS --unix-socket "$SOCKET" -o /dev/null "http://localhost$1"; }
              get /             || { echo "site root not served"; exit 1; }
              get /main.js      || { echo "script not served"; exit 1; }
              get /main.effekt  || { echo "extraFiles not served"; exit 1; }
              touch $out
            '';

          checkedVersions = ["0.2.2" "0.3.0" "0.12.0" "0.22.0" "0.32.0" "0.41.0" "0.51.0" "0.54.0" "0.61.0" "0.71.0" latestVersion];

          # Builds and runs the fixture with one backend on one Effekt version
          runVersionCheck = version: backendName:
            let
              checkName = "check-${backendName}-${versionSuffix version}";
              package = effektLib.buildEffektPackage {
                pname = checkName;
                version = "0.0.0";
                src = ./tests/hello;
                main = "main.effekt";
                effektVersion = version;
                backends = bs: [bs.${backendName}];
              };
            in pkgs.runCommand checkName {} ''
              ${pkgs.lib.getExe package} | grep -q "Hello from effekt-nix!"
              touch $out
            '';

          # 'js' across the whole range, 'llvm' on a few -- but only where the backend exists (see 'minVersion')
          backendsToCheck = version:
            pkgs.lib.filter (name: pkgs.lib.versionAtLeast version effektLib.effektBackends.${name}.minVersion)
              (["js"] ++ pkgs.lib.optionals (builtins.elem version ["0.2.2" "0.32.0" latestVersion]) ["llvm"]);

          versionChecks = builtins.listToAttrs (pkgs.lib.concatMap (version:
            map (backendName:
              pkgs.lib.nameValuePair "${backendName}-${versionSuffix version}" (runVersionCheck version backendName)
            ) (backendsToCheck version)
          ) checkedVersions);
        in
        perBackend // versionChecks // primitiveChecks // {
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

          # 'minVersion' holds even for a selector that ignores 'bs' and returns a backend directly
          selector-ignoring-bs =
            let
              rejected = drv: !(builtins.tryEval drv.drvPath).success;
              viaGetEffekt = b: effektLib.getEffekt { version = "0.30.0"; backends = _: [b]; };
              viaCompile = b: effektLib.compile { effektVersion = "0.30.0"; src = ./tests/hello; main = "main.effekt"; backend = _: b; };
            in
            assert pkgs.lib.assertMsg (!rejected (viaGetEffekt effektLib.effektBackends.js) && !rejected (viaCompile effektLib.effektBackends.js))
              "'js' on 0.30.0 must evaluate, or the rejections below prove nothing";
            assert pkgs.lib.assertMsg (rejected (viaGetEffekt effektLib.effektBackends.chez-cps))
              "'selectBackends' let a selector that ignores 'bs' bypass 'minVersion'";
            assert pkgs.lib.assertMsg (rejected (viaCompile effektLib.effektBackends.chez-cps))
              "'selectBackend' let a selector that ignores 'bs' bypass 'minVersion'";
            pkgs.runCommand "check-selector-ignoring-bs" {} "touch $out";
        }
      );
    };
}
