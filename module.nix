# Direct traffic to a regular http server, possibly using HTTPS with an automatically-provisioned domain-verified SSL certificate
# To use this module, add it to your nixos configuration.nix like this:
# imports = [
#   (import ./path/to/this/file.nix {} {
#     backendPort = 8000;
#     sslConfig = {
#       hostName = "example.com";
#       adminEmail = "webmaster@example.com";
#       subdomains = [ "www" ];
#     };
#   })
# ];

{ }:
{ backendPort
  # The port (on localhost) where Nginx will get its content from - usually, your main http server
, sslConfig ? null
  # Either null or a record with:
  # hostName: a string with the root domain name at which the server will be hosted
  # adminEmail: The email address to report certificate issues to
  # subdomains: (optional) a list of subdomains that should be included in the SSL certificate
  # acmeWebRoot: (optional) the location from which to serve LetsEncrypt's challenges
}:
{ config, options, pkgs, ... }:
let sslConfig' = if sslConfig == null then null else {
      subdomains = []; #TODO(after 2017-02-01): Get wildcard certificates from LetsEncrypt: https://letsencrypt.org/2017/07/06/wildcard-certificates-coming-jan-2018.html
      acmeWebRoot = "/srv/acme/";
    } // sslConfig;

    inherit (pkgs.lib) concatStringsSep mapAttrs optional;
    plainInputPort = ''
      listen 80;
    '';
    sslInputPort = hostName: ''
      listen 443 ssl;
      ssl_certificate /var/lib/acme/${hostName}/fullchain.pem;
      ssl_certificate_key /var/lib/acme/${hostName}/key.pem;
      ssl_protocols  TLSv1 TLSv1.1 TLSv1.2;  # don't use SSLv3 ref: POODLE
    '';
    nginxService = { locations, inputPort }:
      let locationConfig = path: port: ''
            location ${path} {
              ${if path != "/" then "rewrite ^${path}(.*)$ /$1 break;" else ""}
              proxy_pass http://127.0.0.1:${builtins.toString port};
              proxy_set_header Host $http_host;
              proxy_read_timeout 300s;
              proxy_max_temp_file_size 4096m;
              client_max_body_size 1G;
            }
          '';
          locationConfigs = concatStringsSep "\n" (builtins.attrValues (mapAttrs locationConfig locations));
      in {
        enable = true;
        httpConfig = ''
          server {
            ${inputPort}
            ${locationConfigs}
            access_log off;
          }
          error_log  /var/log/nginx_error.log  warn;
        '';
      };

in {
  networking.firewall.allowedTCPPorts = [ 80 ];
  services.nginx = nginxService {
    locations = {
      "/" = backendPort;
    };
    inputPort = if sslConfig != null
      then sslInputPort sslConfig'.hostName
      else plainInputPort;
  };
} // (if sslConfig' != null then {
  networking.firewall.allowedTCPPorts = [ 443 ];
  services.lighttpd = {
    enable = true;
    document-root = sslConfig'.acmeWebRoot;
    port = 80;
    enableModules = [ "mod_redirect" ];
    extraConfig = ''
      $HTTP["url"] !~ "^/\.well-known/acme-challenge" {
        $HTTP["host"] =~ "^.*$" {
          url.redirect = ( "^.*$" => "https://%0$0" )
        }
      }
    '';
  };
  security.acme.certs.${sslConfig'.hostName} = {
    webroot = sslConfig'.acmeWebRoot;
    email = sslConfig'.adminEmail;
    plugins = [ "fullchain.pem" "key.pem" "account_key.json" ];
    postRun = ''
      systemctl reload-or-restart nginx.service
    '';
    extraDomains = builtins.listToAttrs (map (subdomain: { name = "${subdomain}.${sslConfig'.hostName}"; value = null; }) sslConfig'.subdomains);
  };
} else {})

