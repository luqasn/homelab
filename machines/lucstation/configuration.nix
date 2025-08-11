{
  pkgs,
  lib,
  config,
  ...
}:
{
  imports = [

  ];

  # This is your user login name.
  users.users.user.name = "lucas";
  # Hostname
    networking.hostName = "lucstation";

    # Enabling the dr460nized desktop version
    # as well as the linux-cachyos kernel and gaming
    # options and applications
    garuda = {
      dr460nized.enable = true;
      gaming.enable = true;
      performance-tweaks = {
        cachyos-kernel = true;
        enable = true;
      };
    };

  # IMPORTANT! Add your SSH key here
  # e.g. > cat ~/.ssh/id_ed25519.pub
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOJLoEv6NFo+psb7VFAqeUv1PiIdFyvLGxPLT3+3uvzI luqasn@gmail.com"
  ];

  # New machine!
}
