{ pkgs, browserPkgs, src }:
let
  environment = {
    PLAYWRIGHT_MODULE = "${browserPkgs.playwright-driver}/index.mjs";
    PLAYWRIGHT_BROWSERS_PATH = "${browserPkgs.playwright-driver.browsers-chromium}";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  };
  checker = pkgs.writeShellApplication {
    name = "browser-check";
    runtimeInputs = [ browserPkgs.nodejs ];
    runtimeEnv = environment;
    text = ''node ${src}/tools/browser-check.mjs ${src}'';
  };
  lifecycleChecker = pkgs.writeShellApplication {
    name = "lifecycle-browser-check";
    runtimeInputs = [ browserPkgs.nodejs ];
    runtimeEnv = environment;
    text = ''node ${src}/tools/lifecycle-browser-check.mjs ${src}'';
  };
in {
  inherit checker lifecycleChecker environment;
  apps.browser-check = { type = "app"; program = pkgs.lib.getExe checker; };
  apps.lifecycle-browser-check = { type = "app"; program = pkgs.lib.getExe lifecycleChecker; };
  check = pkgs.runCommand "singular-browser-check" {
    nativeBuildInputs = [ pkgs.glibcLocales ];
    LANG = "C.UTF-8";
    LC_ALL = "C.UTF-8";
  } ''
    ${pkgs.lib.getExe checker}
    ${pkgs.lib.getExe lifecycleChecker}
    touch "$out"
  '';
}
