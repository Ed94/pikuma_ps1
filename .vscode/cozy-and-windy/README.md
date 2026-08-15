# Cozy and Windy

Editor theme ported from the Rider scheme of the same name.

It colors the editor surface, C/C++ syntax, and tape-atom DSL keywords
emitted by `local.tape-atom-syntax`. It does not change workbench chrome.

## Install

```powershell
cd C:\projects\Pikuma\ps1\.vscode\cozy-and-windy
npm run package
code --install-extension .\cozy-and-windy-0.1.0.vsix --force
```

Reload the window. Select **Cozy and Windy** as the color theme, or set
`workbench.colorTheme` to `Cozy and Windy` in the PS1 workspace settings.

Keep `local.tape-atom-syntax` installed. This theme colors those token
types; it does not classify them.

## Inspect

Open `hello_camera.atom.c` and run **Developer: Inspect Editor Tokens and Scopes**
on `MipsAtom_`, an atom name, `atom_info`, `R_PrimCursor`, a `gte_*` call,
and a `mac_*` call.
