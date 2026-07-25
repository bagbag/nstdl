# Fixture flake

This is a consumer fixture, not a published flake. Its relative `nstdl` input
cannot escape the Nix store after the fixture is copied there, so local runs
must override that input with the checkout under test:

Run every flake-parts and raw-module evaluation with:

```sh
bash tests/evaluate.sh
```

The fixture covers NixOS server and workstation configurations, a Darwin
workstation configuration, and standalone Home Manager. The NixOS fixtures add
minimal fake boot and root-filesystem modules so the system toplevel evaluates
without carrying any real host facts.
