{
  config,
  pkgs,
  ...
}:
{
  services.qemuGuest.enable = config.nstdl.hostConfig.virtualisation == "qemu";
  virtualisation.vmware.guest.enable = config.nstdl.hostConfig.virtualisation == "vmware";
}
