#!/usr/bin/env bash
# Build a ppy.osu.Game NuGet package from a ppy/osu channel tag.
#
# ppy/osu only publishes pure-numeric tags (e.g. 2026.730.0) to nuget.org; the
# `-lazer`/`-tachyon` channel tags never reach nuget.org (see ppy/osu
# .github/workflows/deploy.yml: `!*-*`). When a channel release needs a package
# version that nuget.org has not published, this script reproduces ppy's own
# `dotnet pack` command against the matching channel tag so the resulting
# package embeds that tag's CURRENT_RULESET_API_VERSION exactly.
#
# Usage: pack-osu-from-source.sh <bare_version> <channel> <output_dir>
#   bare_version : e.g. 2026.821.0 (without the -lazer/-tachyon suffix)
#   channel      : lazer | tachyon
#   output_dir   : absolute path to place ppy.osu.Game.<bare_version>.nupkg
set -euo pipefail

BARE_VER="${1:-}"
CHANNEL="${2:-}"
OUTPUT_DIR="${3:-}"
RUNNER_TEMP="${RUNNER_TEMP:-}"

if [[ ! "$CHANNEL" =~ ^(lazer|tachyon)$ ]] || [[ ! "$BARE_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ -z "$OUTPUT_DIR" ]] || [[ -z "$RUNNER_TEMP" ]]; then
  echo "::error::Usage: pack-osu-from-source.sh <YYYY.N.N> <lazer|tachyon> <output_dir>"
  echo "::error::RUNNER_TEMP must point to an isolated temporary directory."
  exit 1
fi

PPY_TAG="${BARE_VER}-${CHANNEL}"
echo "::group::Pack ppy.osu.Game ${BARE_VER} from ppy/osu tag ${PPY_TAG}"

mkdir -p "$OUTPUT_DIR"

# Shallow clone the exact channel tag. --depth 1 keeps it small; the tag carries
# the full source so `dotnet pack` (which restores PackageReference deps from
# nuget.org itself) needs no history.
clone_dir="$RUNNER_TEMP/ppy-osu-src"
rm -rf "$clone_dir"
echo "Cloning ppy/osu tag ${PPY_TAG}..."
git clone --depth 1 --branch "$PPY_TAG" https://github.com/ppy/osu.git "$clone_dir"

# Reproduce ppy/osu's own pack command (deploy.yml line 72). Only the Version
# property differs from a bare checkout; symbols/doc files are irrelevant for
# ruleset consumption and are omitted to keep the package lean.
echo "Packing osu.Game as ppy.osu.Game ${BARE_VER}..."
dotnet pack -c Release "$clone_dir/osu.Game/osu.Game.csproj" \
  /p:Version="$BARE_VER" \
  /p:GenerateDocumentationFile=false \
  -o "$OUTPUT_DIR"

NUPKG="$OUTPUT_DIR/ppy.osu.Game.${BARE_VER}.nupkg"
if [ ! -f "$NUPKG" ]; then
  echo "::error::Expected package $NUPKG was not produced."
  exit 1
fi

echo "::notice::Built $NUPKG from ppy/osu ${PPY_TAG}."
echo "::endgroup::"
