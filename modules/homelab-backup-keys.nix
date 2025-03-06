{ pkgs, ... }:
{
  clan.core.vars.generators = {
    ssh-key-root = {
      share = true;
      files."id_ed25519".secret = true;
      files."id_ed25519.pub".secret = false;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.openssh
      ];
      script = ''
        ssh-keygen -t ed25519 -N "" -f "$out/id_ed25519"
      '';
    };

    #    ssh-key-root-public = {
    #      share = true;
    #      files."id_ed25519.pub".secret = false;
    #      dependencies = [ "ssh-key-root" ];
    #      runtimeInputs = [
    #        pkgs.coreutils
    #        pkgs.openssh
    #      ];
    #      script = ''
    #        ssh-keygen -y -f "$in/ssh-key-root/id_ed25519" > "$out/id_ed25519.pub"
    #      '';
    #    };
  };
}
