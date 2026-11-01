# services.stocks: runs the packages.stocks build that CI published on the
# deploy/production branch (scripts/publish-production.sh). A timer polls the
# branch, downloads a new store path from a binary cache the host already
# trusts, switches a nix-env profile and restarts the server. Nothing is built
# on the host. nix/README.md describes the deploy chain.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.stocks;
  inherit (lib) mkOption types;

  # The package the server runs, a nix-env profile and the updater's only
  # record of what is deployed. Every switch adds a generation beside it
  # (current-N-link). To roll back, first `systemctl stop stocks-update.timer
  # stocks-update.service`: that ends a run already in flight, and with the
  # timer stopped no tick switches back to the published package. Then pick
  # the generation with --list-generations, since that run may have added one.
  profile = "${cfg.stateDir}/current";
  # The backend requires the database's parent directory to be owned by the
  # service user and closed to everyone else.
  dataDir = "${cfg.stateDir}/data";
  # The pointer line ("<rev> <store path>") whose path the profile holds, for
  # calibration_snapshot.py. Informational: the updater never reads it.
  deployedStamp = "${cfg.stateDir}/deployed";
  # "<start|restart> <store path>", written before the profile switch and
  # carried out by the privileged ExecStopPost once the profile holds that
  # path. It survives a run that stops halfway or fails later, so the next
  # run finishes it.
  pendingRestart = "${cfg.stateDir}/restart-pending";
  # A bare repository that holds only the pointer branch.
  pointerRepo = "${cfg.stateDir}/pointer.git";

  # ssh-over-proxy has stalled after connect with no error and no timeout of
  # its own, which once wedged an updater for 3 days.
  gitSshCommand = lib.concatStringsSep " " [
    "ssh"
    "-i ${cfg.deployKeyFile}"
    "-o IdentitiesOnly=yes"
    "-o BatchMode=yes"
    "-o ConnectTimeout=15"
    "-o ServerAliveInterval=10"
    "-o ServerAliveCountMax=3"
  ];

  # Everything that needs the network happens here, never in stocks-server's
  # start, so an activation that restarts the host's resolver cannot fail on
  # it. Nothing is built: the path is downloaded or the run fails.
  updateScript = pkgs.writeShellApplication {
    name = "stocks-update";
    runtimeInputs = [
      pkgs.git
      pkgs.openssh
      pkgs.coreutils
      config.nix.package
    ];
    text = ''
      if [ ! -d ${pointerRepo} ]; then
        rm -rf ${pointerRepo}.partial
        git init --quiet --bare ${pointerRepo}.partial
        mv ${pointerRepo}.partial ${pointerRepo}
      fi
      if ! timeout --kill-after=10s 120s git -C ${pointerRepo} fetch --quiet --depth=1 \
        ${lib.escapeShellArg cfg.repository} "+refs/heads/${cfg.branch}:refs/heads/${cfg.branch}"; then
        echo "fetch failed or timed out - retrying on the next timer tick"
        exit 0
      fi

      line=$(git -C ${pointerRepo} show "refs/heads/${cfg.branch}:production")
      if [[ ! $line =~ ^[0-9a-f]{40}\ /nix/store/[0-9a-z]{32}-stocks$ ]]; then
        echo "unexpected pointer line: $line" >&2
        exit 1
      fi
      rev=''${line%% *}
      target=''${line#* }
      current=$(readlink -e ${profile} || true)
      pending=$(cat ${pendingRestart} 2>/dev/null || true)
      if [ "$target" = "$current" ]; then
        # A request for a package that was never switched to is stale.
        if [ -n "$pending" ] && [ "''${pending#* }" != "$current" ]; then
          rm -f ${pendingRestart}
        fi
        # A newer commit can publish the same package, e.g. a docs-only change.
        echo "$line" >${deployedStamp}
        echo "running the published package (''${rev:0:8})"
        exit 0
      fi

      echo "downloading ''${rev:0:8}: $target"
      # Rooted from the moment it is valid, so a GC cannot take it before the
      # profile switch below.
      nix-store --realise "$target" --add-root ${cfg.stateDir}/downloaded >/dev/null
      test -x "$target/bin/stocks-server"
      # Without a profile the server has never run a package: a first install
      # leaves it inactive. An unfinished start stays a start.
      action=restart
      if [ -z "$current" ] || [ "''${pending%% *}" = start ]; then
        action=start
      fi
      echo "$action $target" >${pendingRestart}
      nix-env --profile ${profile} --set "$target"
      nix-env --profile ${profile} --delete-generations +${toString cfg.keepGenerations}
      echo "$line" >${deployedStamp}
      echo "switched to ''${rev:0:8}, stocks-server $action requested"
    '';
  };

  # The updater runs as the service user, which cannot start a system unit, so
  # this privileged step carries out the request it left. It runs after failed
  # runs too, and acts only once the profile holds the requested path.
  # try-restart leaves a server that someone stopped on purpose stopped. A
  # first package uses restart, which starts an inactive server and also
  # reloads one that came up while an earlier request was failing.
  restartScript = pkgs.writeShellScript "stocks-restart-if-switched" ''
    set -eu
    request=$(${pkgs.coreutils}/bin/cat ${pendingRestart} 2>/dev/null || true)
    if [ -z "$request" ] \
      || [ "$(${pkgs.coreutils}/bin/readlink -e ${profile} || true)" != "''${request#* }" ]; then
      exit 0
    fi
    case "''${request%% *}" in
      start) ${pkgs.systemd}/bin/systemctl restart stocks-server.service ;;
      *) ${pkgs.systemd}/bin/systemctl try-restart stocks-server.service ;;
    esac
    ${pkgs.coreutils}/bin/rm -f ${pendingRestart}
  '';
in
{
  options.services.stocks = {
    enable = lib.mkEnableOption "the stocks server, deployed from the CI's deploy/production branch";

    user = mkOption {
      type = types.str;
      description = "Account the server and the updater run as. The AI CLIs use its logins.";
    };

    group = mkOption {
      type = types.str;
      default = config.users.users.${cfg.user}.group;
      defaultText = lib.literalExpression "config.users.users.\${user}.group";
      description = "Group of the state directory.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "${config.users.users.${cfg.user}.home}/stocks";
      defaultText = lib.literalExpression ''"''${home of user}/stocks"'';
      description = ''
        Holds the profile (current), the database and attachments (data/),
        and the updater's state. It must not be inside a directory others can
        write: the backend checks the database's ancestors. Keep its last
        component `stocks`: calibration_snapshot.py only accepts an instance
        ending in /stocks/current.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 5002;
      description = "Backend port on 127.0.0.1; put a reverse proxy in front of it.";
    };

    gatherPort = mkOption {
      type = types.port;
      default = 5106;
      description = "Port of the Python gather service on 127.0.0.1.";
    };

    allowedOrigins = mkOption {
      type = types.listOf types.str;
      description = ''
        Origins the reverse proxy serves, such as https://stocks.example.org.
        The backend answers 403 to any Host that is not loopback or one of these.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        ANALYZER_ENGINE = "claude_cli";
        PROXY = "http://127.0.0.1:10809";
      };
      description = "Further server settings that a checkout keeps in .env.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Secrets for the server, such as CLAUDE_CODE_OAUTH_TOKEN.";
    };

    path = mkOption {
      type = types.listOf (types.either types.package types.str);
      default = [ ];
      description = ''
        Added to the server's PATH. The backend's readiness probes run claude
        and codex from PATH and gather runs codex from it; the Claude SDK uses
        the CLI bundled in the package.
      '';
    };

    repository = mkOption {
      type = types.str;
      default = "git@github.com:chinrw/stocks.git";
      description = "Git URL the updater fetches the pointer branch from.";
    };

    branch = mkOption {
      type = types.str;
      default = "deploy/production";
      description = "Branch whose production file names the store path to run.";
    };

    deployKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "SSH key with read access to the repository, readable by the user.";
    };

    keepGenerations = mkOption {
      type = types.ints.positive;
      default = 5;
      description = "Profile generations kept for rollback.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 ${cfg.user} ${cfg.group} -"
      "d ${dataDir} 0700 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.stocks-server = {
      description = "Stock Analyzer server (CI-built packages.stocks)";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      # Skipped, not failed, until stocks-update has put a first package in
      # place; the updater then starts it.
      unitConfig.ConditionPathExists = profile;
      inherit (cfg) path;
      # The AI CLIs reach the model APIs through the host's proxy, if any.
      environment = config.networking.proxy.envVars // cfg.environment // {
        PORT = toString cfg.port;
        GATHER_PORT = toString cfg.gatherPort;
        # Echoed by /health; calibration_snapshot.py checks for this name.
        STOCKS_INSTANCE = profile;
        STOCKS_DB_PATH = "${dataDir}/stocks.db";
        STOCKS_ALLOWED_ORIGINS = lib.concatStringsSep "," cfg.allowedOrigins;
      };
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        ExecStart = "${profile}/bin/stocks-server";
        Restart = "on-failure";
        RestartSec = "30s";
      } // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    };

    systemd.services.stocks-update = {
      description = "Switch stocks to the package on its ${cfg.branch} branch";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = config.networking.proxy.envVars // lib.optionalAttrs (cfg.deployKeyFile != null) {
        GIT_SSH_COMMAND = gitSshCommand;
      };
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = lib.getExe updateScript;
        ExecStopPost = "+${restartScript}";
        # The first download is the whole closure, over a gigabyte.
        TimeoutStartSec = "30min";
      };
    };

    systemd.timers.stocks-update = {
      description = "Poll the stocks ${cfg.branch} branch";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Relative to the timer's own start, so the first run after a deploy
        # comes after the activation, not during it.
        OnActiveSec = "3min";
        OnUnitActiveSec = "5min";
        AccuracySec = "1min";
      };
    };
  };
}
