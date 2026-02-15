{
  lib,
  config,
  pkgs,
  ...
}:
# from https://github.com/jfly/snow/blob/af6d54a618b5ec5887220be88bd605515c7bc813/machines/fflewddur/home-assistant/mqtt.nix
let
  ports.mqtt = 1883;
  ports.mqtts = 8883;
  # After adding a user to the list, get their password with:
  # ```console
  # $ clan vars generate elserver && clan vars get elserver mqtt-[USERNAME]/password
  # ```
  mqttUsers = [
    "watermeter"
    "tasmota"
    "home-assistant"
    "esphome"
    "zigbee2mqtt"
  ];

  # Generate an attrset suitable for passing to `services.mosquitto.listeners.*.users`.
  # Like this:
  #
  # ```nix
  # {
  #   jfly.hashedPasswordFile = config.clan.core.vars.generators.mqtt-jfly.files."password.hashed".path;
  #   ...
  # };
  # ```
  mqttListenerUsers = lib.pipe mqttUsers [
    (map (
      userName:
      (lib.nameValuePair userName {
        hashedPasswordFile =
          config.clan.core.vars.generators."mqtt-${userName}".files."password.hashed".path;
      })
    ))
    lib.listToAttrs
  ];

  mqttPwGenerators = lib.pipe mqttUsers [
    (map (
      userName:
      (lib.nameValuePair "mqtt-${userName}" {
        files."password".deploy = lib.mkDefault false; # This may be overridden by other modules that need the password (for example, see <machines/fflewddur/home-assistant/zigbee2mqtt.nix>).
        files."password.hashed" = { };
        runtimeInputs = with pkgs; [
          coreutils
          gnused
          mosquitto
          xkcdpass
        ];
        script = ''
          # Generate a password.
          xkcdpass --numwords 4 --delimiter - | tr -d '\n' > $out/password

          # Generate a file of the form USERNAME:<hashedpw>.
          touch ./username-colon-hashedpw
          chmod 0700 ./username-colon-hashedpw
          mosquitto_passwd -b ./username-colon-hashedpw "USERNAME" $(< $out/password)

          # Extract just the hashedpw from the file and save that.
          sed 's/^USERNAME://' ./username-colon-hashedpw > $out/password.hashed
        '';
      })
    ))
    lib.listToAttrs
  ];
in
{
  # TODO: port HA to use MQTTS. I cannot get it to work. See
  # <https://github.com/home-assistant/core/issues/130643>
  clan.core.vars.generators = mqttPwGenerators;
  services.mosquitto = {
    enable = true;
    # logType = [ "all" ]; # debug
    listeners = [
      {
        port = ports.mqtt;
        # Allow all users all access. Ideally we'd have finer grained ACLs.
        acl = [ "pattern readwrite #" ];
        users = mqttListenerUsers;
      }
    ];
  };
  }