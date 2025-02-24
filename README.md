# Biscuit [![CI-badge][CI-badge]][CI-url] [![Hackage][hackage]][hackage-url]

<img src="https://raw.githubusercontent.com/biscuit-auth/biscuit-haskell/main/assets/biscuit-logo.png" align=right>

This is the repository for a collection of haskell libraries providing support for the [Biscuit][biscuit] auth toolkit, created by [Geoffroy Couprie][gcouprie].

You will find below the main lib and its companions:

* [biscuit](./biscuit/) — Main library, providing minting and signature verification of biscuit tokens, as well as a datalog engine allowing to compute the validity of a token in a given context
* [biscuit-servant](./biscuit-servant) — Servant combinators, for a smooth integration in your API

## Supported biscuit versions

The core library supports [`v2` biscuits][v2spec] (both open and sealed).

[CI-badge]: https://img.shields.io/github/workflow/status/Divarvel/biscuit-haskell/CI?style=flat-square
[CI-url]: https://github.com/Divarvel/biscuit-haskell/actions
[Hackage]: https://img.shields.io/hackage/v/biscuit-haskell?color=purple&style=flat-square
[hackage-url]: https://hackage.haskell.org/package/biscuit-haskell
[gcouprie]: https://github.com/geal
[biscuit]: https://www.clever-cloud.com/blog/engineering/2021/04/12/introduction-to-biscuit/
[v2spec]: https://github.com/CleverCloud/biscuit/blob/2.0/SPECIFICATIONS.md
