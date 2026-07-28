{
  config.nstdl.profiles.nixos = {
    intel =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        hardware = {
          cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
          graphics.extraPackages = with pkgs; [
            intel-media-driver
            libvdpau-va-gl
            intel-compute-runtime
            intel-npu-driver
          ];
        };

        environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
        boot.kernelParams = [ "intel_pstate=active" ];
      };

    laptop = {
      services = {
        auto-cpufreq.enable = true;
        thermald.enable = true;
        power-profiles-daemon.enable = false;
      };
    };
  };
}
