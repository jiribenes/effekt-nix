# effekt-nix

> [!NOTE]
> Contributions are very welcome! :)

A comprehensive Nix flake for the [Effekt programming language](https://github.com/effekt-lang/effekt).

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
  ```

</details>

---

<details>
  <summary><b>I want to quickly play with Effekt!</b></summary>

  Sure, let's get you a devshell in which you can just call `effekt` then:
  ```sh
  # a development shell with the latest Effekt version
  nix develop github:jiribenes/effekt-nix

  # a development shell with the nightly Effekt version
  nix develop github:jiribenes/effekt-nix#nightly

  # a development shell for developing the Effekt compiler
  nix develop github:jiribenes/effekt-nix#compilerDev
  ```

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

## Documentation

FIXME: Update for Nix flake!
