{ pkgs, config, lib, self, ... }:

let
  projectName = name:
    if config.name == null
    then throw ''You need to set `name = "myproject";` or `containers.${name}.name = "mycontainer"; to be able to generate a container.''
    else config.name;
  types = lib.types;
  envContainerName = builtins.getEnv "DEVENV_CONTAINER";

  nix2containerInput = config.lib.getInput {
    name = "nix2container";
    url = "github:nlewo/nix2container";
    attribute = "containers";
    follows = [ "nixpkgs" ];
  };
  nix2container = nix2containerInput.packages.${pkgs.stdenv.system};
  mk-shell-bin = config.lib.getInput {
    name = "mk-shell-bin";
    url = "github:rrbutani/nix-mk-shell-bin";
    attribute = "containers";
  };
  shell = mk-shell-bin.lib.mkShellBin { drv = config.shell; nixpkgs = pkgs; };
  bash = "${pkgs.bashInteractive}/bin/bash";
  mkEntrypoint = cfg: pkgs.writeScript "entrypoint" ''
    #!${bash}

    export PATH=/bin

    source ${shell.envScript}

    exec "$@"
  '';
  user = "user";
  group = "user";
  uid = "1000";
  gid = "1000";
  homeDir = "/env";

  mkHome = path: (pkgs.runCommand "devenv-container-home" { } ''
    mkdir -p $out${homeDir}
    cp -R ${path}/. $out${homeDir}/
  '');

  mkMultiHome = paths: map mkHome paths;

  homeRoots = cfg: (
    if (builtins.typeOf cfg.copyToRoot == "list")
    then cfg.copyToRoot
    else [ cfg.copyToRoot ]
  );

  mkTmp = (pkgs.runCommand "devenv-container-tmp" { } ''
    mkdir -p $out/tmp
  '');

  mkEtc = (pkgs.runCommand "devenv-container-etc" { } ''
    mkdir -p $out/etc/pam.d

    echo "root:x:0:0:System administrator:/root:${bash}" > \
          $out/etc/passwd
    echo "${user}:x:${uid}:${gid}::${homeDir}:${bash}" >> \
          $out/etc/passwd

    echo "root:!x:::::::" > $out/etc/shadow
    echo "${user}:!x:::::::" >> $out/etc/shadow

    echo "root:x:0:" > $out/etc/group
    echo "${group}:x:${gid}:" >> $out/etc/group

    cat > $out/etc/pam.d/other <<EOF
    account sufficient pam_unix.so
    auth sufficient pam_rootok.so
    password requisite pam_unix.so nullok sha512
    session required pam_unix.so
    EOF

    touch $out/etc/login.defs
  '');

  mkPerm = derivation:
    {
      path = derivation;
      mode = "0744";
      uid = lib.toInt uid;
      gid = lib.toInt gid;
      uname = user;
      gname = group;
    };


  mkDerivation = cfg: nix2container.nix2container.buildImage {
    name = cfg.name;
    tag = cfg.version;
    initializeNixDatabase = true;
    nixUid = lib.toInt uid;
    nixGid = lib.toInt gid;

    copyToRoot = [
      (pkgs.buildEnv {
        name = "devenv-container-root";
        paths = [
          pkgs.coreutils-full
          pkgs.bashInteractive
          pkgs.su
          pkgs.sudo
          pkgs.dockerTools.usrBinEnv
        ];
        pathsToLink = [ "/bin" "/usr/bin" ];
      })
      mkEtc
      mkTmp
    ];

    maxLayers = cfg.maxLayers;

    layers =
      if cfg.enableLayerDeduplication
      then
        builtins.foldl'
          (layers: layer:
            layers ++ [
              (nix2container.nix2container.buildLayer (layer // { inherit layers; }))
            ]
          )
          [ ]
          cfg.layers
      else builtins.map (layer: nix2container.nix2container.buildLayer layer) cfg.layers
    ;

    perms = [
      {
        path = mkTmp;
        regex = "/tmp";
        mode = "1777";
        uid = 0;
        gid = 0;
        uname = "root";
        gname = "root";
      }
    ];

    config = {
      Entrypoint = cfg.entrypoint;
      User = "${user}";
      WorkingDir = "${homeDir}";
      Env = lib.mapAttrsToList
        (name: value:
          "${name}=${toString value}"
        )
        config.env ++ [ "HOME=${homeDir}" "USER=${user}" ];
      Cmd = [ cfg.startupCommand ];
    };
  };

  # <registry> <args>
  mkCopyScript = cfg: pkgs.writeShellScript "copy-container" ''
    set -e -o pipefail

    container=$1
    shift

    if [[ "$1" == false ]]; then
      registry=${cfg.registry}
    else
      registry="$1"
    fi
    shift

    dest="''${registry}${cfg.name}:${cfg.version}"

    if [[ $# == 0 ]]; then
      args=(${if cfg.defaultCopyArgs == [] then "" else toString cfg.defaultCopyArgs})
    else
      args=("$@")
    fi

    echo
    echo "Copying container $container to $dest"
    echo

    ${nix2container.skopeo-nix2container}/bin/skopeo --insecure-policy copy "nix:$container" "$dest" ''${args[@]}
  '';
  containerOptions = types.submodule ({ name, config, ... }: {
    options = {
      name = lib.mkOption {
        type = types.nullOr types.str;
        description = "Name of the container.";
        defaultText = "top-level name or containers.mycontainer.name";
        default = "${projectName name}-${name}";
      };

      version = lib.mkOption {
        type = types.nullOr types.str;
        description = "Version/tag of the container.";
        default = "latest";
      };

      copyToRoot = lib.mkOption {
        type = types.either types.path (types.listOf types.path);
        description = "Add a path to the container. Defaults to the whole git repo.";
        default = self;
        defaultText = lib.literalExpression "self";
      };

      startupCommand = lib.mkOption {
        type = types.nullOr (types.either types.str types.package);
        description = "Command to run in the container.";
        default = null;
      };

      entrypoint = lib.mkOption {
        type = types.listOf types.anything;
        description = "Entrypoint of the container.";
        default = [ (mkEntrypoint config) ];
        defaultText = lib.literalExpression "[ entrypoint ]";
      };

      defaultCopyArgs = lib.mkOption {
        type = types.listOf types.str;
        description =
          ''
            Default arguments to pass to `skopeo copy`.
            You can override them by passing arguments to the script.
          '';
        default = [ ];
      };

      registry = lib.mkOption {
        type = types.nullOr types.str;
        description = "Registry to push the container to.";
        default = "docker-daemon:";
      };

      maxLayers = lib.mkOption {
        type = types.nullOr types.int;
        description = "Maximum number of container layers created.";
        default = 1;
      };

      enableLayerDeduplication = (lib.mkEnableOption ''
        layer deduplication using the approach described at https://blog.eigenvalue.net/2023-nix2container-everything-once/
      '') // { default = true; };

      layers = lib.mkOption {
        type = types.listOf (types.submoduleWith {
          modules = [
            {
              options = {
                deps = lib.mkOption {
                  type = types.listOf types.package;
                  description = "A list of store paths to include in the layer.";
                  default = [ ];
                };
                copyToRoot = lib.mkOption {
                  type = types.listOf types.package;
                  description = ''
                    A list of derivations copied to the image root directory.

                    Store path prefixes ``/nix/store/hash-path`` are removed in order to relocate them to the image ``/``.
                  '';
                  default = [ ];
                };
                reproducible = lib.mkOption {
                  type = types.bool;
                  description = "Whether the layer should be reproducible.";
                  default = true;
                };
                maxLayers = lib.mkOption {
                  type = types.int;
                  description = "The maximum number of layers to create.";
                  default = 1;
                };
                perms = lib.mkOption {
                  description = ''
                    A list of file permissions which are set when the tar layer is created.

                    These permissions are not written to the Nix store.
                  '';
                  default = [ ];
                  type = types.listOf (types.submoduleWith {
                    modules = [
                      {
                        options = {
                          path = lib.mkOption {
                            type = types.pathInStore;
                            description = "A store path.";
                          };
                          regex = lib.mkOption {
                            type = types.nullOr types.str;
                            description = "A regex pattern to select files or directories to apply the ``mode`` to.";
                            example = ".*";
                            default = null;
                          };
                          mode = lib.mkOption {
                            type = types.nullOr types.str;
                            description = "The numeric permissions mode to apply to all of the files matched by the ``regex``.";
                            example = "644";
                            default = null;
                          };
                          gid = lib.mkOption {
                            type = types.nullOr types.int;
                            description = "The group ID to apply to all of the files matched by the ``regex``.";
                            example = "1000";
                            default = null;
                          };
                          uid = lib.mkOption {
                            type = types.nullOr types.int;
                            description = "The user ID to apply to all of the files matched by the ``regex``.";
                            example = "1000";
                            default = null;
                          };
                          uname = lib.mkOption {
                            type = types.nullOr types.str;
                            description = "The user name to apply to all of the files matched by the ``regex``.";
                            example = "root";
                            default = null;
                          };
                          gname = lib.mkOption {
                            type = types.nullOr types.str;
                            description = "The group name to apply to all of the files matched by the ``regex``.";
                            example = "root";
                            default = null;
                          };
                        };
                      }
                    ];
                  });
                };
                ignore = lib.mkOption {
                  type = types.nullOr types.pathInStore;
                  default = null;
                  description = ''
                    A store path to ignore when building the layer. This is mainly useful to ignore the configuration file from the container layer.
                  '';
                };
              };
            }
          ];
        });
        description = "The layers to create.";
        default = [ ];
      };

      isBuilding = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Set to true when the environment is building this container.";
      };

      derivation = lib.mkOption {
        type = types.package;
        internal = true;
        default = mkDerivation config;
      };

      copyScript = lib.mkOption {
        type = types.package;
        internal = true;
        default = mkCopyScript config;
      };

      dockerRun = lib.mkOption {
        type = types.package;
        internal = true;
        default = pkgs.writeShellScript "docker-run" ''
          docker run -it ${config.name}:${config.version} "$@"
        '';
      };
    };

    config.layers = [
      {
        perms = map mkPerm (mkMultiHome (homeRoots config));
        copyToRoot = mkMultiHome (homeRoots config);
      }
    ];
  });
in
{
  options = {
    containers = lib.mkOption {
      type = types.attrsOf containerOptions;
      default = { };
      description = "Container specifications that can be built, copied and ran using `devenv container`.";
    };

    container = {
      isBuilding = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Set to true when the environment is building a container.";
      };
    };
  };

  config = lib.mkMerge [
    {
      container.isBuilding = envContainerName != "";

      containers.shell = {
        name = lib.mkDefault "shell";
        startupCommand = lib.mkDefault bash;
      };

      containers.processes = {
        name = lib.mkDefault "processes";
        startupCommand = lib.mkDefault config.procfileScript;
      };
    }
    (if envContainerName == "" then { } else {
      containers.${envContainerName}.isBuilding = true;
    })
    (lib.mkIf config.container.isBuilding {
      devenv.tmpdir = lib.mkOverride (lib.modules.defaultOverridePriority - 1) "/tmp";
      devenv.runtime = lib.mkOverride (lib.modules.defaultOverridePriority - 1) "${config.devenv.tmpdir}/devenv";
      devenv.root = lib.mkForce "${homeDir}";
      devenv.dotfile = lib.mkOverride 49 "${homeDir}/.devenv";
    })
  ];
}
