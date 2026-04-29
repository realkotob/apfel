# nixpkgs distribution

apfel ships on [nixpkgs](https://github.com/NixOS/nixpkgs) under the attribute `apfel-llm`. This page covers the install, the name choice, and how new versions land upstream.

## Install (end users)

```bash
nix profile install nixpkgs#apfel-llm
```

Runtime requirements are the same as Homebrew: macOS 26 Tahoe or later, Apple Silicon, Apple Intelligence enabled, Siri language matching device language.

The binary on your `$PATH` is still `apfel` - only the install-time attribute is `apfel-llm`.

## Why `apfel-llm` and not `apfel`

nixpkgs already has an unrelated package at [`pkgs/by-name/ap/apfel`](https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/ap/apfel/package.nix): the [scarrazza/apfel](https://github.com/scarrazza/apfel) particle-physics PDF Evolution Library (GPL3, maintained by `veprbl`). The name was taken years before apfel existed in its AI form, so nixpkgs convention requires disambiguation.

The disambiguator that landed upstream is `apfel-llm` (via [NixOS/nixpkgs#508084](https://github.com/NixOS/nixpkgs/pull/508084)). The binary on `$PATH` is still `apfel` either way - only the install attribute differs.

## Why a pre-built binary derivation

apfel links against Apple's [`FoundationModels`](https://developer.apple.com/documentation/foundationmodels) framework, which requires the macOS 26 SDK and Apple Silicon at build time. The nixpkgs darwin stdenv does not currently ship those prerequisites, so building from source inside a Nix sandbox is not reliably supported today.

The derivation installs the same signed release tarball that Homebrew consumes (`apfel-${version}-arm64-macos.tar.gz` attached to each GitHub Release), and declares `sourceProvenance = [ binaryNativeCode ]` to be honest about that.

If nixpkgs' darwin stdenv later gains macOS 26 SDK support, we switch to a source build in a follow-up PR.

## How new versions land

We do **not** run our own auto-bump workflow. The package.nix uses `passthru.updateScript = nix-update-script { }`, which feeds the standard nixpkgs update bots and contributor tooling. New apfel releases land in nixpkgs through one of:

1. **[`r-ryantm`](https://github.com/ryantm/nixpkgs-update)** - the official nixpkgs update bot. Scans packages weekly and opens bump PRs automatically. Latency: ~7 days.
2. **Community contributors** - anyone with a nixpkgs checkout can bump the version + hash. We have a regular contributor ([@arunoruto](https://github.com/arunoruto)) who has been doing this proactively.
3. **Manual self-bump** - if both above are slow and you need a fresh version, the workflow is below.

This matches the standard nixpkgs maintenance model: the package opts into automation, and human contributors fill the gaps. We tried adding our own release-triggered workflow but it required cross-org GitHub auth that fine-grained PATs cannot provide; the pragmatic right answer is to use the channels nixpkgs already has.

## Manual self-bump (if you ever need it)

On any machine with `nix` and `git`:

```bash
git clone --depth 1 https://github.com/NixOS/nixpkgs.git /tmp/nixpkgs-bump
cd /tmp/nixpkgs-bump

# Fork NixOS/nixpkgs to your account first via the GitHub UI, then:
git remote add fork git@github.com:YOUR_USER/nixpkgs.git

VERSION="X.Y.Z"   # e.g. 1.3.4
URL="https://github.com/Arthur-Ficial/apfel/releases/download/v${VERSION}/apfel-${VERSION}-arm64-macos.tar.gz"
HASH=$(nix-prefetch-url --type sha256 "$URL" | xargs nix-hash --to-sri --type sha256)

git checkout -b "apfel-llm-${VERSION}"
sed -i.bak -E "s/version = \"[^\"]+\"/version = \"${VERSION}\"/; s|hash = \"sha256-[^\"]+\"|hash = \"${HASH}\"|" \
  pkgs/by-name/ap/apfel-llm/package.nix
rm pkgs/by-name/ap/apfel-llm/package.nix.bak

git add pkgs/by-name/ap/apfel-llm/package.nix
git commit -m "apfel-llm: ${VERSION}"
git push fork "apfel-llm-${VERSION}"

gh pr create --repo NixOS/nixpkgs \
  --head "YOUR_USER:apfel-llm-${VERSION}" \
  --base master \
  --title "apfel-llm: ${VERSION}" \
  --body "Routine version bump."
```

## Testing the package locally

```bash
git clone --depth 1 https://github.com/NixOS/nixpkgs.git /tmp/nixpkgs-test
cd /tmp/nixpkgs-test
nix-build -A apfel-llm --no-out-link

ls /nix/store/*-apfel-llm-*/bin/apfel
```

Run it: `/nix/store/...-apfel-llm-.../bin/apfel --version`.

## Tracking

- Package source: <https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/ap/apfel-llm/package.nix>
- nixpkgs PRs: <https://github.com/NixOS/nixpkgs/pulls?q=is%3Apr+apfel-llm>
- r-ryantm PRs for apfel-llm: <https://github.com/NixOS/nixpkgs/pulls/r-ryantm?q=apfel-llm>
