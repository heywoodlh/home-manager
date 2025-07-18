{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    any
    concatStringsSep
    concatMapStringsSep
    literalExpression
    mapAttrsToList
    mkIf
    mkOption
    optionalAttrs
    types
    ;

  cfg = config.programs.mbsync;

  # Accounts for which mbsync is enabled.
  mbsyncAccounts = lib.filter (a: a.mbsync.enable) (lib.attrValues config.accounts.email.accounts);

  # Given a SINGLE group's channels attribute set, return true if ANY of the channel's
  # patterns use the invalidOption attribute set value name.
  channelInvalidOption =
    channels: invalidOption: any (c: c) (mapAttrsToList (c: lib.hasAttr invalidOption) channels);

  # Given a SINGLE account's groups attribute set, return true if ANY of the account's group's channel's patterns use the invalidOption attribute set value name.
  groupInvalidOption =
    groups: invalidOption:
    any (g: g) (
      mapAttrsToList (groupName: groupVals: channelInvalidOption groupVals.channels invalidOption) groups
    );

  # Given all accounts (ensure that accounts passed in here ARE mbsync-using accounts)
  # return true if ANY of the account's groups' channels' patterns use the
  # invalidOption attribute set value name.
  accountInvalidOption =
    accounts: invalidOption:
    any (a: a) (map (account: groupInvalidOption account.mbsync.groups invalidOption) mbsyncAccounts);

  genTlsConfig =
    tls:
    {
      TLSType =
        if !tls.enable then
          "None"
        else if tls.useStartTls then
          "STARTTLS"
        else
          "IMAPS";
    }
    // lib.optionalAttrs (tls.enable && tls.certificatesFile != null) {
      CertificateFile = toString tls.certificatesFile;
    };

  nearFarMapping = {
    none = "None";
    imap = "Far";
    maildir = "Near";
    both = "Both";
  };

  genSection =
    header: entries:
    let
      escapeValue = lib.escape [ ''"'' ];
      hasSpace = v: builtins.match ".* .*" v != null;
      genValue =
        n: v:
        if lib.isList v then
          concatMapStringsSep " " (genValue n) v
        else if lib.isBool v then
          lib.hm.booleans.yesNo v
        else if lib.isInt v then
          toString v
        else if lib.isString v && hasSpace v then
          ''"${escapeValue v}"''
        else if lib.isString v then
          v
        else
          let
            prettyV = lib.generators.toPretty { } v;
          in
          throw "mbsync: unexpected value for option ${n}: '${prettyV}'";
    in
    ''
      ${header}
      ${concatStringsSep "\n" (mapAttrsToList (n: v: "${n} ${genValue n v}") entries)}
    '';

  genAccountConfig =
    account:
    let
      inherit (account)
        name
        maildir
        imap
        mbsync
        passwordCommand
        userName
        ;
    in
    genSection "IMAPAccount ${name}" (
      {
        Host = imap.host;
        User = userName;
        PassCmd = toString passwordCommand;
      }
      // genTlsConfig imap.tls
      // optionalAttrs (imap.port != null) { Port = toString imap.port; }
      // mbsync.extraConfig.account
    )
    + "\n"
    + genSection "IMAPStore ${name}-remote" ({ Account = name; } // mbsync.extraConfig.remote)
    + "\n"
    + genSection "MaildirStore ${name}-local" (
      {
        Inbox = "${maildir.absPath}/${account.folders.inbox}";
      }
      // optionalAttrs (mbsync.subFolders != "Maildir++" || mbsync.flatten != null) {
        Path = "${maildir.absPath}/";
      }
      // optionalAttrs (mbsync.flatten == null) {
        SubFolders = mbsync.subFolders;
      }
      // optionalAttrs (mbsync.flatten != null) { Flatten = mbsync.flatten; }
      // mbsync.extraConfig.local
    )
    + "\n"
    + genChannels account;

  genChannels =
    account:
    let
      inherit (account) name mbsync;
    in
    if mbsync.groups == { } then
      genAccountWideChannel account
    else
      genGroupChannelConfig name mbsync.groups + "\n" + genAccountGroups mbsync.groups;

  # Used when no channels are specified for this account. This will create a
  # single channel for the entire account that is then further refined within
  # the Group for synchronization.
  genAccountWideChannel =
    account:
    let
      inherit (account) name mbsync;
    in
    genSection "Channel ${name}" (
      {
        Far = ":${name}-remote:";
        Near = ":${name}-local:";
        Patterns = mbsync.patterns;
        Create = nearFarMapping.${mbsync.create};
        Remove = nearFarMapping.${mbsync.remove};
        Expunge = nearFarMapping.${mbsync.expunge};
        SyncState = "*";
      }
      // mbsync.extraConfig.channel
    )
    + "\n";

  # Given the attr set of groups, return a string of channels that will direct
  # mail to the proper directories, according to the pattern used in channel's
  # "far" pattern definition.
  genGroupChannelConfig =
    storeName: groups:
    let
      # Given the name of the group this channel is part of and the channel
      # itself, generate the string for the desired configuration.
      genChannelString =
        groupName: channel:
        let
          escapeValue = lib.escape [ ''\"'' ];
          hasSpace = v: builtins.match ".* .*" v != null;
          # Given a list of patterns, will return the string requested.
          # Only prints if the pattern is NOT the empty list, the default.
          genChannelPatterns =
            patterns:
            if (lib.length patterns) != 0 then
              "Pattern "
              + concatStringsSep " " (map (pat: if hasSpace pat then escapeValue pat else pat) patterns)
              + "\n"
            else
              "";
        in
        genSection "Channel ${groupName}-${channel.name}" (
          {
            Far = ":${storeName}-remote:${channel.farPattern}";
            Near = ":${storeName}-local:${channel.nearPattern}";
          }
          // channel.extraConfig
        )
        + genChannelPatterns channel.patterns;
      # Given the group name, and a attr set of channels within that group,
      # Generate a list of strings for each channels' configuration.
      genChannelStrings =
        groupName: channels:
        lib.optionals (channels != { }) (
          mapAttrsToList (channelName: info: genChannelString groupName info) channels
        );
      # Given a group, return a string that configures all the channels within
      # the group.
      genGroupsChannels = group: concatStringsSep "\n" (genChannelStrings group.name group.channels);
      # Generate all channel configurations for all groups for this account.
    in
    concatStringsSep "\n" (
      lib.remove "" (mapAttrsToList (name: group: genGroupsChannels group) groups)
    );

  # Given the attr set of groups, return a string which maps channels to groups
  genAccountGroups =
    groups:
    let
      # Given the name of the group and the attribute set of channels, make
      # make "Channel <grpName>-<chnName>" for each channel to list os strings
      genChannelStrings =
        groupName: channels: mapAttrsToList (name: info: "Channel ${groupName}-${name}") channels;
      # Take in 1 group, if the group has channels specified, construct the
      # "Group <grpName>" header and each of the channels.
      genGroupChannelString =
        group:
        lib.flatten (
          lib.optionals (group.channels != { }) (
            [ "Group ${group.name}" ] ++ (genChannelStrings group.name group.channels)
          )
        );
      # Given set of groups, generates list of strings, where each string is one
      # of the groups and its constituent channels.
      genGroupsStrings = mapAttrsToList (
        name: info: concatStringsSep "\n" (genGroupChannelString groups.${name})
      ) groups;
      # Join all non-empty groups.
      combined = concatStringsSep "\n\n" (lib.remove "" genGroupsStrings) + "\n";
    in
    combined;

  genGroupConfig =
    name: channels:
    let
      genGroupChannel = n: boxes: "Channel ${n}:${concatStringsSep "," boxes}";
    in
    "\n" + concatStringsSep "\n" ([ "Group ${name}" ] ++ mapAttrsToList genGroupChannel channels);

in
{
  meta.maintainers = [ lib.maintainers.KarlJoad ];

  options = {
    programs.mbsync = {
      enable = lib.mkEnableOption "mbsync IMAP4 and Maildir mailbox synchronizer";

      package = lib.mkPackageOption pkgs "isync" { };

      groups = mkOption {
        type = types.attrsOf (types.attrsOf (types.listOf types.str));
        default = { };
        example = literalExpression ''
          {
            inboxes = {
              account1 = [ "Inbox" ];
              account2 = [ "Inbox" ];
            };
          }
        '';
        description = ''
          Definition of groups.
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Extra configuration lines to add to the mbsync configuration.
        '';
      };
    };

    accounts.email.accounts = mkOption {
      type = with types; attrsOf (submodule (import ./accounts.nix));
    };
  };

  config = mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions =
          let
            checkAccounts =
              pred: msg:
              let
                badAccounts = lib.filter pred mbsyncAccounts;
              in
              {
                assertion = badAccounts == [ ];
                message = "mbsync: ${msg} for accounts: " + concatMapStringsSep ", " (a: a.name) badAccounts;
              };
          in
          [
            (checkAccounts (a: a.maildir == null) "Missing maildir configuration")
            (checkAccounts (a: a.imap == null) "Missing IMAP configuration")
            (checkAccounts (a: a.passwordCommand == null) "Missing passwordCommand")
            (checkAccounts (a: a.userName == null) "Missing username")
          ];
      }

      (mkIf (accountInvalidOption mbsyncAccounts "masterPattern") {
        warnings = [
          "mbsync channels no longer use masterPattern. Use farPattern in its place."
        ];
      })

      (mkIf (accountInvalidOption mbsyncAccounts "slavePattern") {
        warnings = [
          "mbsync channels no longer use slavePattern. Use nearPattern in its place."
        ];
      })

      {
        home.packages = [ cfg.package ];

        programs.notmuch.new.ignore = [
          ".uidvalidity"
          ".mbsyncstate"
        ];

        xdg.configFile."isyncrc".text =
          let
            accountsConfig = map genAccountConfig mbsyncAccounts;
            # Only generate this kind of Group configuration if there are ANY accounts
            # that do NOT have a per-account groups/channels option(s) specified.
            groupsConfig =
              if any (account: account.mbsync.groups == { }) mbsyncAccounts then
                mapAttrsToList genGroupConfig cfg.groups
              else
                [ ];
          in
          ''
            # Generated by Home Manager.

          ''
          + concatStringsSep "\n" (lib.optional (cfg.extraConfig != "") cfg.extraConfig)
          + concatStringsSep "\n\n" accountsConfig
          + concatStringsSep "\n" groupsConfig;

        home.activation = mkIf (mbsyncAccounts != [ ]) {
          createMaildir = lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
            run mkdir -m700 -p $VERBOSE_ARG ${
              concatMapStringsSep " " (a: lib.escapeShellArg a.maildir.absPath) mbsyncAccounts
            }
          '';
        };
      }
    ]
  );
}
