# Vendored DMG build dependencies

These Python modules are used only by `Scripts/create-dmg.sh` to write Finder's
`.DS_Store` metadata without launching Finder. They are not copied into the
Palmos app bundle or DMG.

- `ds_store` 1.3.1, from https://github.com/dmgbuild/ds_store
  - source archive SHA-256: `c27d413caf13c19acb85d75da4752673f1f38267f9eb6ba81b3b5aa99c2d207c`
- `mac_alias` 2.2.2, from https://github.com/dmgbuild/mac_alias
  - source archive SHA-256: `c99c728eb512e955c11f1a6203a0ffa8883b26549e8afe68804031aa5da856b7`

Only the runtime modules required to create `.DS_Store` files and Finder alias
records are vendored. Each package's upstream MIT license is preserved in its
directory.
