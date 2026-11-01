{
  description = "NixOS modules mirrored from private repositories";

  outputs = _: {
    # services.stocks. CI in chinrw/stocks overwrites modules/stocks.nix with
    # that repository's nix/module.nix after every gated main push.
    nixosModules.stocks = import ./modules/stocks.nix;
  };
}
