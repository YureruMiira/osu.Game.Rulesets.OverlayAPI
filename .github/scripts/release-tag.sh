#!/usr/bin/env bash
# Build the plugin for an existing tag and publish its GitHub Release.
set -euo pipefail

TAG="${1:-}"
PROJECT="osu.Game.Rulesets.OverlayAPI/osu.Game.Rulesets.OverlayAPI.csproj"
REPLACE_EXISTING="${REPLACE_EXISTING:-false}"

if [ -z "$TAG" ]; then
  echo "::error::Usage: release-tag.sh <tag>"
  exit 1
fi

if [[ ! "$REPLACE_EXISTING" =~ ^(true|false)$ ]]; then
  echo "::error::REPLACE_EXISTING must be 'true' or 'false'."
  exit 1
fi

case "$TAG" in
  v[0-9]*-lazer.[0-9]*.[0-9]*.[0-9]*)
    CHANNEL="lazer"
    PRERELEASE=false
    OSU_VER="${TAG#v*-lazer.}"
    TITLE="OverlayAPI ${TAG} — osu! lazer ${OSU_VER}"
    SUMMARY="Automatically synchronized for the osu! lazer channel."
    ;;
  v[0-9]*-tachyon.[0-9]*.[0-9]*.[0-9]*)
    CHANNEL="tachyon"
    PRERELEASE=false
    OSU_VER="${TAG#v*-tachyon.}"
    TITLE="OverlayAPI ${TAG} — osu! tachyon ${OSU_VER}"
    SUMMARY="Automatically synchronized for the osu! tachyon channel."
    ;;
  v[0-9]*-a | v[0-9]*-a.[0-9]*)
    CHANNEL="manual"
    PRERELEASE=true
    TITLE="OverlayAPI ${TAG} — manual enhancement"
    OSU_VER="N/A (manual code baseline)"
    SUMMARY="Manual enhancement pre-release baseline. Successful publication automatically starts lazer and tachyon channel synchronization."
    ;;
  *)
    echo "::error::Unsupported release tag '$TAG'. Use a lazer, tachyon, -a, or -a.N tag."
    exit 1
    ;;
esac

PROJECT_NUGET_VER="$(sed -n 's/.*<PpyOsuGameVersion>\([^<]*\)<\/PpyOsuGameVersion>.*/\1/p' "$PROJECT" | head -1)"
if [ -z "$PROJECT_NUGET_VER" ]; then
  PROJECT_NUGET_VER="$(sed -n 's/.*<PackageReference *Include="ppy\.osu\.Game" *Version="\([^"]*\)".*/\1/p' "$PROJECT" | head -1)"
fi
PROJECT_SOURCE_CHANNEL="$(sed -n 's/.*<PpyOsuGameSourceChannel>\([^<]*\)<\/PpyOsuGameSourceChannel>.*/\1/p' "$PROJECT" | head -1)"
PROJECT_SOURCE_CHANNEL="${PROJECT_SOURCE_CHANNEL:-nuget}"

if [[ ! "$PROJECT_NUGET_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Could not read a valid ppy.osu.Game version from $PROJECT."
  exit 1
fi

# A channel tag's osu! version is the build contract. This deliberately
# overrides stale dependency metadata in historical tags, allowing a bad asset
# to be repaired without moving or rewriting the immutable Git tag.
if [ "$CHANNEL" = "manual" ]; then
  NUGET_VER="$PROJECT_NUGET_VER"
  SOURCE_CHANNEL="$PROJECT_SOURCE_CHANNEL"
else
  NUGET_VER="$OSU_VER"
  SOURCE_CHANNEL="$CHANNEL"
fi

RELEASE_EXISTS=false
if gh release view "$TAG" >/dev/null 2>&1; then
  RELEASE_EXISTS=true
  if [ "$REPLACE_EXISTING" != true ]; then
    echo "GitHub Release $TAG already exists — nothing to publish. Set REPLACE_EXISTING=true to rebuild and replace its asset."
    exit 0
  fi
  echo "::notice::GitHub Release $TAG exists; rebuilding and replacing its asset."
fi

# Download the exact package before restoring so its target framework can drive
# the build. Historical release tags may target net8.0 even when the matching
# osu! channel has moved to net10.0.
LOCAL_NUGET_DIR="$RUNNER_TEMP/local-nuget"
mkdir -p "$LOCAL_NUGET_DIR"
PACKAGE_FILE="$LOCAL_NUGET_DIR/ppy.osu.game.${NUGET_VER}.nupkg"
PACKAGE_STATUS="$(curl --silent --show-error --location --retry 3 \
  --connect-timeout 10 --max-time 60 --write-out '%{http_code}' \
  "https://api.nuget.org/v3-flatcontainer/ppy.osu.game/${NUGET_VER}/ppy.osu.game.${NUGET_VER}.nupkg" \
  --output "$PACKAGE_FILE")" || {
  echo "::error::Could not download ppy.osu.Game $NUGET_VER from nuget.org."
  exit 1
}

if [ "$PACKAGE_STATUS" = 404 ]; then
  rm -f "$PACKAGE_FILE"
  # Use the channel recorded in the project for manual tags whose dependency
  # came from source. Channel tags derive it from their own tag name.
  case "$SOURCE_CHANNEL" in
    lazer|tachyon)
      echo "::notice::ppy.osu.Game $NUGET_VER is not on nuget.org; packing from ppy/osu tag ${NUGET_VER}-${SOURCE_CHANNEL}."
      PACK_HELPER="${PACK_OSU_FROM_SOURCE_SCRIPT:-$(dirname "$0")/pack-osu-from-source.sh}"
      bash "$PACK_HELPER" "$NUGET_VER" "$SOURCE_CHANNEL" "$LOCAL_NUGET_DIR"
      PACKAGE_FILE="$LOCAL_NUGET_DIR/ppy.osu.Game.${NUGET_VER}.nupkg"
      ;;
    *)
      echo "::error::$TAG needs ppy.osu.Game $NUGET_VER, which is not on nuget.org, but its source channel is '${SOURCE_CHANNEL:-<missing>}'."
      exit 1
      ;;
  esac
elif [ "$PACKAGE_STATUS" != 200 ]; then
  echo "::error::nuget.org returned HTTP $PACKAGE_STATUS for ppy.osu.Game $NUGET_VER."
  exit 1
fi

PACKAGE_ENTRIES="$(unzip -Z1 "$PACKAGE_FILE")" || {
  echo "::error::Cannot inspect ppy.osu.Game package: $PACKAGE_FILE"
  exit 1
}
PACKAGE_FRAMEWORKS="$(sed -nE 's#^lib/(net[0-9]+\.[0-9]+)/osu\.Game\.dll$#\1#p' <<< "$PACKAGE_ENTRIES" | sort -u)"
if [[ ! "$PACKAGE_FRAMEWORKS" =~ ^net[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Expected one osu.Game target framework in $PACKAGE_FILE; found '${PACKAGE_FRAMEWORKS:-none}'."
  exit 1
fi
echo "::notice::Building $TAG against ppy.osu.Game $NUGET_VER ($PACKAGE_FRAMEWORKS)."

BUILD_VERSION_ARGS=()
if [ "$PROJECT_NUGET_VER" != "$NUGET_VER" ]; then
  BUILD_VERSION_ARGS+=("/p:PpyOsuGameVersion=$NUGET_VER")
  echo "::notice::Overriding historical tag dependency $PROJECT_NUGET_VER with channel target $NUGET_VER."
fi
BUILD_VERSION_ARGS+=("/p:TargetFramework=$PACKAGE_FRAMEWORKS")

# Restore explicitly so historical tags do not need a NuGet.config file from
# main. Configuration must match the following no-restore build: ILRepack is a
# Release-only PackageReference and a default Debug restore omits its targets.
dotnet restore "$PROJECT" -p:Configuration=Release "${BUILD_VERSION_ARGS[@]}" \
  --source "$LOCAL_NUGET_DIR" --source https://api.nuget.org/v3/index.json
# ProjectReference framework negotiation still builds the protocol project at
# the framework declared by the checked-out tag. Restore that target explicitly:
# old tags declare net8.0 even when osu.Game now requires net10.0.
dotnet restore OverlayAPI.LazerProtocol/OverlayAPI.LazerProtocol.csproj -p:Configuration=Release \
  --source "$LOCAL_NUGET_DIR" --source https://api.nuget.org/v3/index.json
dotnet build "$PROJECT" -c Release --no-restore "${BUILD_VERSION_ARGS[@]}"

ARTIFACT="osu.Game.Rulesets.OverlayAPI/bin/Release/$PACKAGE_FRAMEWORKS/osu.Game.Rulesets.OverlayAPI.dll"
if [ ! -f "$ARTIFACT" ]; then
  echo "::error::Expected final ILRepack artifact was not found: $ARTIFACT"
  exit 1
fi

VERIFY_HELPER="${VERIFY_MERGED_ASSEMBLY_SCRIPT:-$(dirname "$0")/verify-merged-assembly.ps1}"
if [ ! -f "$VERIFY_HELPER" ]; then
  echo "::error::Merged assembly verifier was not found: $VERIFY_HELPER"
  exit 1
fi
pwsh -NoLogo -NoProfile -File "$VERIFY_HELPER" "$ARTIFACT"

COMMIT="$(git rev-parse --short=12 HEAD)"
NOTES="$(printf '%s\n\n- Channel: `%s`\n- osu! target: `%s`\n- ppy.osu.Game: `%s`\n- Source commit: `%s`\n\nThe single DLL asset is the final ILRepack ruleset assembly; copy it into the osu! `rulesets` directory.' \
  "$SUMMARY" "$CHANNEL" "$OSU_VER" "${NUGET_VER:-unknown}" "$COMMIT")"

ARGS=(release create "$TAG" "${ARTIFACT}#osu.Game.Rulesets.OverlayAPI.dll" --verify-tag --title "$TITLE" --notes "$NOTES" --generate-notes)
[ "$PRERELEASE" = true ] && ARGS+=(--prerelease)
if [ "$RELEASE_EXISTS" = true ]; then
  gh release upload "$TAG" "${ARTIFACT}#osu.Game.Rulesets.OverlayAPI.dll" --clobber
  gh release edit "$TAG" --title "$TITLE" --notes "$NOTES"
  echo "::notice::Replaced the asset and release notes for $TAG."
else
  gh "${ARGS[@]}"
fi
