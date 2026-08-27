#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="path:${repo_dir}/tests/fixture-flake"
override=(--override-input nstdl "path:${repo_dir}" --no-write-lock-file)

nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-server.config.system.build.toplevel.drvPath"
direct_host_name="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-direct.config.networking.hostName")"
[[ "${direct_host_name}" == "test-direct" ]]
server_allow_users="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-server.config.services.openssh.settings.AllowUsers")"
server_root_keys="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-server.config.users.users.root.openssh.authorizedKeys.keys")"
server_kernel="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-server.config.boot.kernelPackages.kernel.version")"
server_systemd_boot="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-server.config.boot.loader.systemd-boot.enable")"
server_efi_mutation="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-server.config.boot.loader.efi.canTouchEfiVariables")"
server_zram="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-server.config.zramSwap.enable")"
server_firmware="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-server.config.hardware.enableRedistributableFirmware")"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-server.config.security.sudo.extraRules"
qemu_guest_enabled="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-server.config.services.qemuGuest.enable")"
[[ "${server_allow_users}" == *'"admin"'* && "${server_allow_users}" == *'"root"'* && "${server_allow_users}" == *'"deploy"'* ]]
[[ "${server_root_keys}" == *"alice"* ]]
[[ "${server_kernel}" == 6.12* && "${server_systemd_boot}" == "true" && "${server_efi_mutation}" == "true" && "${server_zram}" == "true" && "${server_firmware}" == "false" ]]
deploy_target="$(nix eval "${override[@]}" --raw "${fixture}#deploy.nodes.test-server.hostname")"
deploy_user="$(nix eval "${override[@]}" --raw "${fixture}#deploy.nodes.test-server.sshUser")"
network_addresses="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-server.config.systemd.network.networks.10-nstdl.networkConfig.Address")"
[[ "${deploy_target}" == "test-server.example" && "${deploy_user}" == "admin" && "${network_addresses}" == '["192.0.2.10/24"]' ]]
nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-root-only.config.system.build.toplevel.drvPath"
root_only_allow_users="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-root-only.config.services.openssh.settings.AllowUsers")"
root_only_keys="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-root-only.config.users.users.root.openssh.authorizedKeys.keys")"
root_only_firmware="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-root-only.config.hardware.enableRedistributableFirmware")"
[[ "${root_only_allow_users}" == '["root"]' && "${root_only_keys}" == *"tester"* && "${root_only_firmware}" == "true" ]]

root_ssh_bypass_output="$(mktemp)"
if nix eval --impure --expr "
  let
    flake = builtins.getFlake \"path:${repo_dir}\";
  in
  (flake.inputs.nixpkgs.lib.nixosSystem {
    system = \"x86_64-linux\";
    modules = [
      (import "${repo_dir}/modules/nixos/profiles/accounts.nix")
      {
        nstdl.accounts = {
          role = \"server\";
          extraSshUsers = [ \"root\" ];
        };
        boot.loader.grub = {
          enable = true;
          devices = [ \"nodev\" ];
        };
        fileSystems.\"/\" = {
          device = \"/dev/null\";
          fsType = \"ext4\";
        };
        system.stateVersion = \"25.11\";
      }
    ];
  }).config.system.build.toplevel.drvPath
" >"${root_ssh_bypass_output}" 2>&1; then
  echo "root SSH bypass must be rejected" >&2
  rm -f "${root_ssh_bypass_output}"
  exit 1
fi
if ! rg -q "root SSH access requires accounts.root.enable" "${root_ssh_bypass_output}"; then
  echo "root SSH bypass failure must identify the break-glass requirement" >&2
  rm -f "${root_ssh_bypass_output}"
  exit 1
fi
rm -f "${root_ssh_bypass_output}"

nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-workstation.config.system.build.toplevel.drvPath"
vmware_guest_enabled="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.virtualisation.vmware.guest.enable")"
workstation_ssh_enabled="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.services.openssh.enable")"
workstation_ssh_password_auth="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.services.openssh.settings.PasswordAuthentication")"
workstation_podman_enabled="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.virtualisation.podman.enable")"
workstation_podman_search_registries="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.virtualisation.containers.registries.settings.registries.search.registries")"
workstation_podman_policy="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.virtualisation.containers.policy")"
workstation_nh_enabled="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.programs.nh.enable")"
workstation_nh_clean_enabled="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.programs.nh.clean.enable")"
workstation_nh_clean_args="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-workstation.config.programs.nh.clean.extraArgs")"
workstation_gc_automatic="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.nix.gc.automatic")"
workstation_optimise_automatic="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.nix.optimise.automatic")"
workstation_trusted_users="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.nix.settings.trusted-users")"
workstation_console_mode="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-workstation.config.boot.loader.systemd-boot.consoleMode")"
workstation_boot_limit="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.boot.loader.systemd-boot.configurationLimit")"
workstation_tmp_huge_pages="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-workstation.config.boot.tmp.tmpfsHugeMemoryPages")"
workstation_xkb_layout="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-workstation.config.services.xserver.xkb.layout")"
workstation_xkb_variant="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-workstation.config.services.xserver.xkb.variant")"
workstation_locale_format="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-workstation.config.i18n.extraLocaleSettings.LC_TIME")"
workstation_ozone="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-workstation.config.home-manager.users.tester.home.sessionVariables.NIXOS_OZONE_WL")"
workstation_intel_pstate="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.boot.kernelParams")"
workstation_va_driver="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-workstation.config.environment.sessionVariables.LIBVA_DRIVER_NAME")"
workstation_auto_cpufreq="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.services.auto-cpufreq.enable")"
workstation_thermald="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.services.thermald.enable")"
workstation_power_profiles="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.services.power-profiles-daemon.enable")"
workstation_intel_microcode="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.hardware.cpu.intel.updateMicrocode")"
workstation_qui_enabled="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.services.qui.enable")"
workstation_home_packages="$(nix eval "${override[@]}" --json --apply 'packages: builtins.map (package: package.name) packages' "${fixture}#nixosConfigurations.test-workstation.config.home-manager.users.tester.home.packages")"
workstation_home_packages_unique="$(nix eval "${override[@]}" --json --apply 'packages: let names = builtins.map (package: package.name) packages; in builtins.all (name: builtins.length (builtins.filter (candidate: candidate == name) names) == 1) names' "${fixture}#nixosConfigurations.test-workstation.config.home-manager.users.tester.home.packages")"
workstation_ghostty_settings="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.home-manager.users.tester.programs.ghostty.settings")"
developer_home_packages="$(nix eval "${override[@]}" --json --apply 'packages: builtins.map (package: package.name) packages' "${fixture}#nixosConfigurations.test-workstation.config.home-manager.users.alice.home.packages")"
developer_fzf_nushell_integration="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.home-manager.users.alice.programs.fzf.enableNushellIntegration")"
workstation_system_packages="$(nix eval "${override[@]}" --json --apply 'packages: builtins.map (package: package.name) packages' "${fixture}#nixosConfigurations.test-workstation.config.environment.systemPackages")"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.nix.settings.substituters"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.nix.gc.automatic"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.programs.firefox.enable"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.programs.thunderbird.enable"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-workstation.config.home-manager.users.tester.services.flatpak.update.auto"
[[ "${qemu_guest_enabled}" == "true" && "${vmware_guest_enabled}" == "true" && "${workstation_ssh_enabled}" == "true" && "${workstation_ssh_password_auth}" == "false" && "${workstation_podman_enabled}" == "true" && "${workstation_podman_search_registries}" == '["docker.io","quay.io"]' && "${workstation_podman_policy}" == *'"default":[{"type":"reject"}]'* && "${workstation_podman_policy}" == *'"docker.io":[{"type":"insecureAcceptAnything"}]'* && "${workstation_podman_policy}" == *'"quay.io":[{"type":"insecureAcceptAnything"}]'* && "${workstation_podman_policy}" == *'"docker-daemon":{"":['* && "${workstation_nh_enabled}" == "true" && "${workstation_nh_clean_enabled}" == "true" && "${workstation_nh_clean_args}" == "--keep 5 --keep-since 14d --optimise" && "${workstation_gc_automatic}" == "false" && "${workstation_optimise_automatic}" == "false" && "${workstation_trusted_users}" == *'"tester"'* ]]
[[ "${workstation_console_mode}" == "max" && "${workstation_boot_limit}" == "10" && "${workstation_tmp_huge_pages}" == "within_size" && "${workstation_xkb_layout}" == "de" && "${workstation_xkb_variant}" == "nodeadkeys" && "${workstation_locale_format}" == "de_DE.UTF-8" && "${workstation_ozone}" == "1" ]]
[[ "${workstation_intel_pstate}" == *'"intel_pstate=active"'* && "${workstation_va_driver}" == "iHD" && "${workstation_auto_cpufreq}" == "true" && "${workstation_thermald}" == "true" && "${workstation_power_profiles}" == "false" && "${workstation_intel_microcode}" == "false" ]]
[[ "${workstation_qui_enabled}" == "true" ]]
[[ "${workstation_ghostty_settings}" == *'"background-blur":[false]'* && "${workstation_ghostty_settings}" == *'"background-opacity":[0.9]'* && "${workstation_ghostty_settings}" == *'"scrollback-limit":[10000000]'* && "${workstation_ghostty_settings}" == *'"unfocused-split-opacity":[0.9]'* && "${workstation_ghostty_settings}" == *'"window-vsync":[true]'* ]]
[[ "${workstation_home_packages_unique}" == "true" ]]
[[ "${developer_fzf_nushell_integration}" == "true" ]]
[[ "${workstation_home_packages}" == *'signal-desktop-'* ]]
[[ "${workstation_home_packages}" == *'7zz-'* && "${workstation_home_packages}" == *'bc-'* && "${workstation_home_packages}" == *'e2fsprogs-'* && "${workstation_home_packages}" == *'openssl-'* && "${workstation_home_packages}" == *'unzip-'* && "${workstation_home_packages}" == *'codex-'* && "${workstation_home_packages}" == *'claude-code-'* && "${workstation_home_packages}" == *'dbeaver-bin-'* && "${workstation_home_packages}" == *'typst-'* && "${workstation_home_packages}" == *'pandoc-'* && "${workstation_home_packages}" == *'imagemagick-'* && "${workstation_home_packages}" == *'pdfcpu-'* && "${workstation_home_packages}" != *'ragenix-'* && "${workstation_home_packages}" != *'sysprof-'* && "${developer_home_packages}" != *'dbeaver-bin-'* ]]
[[ "${workstation_system_packages}" == *'nodejs-'* && "${workstation_system_packages}" == *'oxlint-'* && "${workstation_system_packages}" != *'typst-'* && "${workstation_system_packages}" != *'pandoc-'* ]]
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-postgresql.config.services.postgresql.ensureDatabases"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-postgresql.config.services.postgresql.ensureUsers"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-postgresql.config.systemd.timers.nstdl-postgresql-backup-app.timerConfig"

postgresql_backup_script="$(nix eval "${override[@]}" --apply 'builtins.unsafeDiscardStringContext' --raw "${fixture}#nixosConfigurations.test-postgresql.config.systemd.services.nstdl-postgresql-backup-app.script")"
postgresql_plain_script="$(nix eval "${override[@]}" --apply 'builtins.unsafeDiscardStringContext' --raw "${fixture}#nixosConfigurations.test-postgresql.config.systemd.services.nstdl-postgresql-backup-app_plain.script")"
postgresql_globals_script="$(nix eval "${override[@]}" --apply 'builtins.unsafeDiscardStringContext' --raw "${fixture}#nixosConfigurations.test-postgresql.config.systemd.services.nstdl-postgresql-backup-globals.script")"
postgresql_backup_target="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-postgresql.config.systemd.targets.nstdl-postgresql-backup.wants")"
postgresql_reconcile_script="$(nix eval "${override[@]}" --apply 'builtins.unsafeDiscardStringContext' --raw "${fixture}#nixosConfigurations.test-postgresql.config.systemd.services.nstdl-postgresql-reconcile.script")"
postgresql_reconcile_credentials="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-postgresql.config.systemd.services.nstdl-postgresql-reconcile.serviceConfig.LoadCredential")"
postgresql_reconcile_wanted_by="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-postgresql.config.systemd.services.nstdl-postgresql-reconcile.wantedBy")"
postgresql_backup_after="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-postgresql.config.systemd.services.nstdl-postgresql-backup-app.after")"
[[ "${postgresql_backup_script}" == *"pg_dump"* && "${postgresql_backup_script}" == *"--format=custom"* && "${postgresql_backup_script}" == *"--compress=zstd:10"* && "${postgresql_backup_script}" == *"-mtime +14"* ]]
[[ "${postgresql_plain_script}" == *"pg_dump"* && "${postgresql_plain_script}" == *"--create"* && "${postgresql_plain_script}" == *"| cat >"* && "${postgresql_plain_script}" != *"--compress="* && "${postgresql_plain_script}" == *"%Y-%m-%d-%H%M%S-%N"* && "${postgresql_plain_script}" == *"mv --no-clobber"* ]]
[[ "${postgresql_globals_script}" == *"pg_dumpall --globals-only"* && "${postgresql_globals_script}" == *"gzip -c -6"* ]]
[[ "${postgresql_backup_target}" == *"nstdl-postgresql-backup-app.service"* && "${postgresql_backup_target}" == *"nstdl-postgresql-backup-app_plain.service"* && "${postgresql_backup_target}" == *"nstdl-postgresql-backup-globals.service"* ]]
[[ "${postgresql_reconcile_script}" == *"GRANT \"app_readers\" TO \"app\""* && "${postgresql_reconcile_script}" == *"CREATE EXTENSION IF NOT EXISTS \"pgcrypto\""* ]]
[[ "${postgresql_reconcile_credentials}" == *"postgresql-role-app:/run/agenix/app-db-password"* && "${postgresql_reconcile_script}" == *"pg_read_file('\$CREDENTIALS_DIRECTORY/postgresql-role-app')"* ]]
[[ "${postgresql_reconcile_wanted_by}" == *"multi-user.target"* && "${postgresql_backup_after}" == *"postgresql-setup.service"* ]]

postgresql_invalid_output="$(mktemp)"
if nix eval --impure --expr "
  let
    flake = builtins.getFlake \"path:${repo_dir}\";
  in
  (flake.inputs.nixpkgs.lib.nixosSystem {
    system = \"x86_64-linux\";
    modules = [
      (import "${repo_dir}/modules/nixos/features/postgresql.nix")
      {
        services.nstdl.postgresql = {
          enable = true;
          backup.enable = true;
          backup.jobs.cluster = {
            kind = \"cluster\";
            format = \"custom\";
          };
        };
        boot.loader.grub = {
          enable = true;
          devices = [ \"nodev\" ];
        };
        fileSystems.\"/\" = {
          device = \"/dev/null\";
          fsType = \"ext4\";
        };
        system.stateVersion = \"25.11\";
      }
    ];
  }).config.system.build.toplevel.drvPath
" >"${postgresql_invalid_output}" 2>&1; then
  echo "cluster PostgreSQL backups must reject custom format" >&2
  rm -f "${postgresql_invalid_output}"
  exit 1
fi
if ! rg -q "requires format = plain" "${postgresql_invalid_output}"; then
  echo "cluster PostgreSQL backup failure must identify the format invariant" >&2
  rm -f "${postgresql_invalid_output}"
  exit 1
fi
rm -f "${postgresql_invalid_output}"
nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-secrets.config.age.rekey.hostPubkey"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-secrets.config.age.rekey.extraEncryptionPubkeys"
master_identity_count="$(nix eval "${override[@]}" --raw --apply 'identities: builtins.toString (builtins.length identities)' "${fixture}#nixosConfigurations.test-secrets.config.age.rekey.masterIdentities")"
[[ "${master_identity_count}" == "2" ]]
nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-secrets.config.age.rekey.localStorageDir"
password_hash_file="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-secrets.config.users.users.admin.hashedPasswordFile")"
agenix_password_hash_file="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-secrets.config.age.secrets.database-password.path")"
[[ "${password_hash_file}" == "${agenix_password_hash_file}" ]]
database_secret_group="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-secrets.config.age.secrets.database-password.group")"
secret_acl_group="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-secrets.config.users.groups.${database_secret_group}.members")"
secret_acl_mode="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-secrets.config.age.secrets.database-password.mode")"
[[ "${secret_acl_group}" == '["postgres"]' && "${secret_acl_mode}" == "0440" ]]
hyphenated_secret_group="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-secrets.config.age.secrets.db-prod.group")"
dotted_secret_group="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-secrets.config.age.secrets.\"db.prod\".group")"
hyphenated_secret_members="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-secrets.config.users.groups.${hyphenated_secret_group}.members")"
dotted_secret_members="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-secrets.config.users.groups.${dotted_secret_group}.members")"
[[ "${hyphenated_secret_group}" != "${dotted_secret_group}" && "${hyphenated_secret_members}" == '["nobody"]' && "${dotted_secret_members}" == '["postgres"]' ]]
nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-storage.config.system.build.toplevel.drvPath"
storage_luks_enabled="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-storage.config.disko.devices.disk.main.content.partitions.main.content.settings.allowDiscards")"
storage_esp_size="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-storage.config.disko.devices.disk.main.content.partitions.esp.size")"
storage_subvolumes="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-storage.config.disko.devices.disk.main.content.partitions.main.content.content.subvolumes")"
storage_snapshots="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-storage.config.services.btrbk.instances.nstdl.settings.snapshot_preserve")"
storage_calendar="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-storage.config.services.btrbk.instances.nstdl.onCalendar")"
storage_scrub="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-storage.config.services.btrfs.autoScrub.interval")"
nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-storage-plain.config.system.build.toplevel.drvPath"
plain_storage_type="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-storage-plain.config.disko.devices.disk.main.content.partitions.main.content.type")"
plain_storage_snapshots="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-storage-plain.config.services.btrbk.instances")"
plain_storage_scrub="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-storage-plain.config.services.btrfs.autoScrub.interval")"
[[ "${storage_luks_enabled}" == "true" && "${storage_esp_size}" == "1G" && "${storage_subvolumes}" == *'"/@root"'* && "${storage_subvolumes}" == *'"/@home"'* && "${storage_subvolumes}" == *'"/@nix"'* && "${storage_subvolumes}" == *'"/@var"'* && "${storage_subvolumes}" == *'"/@snapshots"'* && "${storage_snapshots}" == "72h 14d 4w" && "${storage_calendar}" == "hourly" && "${storage_scrub}" == "monthly" && "${plain_storage_type}" == "btrfs" && "${plain_storage_snapshots}" == "{}" && "${plain_storage_scrub}" == "monthly" ]]

check_invalid_host() {
  local expected_error="$1"
  local expression="$2"
  local invalid_host_output
  invalid_host_output="$(mktemp)"
  if nix eval --impure --expr "${expression}" >"${invalid_host_output}" 2>&1; then
    echo "invalid host must be rejected" >&2
    rm -f "${invalid_host_output}"
    exit 1
  fi
  if ! rg -q "${expected_error}" "${invalid_host_output}"; then
    echo "invalid host must identify its rejected configuration" >&2
    rm -f "${invalid_host_output}"
    exit 1
  fi
  rm -f "${invalid_host_output}"
}

check_invalid_host "nstdl standard storage is supported only for NixOS hosts" "
  let
    flake = builtins.getFlake \"path:${repo_dir}\";
  in
    (flake.inputs.flake-parts.lib.mkFlake { inputs = flake.inputs; } {
      imports = [ flake.flakeModules.default ];
      nstdl.hosts.invalid = {
        platform = \"darwin\";
        system = \"aarch64-darwin\";
        role = \"workstation\";
        systemStateVersion = 6;
        storage = { device = \"/dev/disk0\"; encryption = \"none\"; };
      };
    }).darwinConfigurations.invalid.config.system.primaryUser
"

check_invalid_host "nstdl static networking is supported only for NixOS hosts" "
  let
    flake = builtins.getFlake \"path:${repo_dir}\";
  in
    (flake.inputs.flake-parts.lib.mkFlake { inputs = flake.inputs; } {
      imports = [ flake.flakeModules.default ];
      nstdl.hosts.invalid = {
        platform = \"darwin\";
        system = \"aarch64-darwin\";
        role = \"workstation\";
        systemStateVersion = 6;
        network = { interface = \"en0\"; addresses = [ \"192.0.2.10/24\" ]; };
      };
    }).darwinConfigurations.invalid.config.system.primaryUser
"

check_invalid_host "must set deployment.targetHost" "
  let
    flake = builtins.getFlake \"path:${repo_dir}\";
  in
    (flake.inputs.flake-parts.lib.mkFlake { inputs = flake.inputs; } {
      imports = [ flake.flakeModules.default ];
      nstdl.hosts.invalid = {
        platform = \"nixos\";
        system = \"x86_64-linux\";
        role = \"server\";
        systemStateVersion = \"25.11\";
        deployment.enable = true;
      };
    }).nixosConfigurations.invalid.config.system.build.toplevel.drvPath
"

nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-proxmox-backup.config.system.build.toplevel.drvPath"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.services.nstdl-proxmox-backup-system.serviceConfig.LoadCredential"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.timers.nstdl-proxmox-backup-system.timerConfig"
nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-proxmox-backup.config.environment.systemPackages"

pbs_script="$(nix eval "${override[@]}" --apply 'builtins.unsafeDiscardStringContext' --raw "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.services.nstdl-proxmox-backup-system.script")"
pbs_credentials="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.services.nstdl-proxmox-backup-system.serviceConfig.LoadCredential")"
pbs_after="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.services.nstdl-proxmox-backup-system.after")"
pbs_defaulted_script="$(nix eval "${override[@]}" --apply 'builtins.unsafeDiscardStringContext' --raw "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.services.nstdl-proxmox-backup-defaulted.script")"
pbs_defaulted_user="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.services.nstdl-proxmox-backup-defaulted.serviceConfig.User")"
pbs_defaulted_group="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.services.nstdl-proxmox-backup-defaulted.serviceConfig.Group")"
pbs_defaulted_timer="$(nix eval "${override[@]}" --json "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.timers.nstdl-proxmox-backup-defaulted.timerConfig")"
pbs_system_user="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.services.nstdl-proxmox-backup-system.serviceConfig.User")"
pbs_system_group="$(nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-proxmox-backup.config.systemd.services.nstdl-proxmox-backup-system.serviceConfig.Group")"

[[ "${pbs_script}" == *"--keep-weekly=4"* && "${pbs_script}" != *"--keep-daily=7"* ]]
[[ "${pbs_script}" == *"--ns' 'servers"* && "${pbs_script}" == *"--exclude' '/nix/store"* && "${pbs_script}" == *"--change-detection-mode' 'metadata"* ]]
[[ "${pbs_credentials}" == *"/run/agenix/pbs-token"* && "${pbs_credentials}" != *"/nix/store/"* ]]
[[ "${pbs_after}" == *"network-online.target"* ]]
[[ "${pbs_defaulted_script}" == *"--ns' 'default-namespace"* && "${pbs_defaulted_script}" == *"--change-detection-mode' 'metadata"* && "${pbs_defaulted_script}" == *"--exclude' '/var/cache"* ]]
[[ "${pbs_defaulted_user}" == "root" && "${pbs_defaulted_group}" == "root" ]]
[[ "${pbs_system_user}" == "nobody" && "${pbs_system_group}" == "nogroup" ]]
[[ "${pbs_defaulted_timer}" == *'"OnCalendar":"hourly"'* && "${pbs_defaulted_timer}" == *'"Persistent":false'* ]]

pbs_wrapper_drv="$(nix eval "${override[@]}" --raw --apply '
  packages:
  (builtins.head (builtins.filter (package: package.name == "proxmox-backup-client-system") packages)).drvPath
' "${fixture}#nixosConfigurations.test-proxmox-backup.config.environment.systemPackages")"
nix build --no-link "${pbs_wrapper_drv}^out"
pbs_wrapper="$(nix-store -q --outputs "${pbs_wrapper_drv}")"
pbs_wrapper_test="$(mktemp)"
trap 'rm -f "${pbs_wrapper_test}"' EXIT
sed '/^exec .*systemd-run /c\printf "%s\\n" "$@"' "${pbs_wrapper}/bin/proxmox-backup-client-system" > "${pbs_wrapper_test}"
chmod +x "${pbs_wrapper_test}"

pbs_wrapper_default="$(${pbs_wrapper_test} backup root.pxar:/)"
pbs_wrapper_override="$(${pbs_wrapper_test} backup root.pxar:/ --ns=alternate --keyfd=3)"
pbs_wrapper_snapshot="$(${pbs_wrapper_test} snapshot upload-log)"
[[ "${pbs_wrapper_default}" == *$'--ns\nservers'* && "${pbs_wrapper_default}" == *$'--keyfile\n/run/agenix/pbs-key'* ]]
[[ "${pbs_wrapper_override}" != *"servers"* && "${pbs_wrapper_override}" != *"/run/agenix/pbs-key"* ]]
[[ "${pbs_wrapper_snapshot}" == *$'--ns\nservers'* && "${pbs_wrapper_snapshot}" == *$'--keyfile\n/run/agenix/pbs-key'* ]]
if "${pbs_wrapper_test}" garbage-collect; then
  echo "PBS wrappers must reject client-side garbage collection" >&2
  exit 1
fi

check_invalid_pbs_job() {
  local expected_error="$1"
  local job="$2"
  local invalid_pbs_output
  invalid_pbs_output="$(mktemp)"
  if nix eval --impure --expr "
    let
      flake = builtins.getFlake \"path:${repo_dir}\";
    in
    (flake.inputs.nixpkgs.lib.nixosSystem {
      system = \"x86_64-linux\";
      modules = [
        (import "${repo_dir}/modules/nixos/features/proxmox-backup.nix")
        {
          services.nstdl.proxmoxBackup = {
            enable = true;
            jobs.invalid = ${job};
          };
          boot.loader.grub = {
            enable = true;
            devices = [ \"nodev\" ];
          };
          fileSystems.\"/\" = {
            device = \"/dev/null\";
            fsType = \"ext4\";
          };
          system.stateVersion = \"25.11\";
        }
      ];
    }).config.system.build.toplevel.drvPath
  " >"${invalid_pbs_output}" 2>&1; then
    echo "invalid PBS client job must be rejected" >&2
    rm -f "${invalid_pbs_output}"
    exit 1
  fi
  if ! rg -q "${expected_error}" "${invalid_pbs_output}"; then
    echo "invalid PBS client job must identify its invariant" >&2
    rm -f "${invalid_pbs_output}"
    exit 1
  fi
  rm -f "${invalid_pbs_output}"
}

check_invalid_pbs_job "requires fingerprint" '{
  repository = "backup@pbs!fixture@pbs.example:store";
  passwordFile = "/run/agenix/pbs-token";
  archives.root = "/";
}'
check_invalid_pbs_job "must use an API-token auth ID" '{
  repository = "backup@pbs.example:store";
  passwordFile = "/run/agenix/pbs-token";
  fingerprint = "aa:bb:cc:dd";
  archives.root = "/";
}'
check_invalid_pbs_job "archive sources must be absolute runtime paths" '{
  repository = "backup@pbs!fixture@pbs.example:store";
  passwordFile = "/run/agenix/pbs-token";
  fingerprint = "aa:bb:cc:dd";
  archives.root = "relative";
}'
check_invalid_pbs_job "must set encryption.keyFile" '{
  repository = "backup@pbs!fixture@pbs.example:store";
  passwordFile = "/run/agenix/pbs-token";
  fingerprint = "aa:bb:cc:dd";
  archives.root = "/";
  encryption.cryptMode = "encrypt";
}'
nix eval "${override[@]}" --raw "${fixture}#darwinConfigurations.test-darwin.config.system.primaryUser"
nix eval "${override[@]}" --raw "${fixture}#darwinConfigurations.test-darwin.config.system.build.toplevel.drvPath"
nix eval "${override[@]}" --raw "${fixture}#darwinConfigurations.test-darwin.config.age.rekey.localStorageDir"
darwin_casks="$(nix eval "${override[@]}" --json --apply 'casks: builtins.map (cask: cask.name) casks' "${fixture}#darwinConfigurations.test-darwin.config.homebrew.casks")"
nix eval "${override[@]}" --json "${fixture}#darwinConfigurations.test-darwin.config.nix.gc.automatic"
darwin_podman_packages="$(nix eval "${override[@]}" --json --apply 'packages: builtins.map (package: package.name) packages' "${fixture}#darwinConfigurations.test-darwin.config.environment.systemPackages")"
darwin_sudo_extra_config="$(nix eval "${override[@]}" --raw "${fixture}#darwinConfigurations.test-darwin.config.security.sudo.extraConfig")"
darwin_qui_program="$(nix eval "${override[@]}" --json "${fixture}#darwinConfigurations.test-darwin.config.launchd.user.agents.qui.serviceConfig.ProgramArguments")"
darwin_qui_keepalive="$(nix eval "${override[@]}" --json "${fixture}#darwinConfigurations.test-darwin.config.launchd.user.agents.qui.serviceConfig.KeepAlive")"
darwin_home_packages="$(nix eval "${override[@]}" --json --apply 'packages: builtins.map (package: package.name) packages' "${fixture}#darwinConfigurations.test-darwin.config.home-manager.users.tester.home.packages")"
darwin_brews="$(nix eval "${override[@]}" --json --apply 'brews: builtins.map (brew: brew.name) brews' "${fixture}#darwinConfigurations.test-darwin.config.homebrew.brews")"
darwin_activation_script="$(nix eval "${override[@]}" --raw "${fixture}#darwinConfigurations.test-darwin.config.system.activationScripts.script.text")"
darwin_nushell_config="$(nix eval "${override[@]}" --raw "${fixture}#darwinConfigurations.test-darwin.config.home-manager.users.tester.programs.nushell.extraConfig")"
[[ "${darwin_casks}" == *'"signal"'* ]]
[[ "${darwin_home_packages}" == *'imagemagick-'* ]]
for cask in firefox@developer-edition keka keepassxc linearmouse rustdesk spotify visual-studio-code whatsapp; do
  [[ "${darwin_casks}" == *"\"${cask}\""* ]]
done
[[ "${darwin_podman_packages}" == *'"podman-'* && "${darwin_podman_packages}" == *'"podman-compose-'* && "${darwin_podman_packages}" == *'"sleepless-'* && "${darwin_sudo_extra_config}" == *'tester ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1'* && "${darwin_casks}" == *'"codex"'* && "${darwin_casks}" == *'"claude-code"'* && "${darwin_casks}" == *'"claude"'* && "${darwin_casks}" == *'"chatgpt"'* && "${darwin_casks}" == *'"discord"'* && "${darwin_home_packages}" != *'codex-'* && "${darwin_home_packages}" != *'claude-code-'* && "${darwin_brews}" == *'"batt"'* && "${darwin_activation_script}" == *'/etc/batt.json'* && "${darwin_activation_script}" == *'launchctl kickstart -k system/org.nixos.nstdl-batt'* && "${darwin_nushell_config}" == *'extern batt'* ]]
[[ "${darwin_qui_program}" == *'nstdl-qui-launcher'* && "${darwin_qui_keepalive}" == "true" ]]
nix eval "${override[@]}" --raw "${fixture}#homeConfigurations.test-standalone.config.home.username"
nix eval "${override[@]}" --raw "${fixture}#nixosConfigurations.test-workstation.config.home-manager.users.alice.home.username"
nix eval "${override[@]}" --json "${fixture}#homeConfigurations.test-standalone.config.programs.lazygit.enable"
nix eval "${override[@]}" --raw "${fixture}#packages.x86_64-linux.agenix-rekey.drvPath"
nix eval "${override[@]}" --raw "${fixture}#agenix-rekey.x86_64-linux.rekey.drvPath"

nix eval --impure --raw --expr "
  let
    flake = builtins.getFlake \"path:${repo_dir}\";
  in
  (flake.inputs.nixpkgs.lib.nixosSystem {
    system = \"x86_64-linux\";
    modules = [
      (import "${repo_dir}/modules/nixos/profiles/core.nix")
      (import "${repo_dir}/modules/nixos/profiles/server.nix")
      (import "${repo_dir}/modules/nixos/profiles/developer.nix")
      {
        nstdl.hostName = \"raw-server\";
        system.stateVersion = \"25.11\";
      }
    ];
  }).config.networking.hostName
"

nix eval --impure --raw --expr "
  let
    flake = builtins.getFlake \"path:${repo_dir}\";
    pkgs = import flake.inputs.nixpkgs {
      system = \"x86_64-linux\";
      config.allowUnfree = true;
    };
  in
  (flake.inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      flake.inputs.nix-index-database.homeModules.nix-index
      (import "${repo_dir}/modules/home-manager/profiles/developer.nix")
      {
        home.username = \"raw-user\";
        home.homeDirectory = \"/home/raw-user\";
        home.stateVersion = \"25.11\";
      }
    ];
  }).config.home.username
"

nix eval --impure --raw --expr "
  let
    flake = builtins.getFlake \"path:${repo_dir}\";
  in
  (flake.inputs.nix-darwin.lib.darwinSystem {
    system = \"aarch64-darwin\";
    modules = [
      (import "${repo_dir}/modules/darwin/profiles/core.nix")
      (import "${repo_dir}/modules/darwin/profiles/workstation.nix")
      (import "${repo_dir}/modules/darwin/profiles/developer.nix")
      {
        nstdl.hostName = \"raw-darwin\";
        nstdl.user.name = \"raw-user\";
        system.stateVersion = 6;
      }
    ];
  }).config.system.primaryUser
"

nix eval --override-input nstdl "path:${repo_dir}" --no-write-lock-file --raw "path:${repo_dir}/example#nixosConfigurations.demo-server.config.system.build.toplevel.drvPath"

stable_override=(
  --override-input nstdl "path:${repo_dir}"
  --override-input nstdl/nixpkgs github:NixOS/nixpkgs/nixos-26.05
  --override-input nstdl/home-manager github:nix-community/home-manager/release-26.05
  --no-write-lock-file
)
nix eval "${stable_override[@]}" --raw "${fixture}#homeConfigurations.test-standalone.config.home.activationPackage.drvPath"
stable_fzf_enabled="$(nix eval "${stable_override[@]}" --json "${fixture}#homeConfigurations.test-standalone.config.programs.fzf.enable")"
stable_nushell_enabled="$(nix eval "${stable_override[@]}" --json "${fixture}#homeConfigurations.test-standalone.config.programs.nushell.enable")"
stable_fzf_nushell_integration_present="$(nix eval "${stable_override[@]}" --json --apply 'fzf: fzf ? enableNushellIntegration' "${fixture}#homeConfigurations.test-standalone.config.programs.fzf")"
[[ "${stable_fzf_enabled}" == "true" && "${stable_nushell_enabled}" == "true" && "${stable_fzf_nushell_integration_present}" == "false" ]]

if nix eval --impure --expr "
  let
    flake = builtins.getFlake \"path:${repo_dir}\";
  in
  (flake.inputs.nixpkgs.lib.nixosSystem {
    system = \"x86_64-linux\";
    modules = [
      (import "${repo_dir}/modules/nixos/features/postgresql.nix")
      {
        services.nstdl.postgresql = {
          enable = true;
          roles.app.encrypted_password = \"test-only-not-a-secret\";
        };
        boot.loader.grub = {
          enable = true;
          devices = [ \"nodev\" ];
        };
        fileSystems.\"/\" = {
          device = \"/dev/null\";
          fsType = \"ext4\";
        };
        system.stateVersion = \"25.11\";
      }
    ];
  }).config.system.build.toplevel.drvPath
"; then
  echo "password-bearing PostgreSQL role options must be rejected" >&2
  exit 1
fi
