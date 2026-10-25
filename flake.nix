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
              kind = "executable";
            };
            js-web = {
              name = "js-web";
              extension = ".js";
              minVersion = "0.14.0";          # Note: until this version, '--build' exits with 1 after writing the page
              buildInputs = [pkgs.nodejs];    # For tests, we currently use the 'js' backend
              runtimeInputs = [];             # Web output doesn't need runtime deps
              compilerEnv = {};
              kind = "website";               # A '.js'/'.html' pair for the browser
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
              kind = "executable";
            };
            chez-callcc = {
              name = "chez-callcc";
              extension = ".ss";
              minVersion = "0.2.2";
              buildInputs = [pkgs.chez];
              runtimeInputs = [pkgs.chez];
              compilerEnv = {};
              kind = "executable";
            };
            chez-monadic = {
              name = "chez-monadic";
              extension = ".ss";
              minVersion = "0.2.2";
              buildInputs = [pkgs.chez];
              runtimeInputs = [pkgs.chez];
              compilerEnv = {};
              kind = "executable";
            };
            chez-cps = {
              name = "chez-cps";
              extension = ".ss";
              minVersion = "0.54.0";
              buildInputs = [pkgs.chez];
              runtimeInputs = [pkgs.chez];
              compilerEnv = {};
              kind = "executable";
            };
          };

          # A backend with per-project settings, e.g. 'bs.llvm.override { effektFlags = ["--optimize"]; }'; chainable
          settableKeys = ["effektFlags" "makeWrapperArgs" "extraFiles"];
          withSettings = backend: settings:
            let unknown = builtins.filter (key: !(builtins.elem key settableKeys)) (builtins.attrNames settings); in
            assert pkgs.lib.assertMsg (unknown == [])
              "unknown setting(s) ${pkgs.lib.concatStringsSep ", " unknown} for backend '${backend.name}' (settable: ${pkgs.lib.concatStringsSep ", " settableKeys})";
            backend // {
              inherit settings;
              override = more: withSettings backend (settings // more);
            };

          # The backends an Effekt version actually supports
          backendsFor = version: pkgs.lib.mapAttrs (name: backend:
            if pkgs.lib.versionAtLeast version backend.minVersion
            then withSettings backend {}
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
              map (b: available.${b.name}.override (b.settings or {})) selected;

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
              available.${selected.name}.override (selected.settings or {});

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
            main,                       # the entry point, as a string relative to 'src'
            backend,                    # selects a single backend, e.g. 'bs: bs.llvm'
            mode ? "build",
            effektFlags ? [],
            includes ? [],              # extra import roots, relative to 'src'
            effektLibraries ? [],       # other Effekt libraries; their paths become import roots
            moduleName ? null,          # the entry point's 'module' name, if it differs from its file name
            nativeBuildInputs ? [],     # the project's build-time tools, besides the backend's
            buildInputs ? [],           # the project's libraries, besides the backend's runtime
            preBuild ? null,            # shell code right before the Effekt build ...
            postBuild ? null,           # ... and right after it
            pname ? null,
            version ? "0.0.0",
          }@args:
            assert pkgs.lib.assertMsg (builtins.isString main)
              "compile needs its entry point as a string relative to 'src' (such as \"src/main.effekt\"), not the path ${toString main}";
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
              inherit preBuild postBuild;

              nativeBuildInputs = [effektBuild] ++ selectedBackend.buildInputs ++ nativeBuildInputs;
              # 'patchShebangs' looks up the launcher's interpreter ('#!/usr/bin/env node') in 'buildInputs' only
              buildInputs = selectedBackend.runtimeInputs ++ buildInputs;

              buildPhase = ''
                runHook preBuild
                effekt --${mode} --backend ${selectedBackend.name} \
                  ${pkgs.lib.escapeShellArgs (includeArgs ++ effektFlags ++ selectedBackend.settings.effektFlags or [])} \
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
          wrap = pkgs.lib.extendMkDerivation {
            constructDrv = pkgs.stdenv.mkDerivation;
            excludeDrvArgNames = ["compiled" "makeWrapperArgs"];
            extendDrvArgs = finalAttrs: {
              pname,
              version ? "0.0.0",
              compiled,                   # a derivation produced by 'compile'
              makeWrapperArgs ? [],
              ...
            }@args:
              let inherit (compiled.passthru) backend artifactName; in
              assert pkgs.lib.assertMsg (compiled.passthru.mode == "build")
                "wrap needs a 'compile' with mode = \"build\" (got \"${compiled.passthru.mode}\")";
              assert pkgs.lib.assertMsg (backend.kind == "executable")
                "wrap expects a backend that produces an executable (e.g. 'js'), but '${backend.name}' produces a website ~> use 'mkSite'";
              {
                inherit pname version;

                # Unpacks a source when given one, but never configures or builds it: 'compile' did
                dontUnpack = !(args ? src);
                dontConfigure = true;
                dontBuild = true;
                nativeBuildInputs = (args.nativeBuildInputs or []) ++ [pkgs.makeWrapper];

                installPhase = ''
                  runHook preInstall

                  # The launcher reads files next to itself ('require("./main.js")'), so the compiler's output stays together
                  mkdir -p $out/libexec $out/bin
                  cp -r ${compiled} $out/libexec/${finalAttrs.pname}

                  makeWrapper $out/libexec/${finalAttrs.pname}/${artifactName} $out/bin/${finalAttrs.pname} \
                    --prefix PATH : ${pkgs.lib.makeBinPath backend.runtimeInputs} \
                    ${pkgs.lib.escapeShellArgs (makeWrapperArgs ++ backend.settings.makeWrapperArgs or [])}

                  runHook postInstall
                '';

                # Anything the caller passes in 'meta' wins over our 'mainProgram'
                meta = { mainProgram = finalAttrs.pname; } // (args.meta or {});
              };
          };

          # A website backend's output as a publishable site root, of real files: 'serve' answers a symlink with 404
          mkSite = pkgs.lib.extendMkDerivation {
            constructDrv = pkgs.stdenv.mkDerivation;
            excludeDrvArgNames = ["compiled" "extraFiles"];
            extendDrvArgs = finalAttrs: {
              pname,
              version ? "0.0.0",
              compiled,                   # a derivation produced by 'compile' with a website backend
              extraFiles ? [],            # project files copied into the site root; later entries win
              ...
            }@args:
              let inherit (compiled.passthru) backend artifactName; in
              assert pkgs.lib.assertMsg (compiled.passthru.mode == "build")
                "mkSite needs a 'compile' with mode = \"build\" (got \"${compiled.passthru.mode}\")";
              assert pkgs.lib.assertMsg (backend.kind == "website")
                "mkSite expects a website backend (e.g. 'js-web') but '${backend.name}' produces an executable ~> use 'wrap'";
              {
                inherit pname version;

                # Unpacks a source when given one, but never configures or builds it: 'compile' did
                dontUnpack = !(args ? src);
                dontConfigure = true;
                dontBuild = true;
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
                      cp --no-preserve=mode ${f} $out/$(stripHash ${f})
                    fi
                  '') (map (f: pkgs.lib.escapeShellArg "${f}") (extraFiles ++ backend.settings.extraFiles or []))}

                  runHook postInstall
                '';
              };
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

          # A package's variants by backend ('{ js = ...; llvm = ...; }'), each with that backend's settings
          variantsOf = package: builtins.listToAttrs (map (b: pkgs.lib.nameValuePair b.name
            (package.override { backends = bs: [(bs.${b.name}.override b.settings)]; })) package.passthru.backends);

          # A package's backends as flake outputs, '<pname>-<backend>' each plus '<pname>-all';
          # the prefix keeps two Effekt packages in one flake from silently overwriting each other
          flakePackages = package:
            let
              variants = pkgs.lib.mapAttrs' (backend: variant: pkgs.lib.nameValuePair "${package.pname}-${backend}" variant)
                (variantsOf package);
            in
              variants // { "${package.pname}-all" = pkgs.linkFarm "${package.pname}-all" variants; };

          # Builds an Effekt package with a single backend: the first one producing an executable, or else the first one.
          # The other selected backends are variants: `package.override { backends = bs: [bs.llvm]; }`
          buildEffektPackage = pkgs.lib.makeOverridable packageFor;
          packageFor =
            {
              pname,                                # package name
              version,                              # package version
              src,                                  # source of the package
              main,                                 # (relative) path to the entrypoint
              tests ? [],                           # (relative) paths to the tests
              effekt ? null,                        # the explicit Effekt derivation to use: uses latest release if not set
              effektVersion ? latestVersion,        # the Effekt version to use
              backends ? (bs: [bs.js]),             # Effekt backends to use
              jvmArgs ? ["-Xss32m"],                # JVM arguments for the compiler
              buildInputs ? [],                     # other build inputs required for the package
              nativeBuildInputs ? [],               # build-time-only tools
              effektFlags ? [],                     # flags passed to the Effekt compiler, such as ["--no-optimize"]
              moduleName ? null,                    # the entry point's 'module' name, if it differs from its file name
              patches ? [],                         # patches to the source, before any Effekt build
              postPatch ? "",                       # prepares the source once, e.g. generates files, before any Effekt build
              preBuild ? null,                      # runs before the Effekt build (of the package and of each test)
              postBuild ? null,                     # ... runs after it
              makeWrapperArgs ? [],                 # for an executable: passed to its wrapper
              extraFiles ? [],                      # for a website: files copied into the site root
              passthru ? {},
              ...
            }@args:
              let
                inherit (resolveEffekt args) selectedBackends effektBuild;
                executables = builtins.filter (b: b.kind == "executable") selectedBackends;
                backend = builtins.head (if executables != [] then executables else selectedBackends);

                # Prepare the "final" source here by applying patches onto `src`
                preparedSrc =
                  if patches == [] && postPatch == "" then src
                  else pkgs.applyPatches { name = "${pname}-${version}-source"; inherit src patches postPatch nativeBuildInputs; };

                compileWith = finalAttrs: b: entry: extra: compile ({
                  effekt = effektBuild;
                  src = assert pkgs.lib.assertMsg (pkgs.lib.all (attr: !(finalAttrs ? ${attr})) ["prePatch" "patches" "postPatch"])
                    "${pname}: the source is prepared once, before any Effekt build: pass 'patches'/'postPatch' to 'buildEffektPackage' (or 'package.override'), not to the package's derivation";
                    finalAttrs.src;
                  main = entry;
                  backend = bs: bs.${b.name}.override (b.settings or {});
                  inherit effektFlags;
                  nativeBuildInputs = finalAttrs.nativeBuildInputs or [];
                  buildInputs = finalAttrs.buildInputs or [];
                  preBuild = finalAttrs.preBuild or null;
                  postBuild = finalAttrs.postBuild or null;
                } // extra);

                # A test is a program: built like the package, run by its 'checkPhase',
                # an exception being that a website's tests run on 'js'.
                testBackend = if backend.kind == "executable" then backend else selectBackend (effektBuild.version or effektVersion) (bs: bs.js);
                testName = test: "${pname}-test-${builtins.replaceStrings ["/"] ["-"] (pkgs.lib.removeSuffix ".effekt" test)}";
                testPrograms = finalAttrs: map (test: wrap {
                  pname = testName test;
                  inherit version makeWrapperArgs;
                  compiled = compileWith finalAttrs testBackend test {};
                }) tests;

                ourArgs = builtins.attrNames (builtins.functionArgs packageFor);
              in
              (if backend.kind == "executable" then wrap else mkSite) (finalAttrs: builtins.removeAttrs args ourArgs // {
                inherit pname version nativeBuildInputs buildInputs preBuild postBuild;
                src = preparedSrc;
                compiled = compileWith finalAttrs backend main { inherit moduleName; };

                doCheck = args.doCheck or (tests != []);
                nativeCheckInputs = (args.nativeCheckInputs or []) ++ testPrograms finalAttrs;
                # By name, from 'PATH': a store path here would make the tests a dependency even with 'doCheck = false'
                checkPhase = args.checkPhase or ''
                  runHook preCheck
                  ${pkgs.lib.concatMapStrings (test: "${testName test}\n") tests}
                  runHook postCheck
                '';

                passthru = passthru // { backends = selectedBackends; };
              } // (if backend.kind == "executable" then { inherit makeWrapperArgs; } else { inherit extraFiles; }));

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
          inherit buildEffektRelease buildEffektFromSource buildEffektPackage getEffekt mkDevShell effektBackends availableBackends compile wrap mkSite serveSite variantsOf flakePackages;
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
            (pkgs.lib.filterAttrs (_: b: b.kind == "executable") effektLib.effektBackends);

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
          # Two backends whose artifacts used to overwrite each other in a shared output directory: now each is its own variant
          both-chez =
            let
              outputs = effektLib.flakePackages (mkCheckPackage "both-chez" (bs: [bs.chez-callcc bs.chez-monadic]));
              builtWith = drv: map (b: b.name) drv.passthru.backends;
            in
            assert pkgs.lib.assertMsg (builtWith outputs.check-both-chez-chez-callcc == ["chez-callcc"]
              && builtWith outputs.check-both-chez-chez-monadic == ["chez-monadic"]) "each variant must be built with its own backend";
            pkgs.runCommand "check-both-chez" {} ''
              ${pkgs.lib.getExe outputs.check-both-chez-chez-callcc} | grep -q "Hello from effekt-nix!"
              ${pkgs.lib.getExe outputs.check-both-chez-chez-monadic} | grep -q "Hello from effekt-nix!"
              touch $out
            '';

          # A backend's settings survive 'variantsOf' and 'flakePackages', and two packages in one flake do not overwrite each other
          flake-packages =
            let
              web = mkCheckPackage "web" (bs: [bs.js (bs.js-web.override { extraFiles = [./tests/hello/test.effekt]; })]);
              outputs = effektLib.flakePackages web // effektLib.flakePackages (mkCheckPackage "other" (bs: [bs.js]));
            in
            assert pkgs.lib.assertMsg (builtins.attrNames (effektLib.variantsOf web) == ["js" "js-web"])
              "'variantsOf' names the variants by backend";
            pkgs.runCommand "check-flake-packages" {} ''
              test -f ${outputs.check-web-js-web}/test.effekt
              ${pkgs.lib.getExe outputs.check-web-js} | grep -q "Hello from effekt-nix!"
              ${pkgs.lib.getExe outputs.check-other-js} | grep -q "Hello from effekt-nix!"
              test -L ${outputs.check-web-all}/check-web-js-web
              touch $out
            '';

          # The web backend produces no executable, so the package is its site root
          js-web =
            let package = mkCheckPackage "js-web" (bs: [bs.js-web]);
            in pkgs.runCommand "check-js-web" {} ''
              test -f ${package}/index.html
              grep -q 'src="main.js"' ${package}/index.html
              test -f ${package}/main.js
              touch $out
            '';

          # Some projects like 'community/effekt-rejit' generate sources before the Effekt build, with their own tools
          hooks =
            let package = effektLib.buildEffektPackage {
              pname = "check-hooks";
              version = "0.0.0";
              src = ./tests/hello;
              main = "main.effekt";
              backends = bs: [bs.js];
              nativeBuildInputs = [pkgs.hello];
              postPatch = ''echo "def main() = println(\"$(hello)\")" > main.effekt'';
            };
            in pkgs.runCommand "check-hooks" {} ''
              ${pkgs.lib.getExe package} | grep -q "Hello, world!"
              touch $out
            '';

          # The package's own phases see its arguments: tools in its 'checkPhase'/'postInstall', its own 'checkPhase', and its tests are wrapped like the package
          argument-routing =
            let
              package = effektLib.buildEffektPackage {
                pname = "check-argument-routing";
                version = "0.0.0";
                src = ./tests/hello;
                main = "main.effekt";
                tests = ["test.effekt"];
                nativeBuildInputs = [pkgs.hello];
                buildInputs = [pkgs.zlib];
                makeWrapperArgs = ["--set" "CHECK_MARKER" "1"];
                checkPhase = ''
                  runHook preCheck
                  check-argument-routing-test-test
                  hello > check-ran
                  runHook postCheck
                '';
                postInstall = "cp check-ran $out/check-ran";
              };
              test = builtins.head (builtins.filter (d: pkgs.lib.hasPrefix "check-argument-routing-test" (d.name or "")) package.nativeBuildInputs);
            in
            assert pkgs.lib.assertMsg (builtins.any (d: d.name == pkgs.zlib.name) package.buildInputs) "the package's derivation must get its 'buildInputs'";
            pkgs.runCommand "check-argument-routing" {} ''
              grep -q "Hello, world!" ${package}/check-ran
              grep -q CHECK_MARKER ${pkgs.lib.getExe test}
              touch $out
            '';

          # 'overrideAttrs' reaches the Effekt build: a new source, and hooks with their tools
          override-attrs =
            let
              package = effektLib.buildEffektPackage {
                pname = "check-override-attrs";
                version = "0.0.0";
                src = ./tests/hello;
                main = "main.effekt";
              };
              newSource = package.overrideAttrs { src = pkgs.writeTextDir "main.effekt" ''def main() = println("new source")''; };
              newHook = package.overrideAttrs (old: {
                nativeBuildInputs = old.nativeBuildInputs ++ [pkgs.hello];
                preBuild = ''echo "def main() = println(\"$(hello)\")" > main.effekt'';
              });
              patched = package.overrideAttrs { postPatch = "true"; };
            in
            assert pkgs.lib.assertMsg (!(builtins.tryEval patched.drvPath).success) "patches on the package's derivation must be refused";
            pkgs.runCommand "check-override-attrs" {} ''
              ${pkgs.lib.getExe newSource} | grep -q "new source"
              ${pkgs.lib.getExe newHook} | grep -q "Hello, world!"
              touch $out
            '';

          # An entry point given as a Nix path is refused, whether as the package's 'main', in its 'tests', or in 'compile'
          entry-point-strings =
            let
              refused = drv: !(builtins.tryEval drv.drvPath).success;
              package = args: effektLib.buildEffektPackage ({
                pname = "check-entry-point-strings";
                version = "0.0.0";
                src = ./tests/hello;
                main = "main.effekt";
              } // args);
            in
            assert pkgs.lib.assertMsg (refused (package { main = ./tests/hello/main.effekt; })) "a path as 'main' must be refused";
            assert pkgs.lib.assertMsg (refused (package { tests = [./tests/hello/test.effekt]; })) "a path in 'tests' must be refused";
            assert pkgs.lib.assertMsg (refused (effektLib.compile { src = ./tests/hello; main = ./tests/hello/main.effekt; backend = bs: bs.js; }))
              "a path as 'compile''s 'main' must be refused";
            assert pkgs.lib.assertMsg (!(refused (package { tests = ["test.effekt"]; }))) "strings must still be accepted";
            pkgs.runCommand "check-entry-point-strings" {} "touch $out";

          # 'preBuild'/'postBuild' run around the Effekt build itself: before it sees the source, after it wrote its output
          build-hooks =
            let package = effektLib.buildEffektPackage {
              pname = "check-build-hooks";
              version = "0.0.0";
              src = ./tests/hello;
              main = "main.effekt";
              backends = bs: [bs.js];
              preBuild = ''echo 'def main() = println("Hello from preBuild")' > main.effekt'';
              postBuild = ''echo "postBuild ran" > $out/hook-marker.txt'';
            };
            in pkgs.runCommand "check-build-hooks" {} ''
              ${pkgs.lib.getExe package} | grep -q "Hello from preBuild"
              grep -q "postBuild ran" ${package}/libexec/check-build-hooks/hook-marker.txt
              touch $out
            '';

          # A selector that ignores 'bs' still gets the table's own backend, which is where 'minVersion' is enforced
          selector-ignoring-bs =
            let
              tampered = effektLib.effektBackends.js // { buildInputs = []; };
              compiled = backend: effektLib.compile { src = ./tests/hello; main = "main.effekt"; inherit backend; };
            in
            pkgs.linkFarm "check-selector-ignoring-bs" {
              selectBackends = pkgs.testers.testEqualDerivation "'selectBackends' kept what the selector returned instead of the table's backend"
                (effektLib.getEffekt { backends = _: [tampered]; }) (effektLib.getEffekt { backends = bs: [bs.js]; });
              selectBackend = pkgs.testers.testEqualDerivation "'selectBackend' kept what the selector returned instead of the table's backend"
                (compiled (_: tampered)) (compiled (bs: bs.js));
            };
        }
      );
    };
}
