{ inputs }:
{
  config.nstdl.profiles.darwin.sleepless = import ../../darwin/features/sleepless.nix {
    source = inputs.sleepless;
  };
}
