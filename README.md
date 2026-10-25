# effekt-nix

> [!NOTE]
> Contributions are very welcome, see Contributing section below! :)

A comprehensive Nix flake for the [Effekt programming language](https://github.com/effekt-lang/effekt).

## Features

- pre-packaged Effekt compiler releases for `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`, and for any subset of Effekt's backends
- building the Effekt compiler from source or from a GitHub Release
- pre-made development shells with Effekt compiler releases and for Effekt compiler development
- Nix toolchain to build, test, and package apps written in Effekt

## Quick Start

<details>
  <summary><b>I want to quickly run Effekt!</b></summary>

  Great! Here's how you run the latest released version of Effekt:
  ```sh
  # run Effekt REPL
  nix run github:jiribenes/effekt-nix

  # run the latest version of the Effekt compiler on a file (with default backend)
  nix run github:jiribenes/effekt-nix -- file.effekt

  # run the latest version of the Effekt compiler on a file with the LLVM backend
  nix run github:jiribenes/effekt-nix -- --backend llvm file.effekt

  # run a specific version of the Effekt compiler
  nix run github:jiribenes/effekt-nix#effekt_0_3_0 -- --help
  ```

</details>

---

<details>
  <summary><b>I want to quickly play with Effekt!</b></summary>

  Sure, let's get you a devshell in which you can just call `effekt` then:
  ```sh
  # a shell with the latest Effekt version
  nix develop github:jiribenes/effekt-nix

  # a shell with a specific Effekt version
  nix develop github:jiribenes/effekt-nix#effekt_0_3_0

  # ADVANCED: a shell for developing the Effekt compiler
  nix develop github:jiribenes/effekt-nix#compilerDev
  ```

  You can use this -- for example -- for benchmarking or for working with LSP support in VSCode.

</details>

---

<details>
  <summary><b>I want to quickly install Effekt on my machine!</b></summary>

  Alright, let's install Effekt on your machine so that you can call `effekt` at any time:
  ```sh
  # install latest version of Effekt
  nix profile install github:jiribenes/effekt-nix
  ```

</details>

---

<details>
  <summary><b>I want to quickly build Effekt on my machine!</b></summary>

  _... okay, I guess? ..._
  ```sh
  # builds the latest version of Effekt
  nix build github:jiribenes/effekt-nix
  ```

  The result of the build is in the `result/` folder (the binary is in `result/bin/`).

</details>

---

<details>
  <summary><b>I want to create a new Effekt project!</b></summary>

You can use this Nix flake directly, but there's also a full template with CI available in [`jiribenes/effekt-template`](https://github.com/jiribenes/effekt-template).

</details>

## Example: packaging an app written in Effekt

```nix
{
  inputs.effekt-nix.url = "github:jiribenes/effekt-nix";
  
  outputs = { self, nixpkgs, effekt-nix }:
    let
      system = "x86_64-linux"; # or "aarch64-darwin" if you're on a M1
      pkgs = nixpkgs.legacyPackages.${system};
      effekt-lib = effekt-nix.lib.mkLib pkgs;

      # You can set a fixed Effekt version and your supported backends here:
      effektVersion = "0.3.0";
      backends = bs: [ bs.js bs.llvm ];

      # A package for your Effekt project
      package = effekt-lib.buildEffektPackage {
        pname = "my-effekt-project";
        version = "1.0.0";
        src = ./.;               # Path to your Effekt project
        main = "./main.effekt";  # the main Effekt file to run

        inherit effektVersion backends;
      };
    in {
      # Your package, plus one for each backend (e.g. 'my-effekt-project-llvm')
      packages.${system} = effekt-lib.flakePackages package // { default = package; };

      # Development shell for your project
      devShells.${system}.default = effekt-lib.mkDevShell {
        inherit effektVersion backends;
      };
    };
}
```

Here's a breakdown of `buildEffektPackage`'s arguments:

- `pname`: The name of your package.
- `version`: The version of your package.
- `src`: The source directory of your Effekt project.
- `main`: The main Effekt file to compile.
- `tests`: (Optional) A list of test files to run during the build process, with the package's backend (a website's tests run on `js`), each variant runs them with its own.
- `effekt`: (Optional) A specific Effekt derivation to use. If not provided, it uses the version specified by `effektVersion`.
- `effektVersion`: The version of Effekt to use (defaults to the latest version).
- `backends`: A function selecting the backends your project works with, e.g. `bs: [ bs.js bs.llvm ]`. The package is built with the first one that produces an executable (or else the first one) + the others are variants, see below. `mkDevShell` takes the same function.
- `buildInputs`: (Optional) Additional build inputs required for your package.
- `nativeBuildInputs`: (Optional) Additional build-time-only tools, for the build and for `postPatch`.
- `effektFlags`: (Optional) Flags passed to the Effekt compiler, for example `[ "--no-optimize" ]`.
- `patches` / `postPatch`: (Optional) Patches / shell code preparing the source once, before any Effekt build, e.g. generating files.
- `preBuild` / `postBuild`: (Optional) Shell code to run before / after the Effekt build.
- `moduleName`: (Optional) The entry point's `module` name, if it differs from its file name (Effekt names its output after the module).
- `makeWrapperArgs`: (Optional) For an executable: arguments for its wrapper, e.g. `[ "--prefix" "PATH" ":" "${pkgs.git}/bin" ]`.
- `extraFiles`: (Optional) For a website: files copied into the site root.
- `meta`: (Optional) Package metadata such as `description` or `license`. Note that `mainProgram` is pre-set for you.

The package is built with one backend: you get `bin/${pname}`, or the site root for a website backend like `js-web`.
The other backends are variants, for example `package.override { backends = bs: [ bs.llvm ]; }`.
`flakePackages package` gives you all of them as flake outputs, see the example above.
`variantsOf package` gives them by backend instead (`{ js = ...; llvm = ...; }`).
Other arguments (`postInstall`, ...) are passed on to the package's derivation.

To use the same Effekt compiler for the package and for the development shell (like the template does), select it once with `getEffekt` and pass it as `effekt` to both:
```nix
effekt = effekt-lib.getEffekt { version = "0.82.0"; backends = bs: [ bs.js bs.llvm ]; };
```
Without specifying a `version`, you get the latest release (_recommended_!).

`effekt-nix` also supports multiple platforms (see `effekt-nix.lib.supportedSystems`). Use `nixpkgs.lib.genAttrs effekt-nix.lib.supportedSystems` (like the [template](https://github.com/jiribenes/effekt-template/blob/main/flake.nix))
to define outputs for multiple systems at the same time.

### Building a website (the `js-web` backend)

The `js-web` backend produces a page instead of an executable, so it is built with `mkSite` rather than with `buildEffektPackage`:

```nix
let
  effekt-lib = effekt-nix.lib.mkLib pkgs;

  site = effekt-lib.mkSite {
    pname = "my-game";
    compiled = effekt-lib.compile {
      src = ./.;
      main = "src/main.effekt";
      backend = bs: bs.js-web;
    };
    extraFiles = [ ./public ]; # assets
  };
in {
  packages.${system}.web = site;

  # use with 'nix run .#serve' for a preview
  packages.${system}.serve = effekt-lib.serveSite { inherit site; };
}
```

The result is a site root: `index.html` plus the compiled `.js`, as real files (never symlinks, which `serve` answers with a 404), and can be uploaded to GitHub Pages as-is:

```yaml
- run: nix build .#web
- uses: actions/upload-pages-artifact@v5
  with: { path: result }
```

### Lower-level building blocks

When a project needs more control than `buildEffektPackage` offers (being a bootloader image, a custom link step,
an unusual layout or something similar), it can use these primitives that `buildEffektPackage` is composed of directly:

- `compile`: compiles a single entry point on a single backend. `$out` is exactly what the Effekt compiler emitted.
  With `mode = "compile"` it stops at the backend representation (e.g. `main.ll`) instead of building a launcher.
  Takes `effektFlags`, `includes` and `effektLibraries` (all become `--includes`), `nativeBuildInputs`/`buildInputs`,
  and `effekt`/`effektVersion` like `buildEffektPackage`.
  Effekt names the output after the entry point's module, so pass `moduleName` if its `module` declaration
  differs from the file name.
- `wrap`: turns a compiled entry point into a program: artifacts in `libexec/`, a wrapper in `bin/<pname>`.
- `mkSite` / `serveSite`: as above, for website backends.

`wrap` and `mkSite` also take the usual `mkDerivation` arguments (`postInstall`, `meta`, ...).
A backend can carry its own settings, for example `bs.llvm.override { effektFlags = [ "--optimize" ]; }`
(`effektFlags`, `makeWrapperArgs` or `extraFiles`), also in `buildEffektPackage`'s `backends`.

```nix
# example: :compile to LLVM IR and link it yourself
compiled = effekt-lib.compile {
  src = ./.; main = "src/main.effekt"; backend = bs: bs.llvm; mode = "compile";
  effektFlags = [ "--optimize" ];
  includes = [ "src/" "lib/" ];
};
# ${compiled}/main.ll is then an ordinary input to any other derivation
```

### Using a custom Effekt compiler build for your app

```nix
{
  inputs.effekt-nix.url = "github:jiribenes/effekt-nix";
  
  outputs = { self, nixpkgs, effekt-nix }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      effekt-lib = effekt-nix.lib.mkLib pkgs;
      
      # Define your own Effekt build from source:
      myCustomEffekt = effekt-lib.buildEffektFromSource {
        # ... by defining the path to your compiler source here:
        src = ./path/to/effekt/compiler/source;
        # ... its version:
        version = "0.99.0";
        # ... and the SHA256 of its Scala dependencies (build with a fake one first, Nix then tells you the correct one):
        depsSha256 = pkgs.lib.fakeSha256;
        backends = bs: [ bs.js bs.llvm ];
      };
    in {
      packages.${system}.default = effekt-lib.buildEffektPackage {
        pname = "my-custom-effekt-project";
        version = "1.0.0";
        src = ./.;                           # Path to your Effekt project
        main = "./src/main.effekt";          # path to the entrypoint
        tests = [ "./src/mytest.effekt" ];   # path to the tests

        effekt = myCustomEffekt;
      };

      devShells.${system}.default = effekt-lib.mkDevShell {
        effekt = myCustomEffekt;
      };
    };
}
```

## Contributing

Contributions of all kinds are very welcome, feel free to just create a PR.

We would especially welcome contributions fixing the various [issues](https://github.com/jiribenes/effekt-nix/issues) this project has
and/or with the [WIP PRs](https://github.com/jiribenes/effekt-nix/pulls) that aren't done yet.
