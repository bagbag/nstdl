{
  # Host facts stay in the consumer repository. Replace this with the machine's
  # generated hardware and filesystem configuration.
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/REPLACE-ME";
    fsType = "ext4";
  };

  # Add site-specific services or network configuration here.
}
