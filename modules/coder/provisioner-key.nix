# Shared Coder provisioner SSH keypair.
#
# Imported by both coder/server.nix (elserver) and coder/microvm-host.nix
# (offsite-backup) so the keypair is generated once and shared:
#
#   • The private key (secret) is deployed to both machines, owned by the
#     `coder` user. Only elserver actually uses it (the embedded terraform
#     provisioner reads it when SSHing to offsite-backup). offsite-backup
#     receives it but ignores it — the `coder` system user is created here on
#     both machines so the file owner resolves.
#
#   • The public key (non-secret, shared) is stored in the flake repo at
#     vars/shared/coder-provisioner-key/id_ed25519.pub/value, so its value is
#     readable at Nix eval time. microvm-host.nix adds it to offsite-backup's
#     root authorized_keys automatically — no manual copy-paste.
#
# Deploy order matters: deploy elserver first (generates the shared keypair),
# then offsite-backup (reads the public key value). Before the first
# generation `.exists` is false, so the authorized_keys list stays empty
# instead of throwing.
{ config, lib, pkgs, ... }:
{
  # System user/group needed on both machines: elserver runs the coder service
  # as `coder`; offsite-backup needs the user so the private key file's
  # `owner = "coder"` resolves during secret deployment. Harmless system user
  # with no login.
  users.groups.coder = { };
  users.users.coder = {
    isSystemUser = true;
    group = "coder";
    createHome = false;
  };

  clan.core.vars.generators.coder-provisioner-key = {
    share = true;
    files."id_ed25519" = {
      owner = "coder";
      # secret = true (default) — deployed as an encrypted secret.
    };
    files."id_ed25519.pub" = {
      secret = false; # public key — value accessible at eval time via .value
    };
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -t ed25519 -N "" -f "$out/id_ed25519" -C "coder-provisioner"
    '';
  };
}
