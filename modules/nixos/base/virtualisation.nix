{
  config,
  pkgs,
  hostConfig,
  ...
}:
{
  services.qemuGuest.enable = hostConfig.virtualisation == "qemu";
  virtualisation.vmware.guest.enable = hostConfig.virtualisation == "vmware";
}
