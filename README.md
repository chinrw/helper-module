# helper-module

NixOS modules whose source lives in private repositories, mirrored here so a
public configuration can import them without a GitHub token.

| Module | Option | Source |
|---|---|---|
| `nixosModules.stocks` | `services.stocks` | `nix/module.nix` in chinrw/stocks |

Do not edit `modules/` here. Change the module in its source repository: its
CI tests it there and overwrites the copy in this repository once main passes
every gate.

```nix
{
  inputs.helper-module.url = "github:chinrw/helper-module";
  # in a NixOS configuration:
  imports = [ inputs.helper-module.nixosModules.stocks ];
}
```
