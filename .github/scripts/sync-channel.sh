#!/usr/bin/env bash
# Sync one osu! release channel and report a tag that still needs a GitHub Release.
#
# Usage: sync-channel.sh <channel> <ppy_bare_version> <nuget_version>
#   channel       : lazer | tachyon
#   ppy_bare_ver  : e.g. 2026.624.0 (without the -lazer/-tachyon suffix)
#   nuget_version : exact ppy.osu.Game build version (official or source-built)
#
# Environment:
#   PACK_FROM_SOURCE : true when the package must be built from this channel tag
#
# Tag conventions:
#   v{base}-{channel}.{osuVer}  e.g. v0.2.0-lazer.2026.624.0
#   v{base}-a                   legacy manual release, e.g. v0.2.0-a
#   v{base}-a.{n}               preferred manual release, e.g. v0.2.1-a.1
#
# `a` sorts before both `lazer` and `tachyon` under SemVer. Therefore a
# channel release based on the same X.Y.Z is correctly newer than its manual
# predecessor; `manual` would sort after `lazer` and must not be used.
#
# A channel tag is deliberately allowed to point to an existing main commit when
# its ppy.osu.Game dependency already matches the selected package. This
# repairs a missed tag/release without creating a meaningless empty commit.
set -euo pipefail

CHANNEL="${1:-}"
TARGET_VER="${2:-}"
NUGET_VER="${3:-}"
PACK_FROM_SOURCE="${PACK_FROM_SOURCE:-false}"
CSPROJ="osu.Game.Rulesets.OverlayAPI/osu.Game.Rulesets.OverlayAPI.csproj"

if [[ ! "$CHANNEL" =~ ^(lazer|tachyon)$ ]] || [[ ! "$TARGET_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Usage: sync-channel.sh <lazer|tachyon> <YYYY.N.N> <nuget-version>"
  exit 1
fi

if [[ ! "$PACK_FROM_SOURCE" =~ ^(true|false)$ ]]; then
  echo "::error::PACK_FROM_SOURCE must be 'true' or 'false'."
  exit 1
fi

if [ "$PACK_FROM_SOURCE" = true ]; then
  TARGET_SOURCE_CHANNEL="$CHANNEL"
else
  TARGET_SOURCE_CHANNEL="nuget"
fi

write_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# True when $1 is greater than or equal to $2 according to NuGet-style numeric versions.
version_at_least() {
  [ "$1" = "$2" ] || [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
}

# Schedule a missing release, or a one-time replacement when its notes prove it
# was built against a different dependency version. release-tag.sh performs the
# actual safe --clobber operation when replace_existing is true.
schedule_release() {
  local tag="$1" expected_version="$2" release_state
  if release_state="$(gh release view "$tag" --json body,assets \
    --template '{{.body}}{{"\n"}}{{range .assets}}{{.name}}{{"\n"}}{{end}}' 2>/dev/null)"; then
    if grep -Fqx -- "- ppy.osu.Game: \`${expected_version}\`" <<< "$release_state" \
      && grep -Fqx -- "osu.Game.Rulesets.OverlayAPI.dll" <<< "$release_state"; then
      echo "Tag and GitHub Release $tag already have the expected dependency and asset."
      write_output release_tag ""
      write_output replace_existing false
    else
      echo "::warning::GitHub Release $tag has stale metadata or a missing asset; scheduling a corrective rebuild."
      write_output release_tag "$tag"
      write_output replace_existing true
    fi
  else
    echo "::notice::GitHub Release $tag is missing; scheduling publication."
    write_output release_tag "$tag"
    write_output replace_existing false
  fi
}

read_project_version() {
  local version
  version="$(sed -n 's/.*<PpyOsuGameVersion>\([^<]*\)<\/PpyOsuGameVersion>.*/\1/p' "$CSPROJ" | head -1)"
  if [ -z "$version" ]; then
    version="$(sed -n 's/.*<PackageReference *Include="ppy\.osu\.Game" *Version="\([^"]*\)".*/\1/p' "$CSPROJ" | head -1)"
  fi
  printf '%s' "$version"
}

read_project_source_channel() {
  local source
  source="$(sed -n 's/.*<PpyOsuGameSourceChannel>\([^<]*\)<\/PpyOsuGameSourceChannel>.*/\1/p' "$CSPROJ" | head -1)"
  printf '%s' "${source:-nuget}"
}

read_tag_version() {
  local content version
  content="$(git show "$1:$CSPROJ" 2>/dev/null)"
  version="$(sed -n 's/.*<PpyOsuGameVersion>\([^<]*\)<\/PpyOsuGameVersion>.*/\1/p' <<< "$content" | head -1)"
  if [ -z "$version" ]; then
    version="$(sed -n 's/.*<PackageReference *Include="ppy\.osu\.Game" *Version="\([^"]*\)".*/\1/p' <<< "$content" | head -1)"
  fi
  printf '%s' "$version"
}

set_project_target() {
  local version="$1" source_channel="$2"
  if grep -q '<PpyOsuGameVersion>' "$CSPROJ"; then
    sed -i -E "s|(<PpyOsuGameVersion>)[^<]+(</PpyOsuGameVersion>)|\1${version}\2|" "$CSPROJ"
  else
    sed -i -E "s|(<PackageReference *Include=\"ppy\.osu\.Game\" *Version=\")[^\"]+(\" *)|\1${version}\2|" "$CSPROJ"
  fi

  if grep -q '<PpyOsuGameSourceChannel>' "$CSPROJ"; then
    sed -i -E "s|(<PpyOsuGameSourceChannel>)[^<]+(</PpyOsuGameSourceChannel>)|\1${source_channel}\2|" "$CSPROJ"
  else
    sed -i "/<PropertyGroup Label=\"Project\">/a\\    <PpyOsuGameSourceChannel>${source_channel}</PpyOsuGameSourceChannel>" "$CSPROJ"
  fi
}

extract_base() {
  sed -E 's/^v([0-9]+\.[0-9]+\.[0-9]+)-.*/\1/' <<< "$1"
}

find_highest_manual_base() {
  local best="" pattern tag base
  for pattern in 'v*-a' 'v*-a.*'; do
    while IFS= read -r tag; do
      [ -z "$tag" ] && continue
      base="$(extract_base "$tag")"
      [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
      if [ -z "$best" ] || version_at_least "$base" "$best"; then
        best="$base"
      fi
    done < <(git tag -l "$pattern")
  done
  printf '%s' "$best"
}

echo "::group::Channel: $CHANNEL (target osu! version: $TARGET_VER)"
write_output release_tag ""
write_output replace_existing false

if [ -z "$NUGET_VER" ]; then
  echo "::notice::No published ppy.osu.Game package is available for $CHANNEL $TARGET_VER yet; waiting."
  write_output release_tag ""
  echo "::endgroup::"
  exit 0
fi

if [[ ! "$NUGET_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! version_at_least "$TARGET_VER" "$NUGET_VER"; then
  echo "::error::NuGet package version '$NUGET_VER' is not a valid stable version <= $TARGET_VER."
  exit 1
fi

if [ "$NUGET_VER" != "$TARGET_VER" ]; then
  echo "::warning::Exact ppy.osu.Game $TARGET_VER is unavailable for $CHANNEL; using newest compatible NuGet $NUGET_VER (<= target)."
fi

# Find the channel's newest tag by upstream osu! version, not tag creation date.
LOCAL_TAG=""
LOCAL_OSU_VER=""
BEST_VER=""
while IFS= read -r tag; do
  [ -z "$tag" ] && continue
  ver="${tag#v}"
  ver="${ver#*-${CHANNEL}.}"
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
  if [ -z "$BEST_VER" ] || version_at_least "$ver" "$BEST_VER"; then
    BEST_VER="$ver"
    LOCAL_TAG="$tag"
    LOCAL_OSU_VER="$ver"
  fi
done < <(git tag -l "v*-${CHANNEL}.*")

echo "Local channel tag: ${LOCAL_TAG:-<none>} (osu! version: ${LOCAL_OSU_VER:-<none>})"

if [ -n "$LOCAL_OSU_VER" ] && ! version_at_least "$TARGET_VER" "$LOCAL_OSU_VER"; then
  echo "::warning::Upstream $CHANNEL version $TARGET_VER is older than local $LOCAL_OSU_VER; skipping."
  write_output release_tag ""
  echo "::endgroup::"
  exit 0
fi

# If the tag already represents the newest upstream version, repair a missing
# GitHub Release. A newer manual base means the user has fixed or enhanced code
# after the previous channel tag. Create a real dependency commit when needed,
# then tag that main commit instead of rewriting history or adding empty commits.
if [ -n "$LOCAL_OSU_VER" ] && [ "$TARGET_VER" = "$LOCAL_OSU_VER" ]; then
  LOCAL_BASE="$(extract_base "$LOCAL_TAG")"
  MANUAL_BASE="$(find_highest_manual_base)"

  if [ -n "$MANUAL_BASE" ] && [ "$MANUAL_BASE" != "$LOCAL_BASE" ] && version_at_least "$MANUAL_BASE" "$LOCAL_BASE"; then
    CURRENT_CSPROJ_VER="$(read_project_version)"
    CURRENT_SOURCE_CHANNEL="$(read_project_source_channel)"
    if [[ ! "$CURRENT_CSPROJ_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "::error::Could not read ppy.osu.Game version from $CSPROJ"
      exit 1
    fi

    if [ "$CURRENT_CSPROJ_VER" != "$NUGET_VER" ] || [ "$CURRENT_SOURCE_CHANNEL" != "$TARGET_SOURCE_CHANNEL" ]; then
      set_project_target "$NUGET_VER" "$TARGET_SOURCE_CHANNEL"
      git add "$CSPROJ"
      git commit -m "chore(${CHANNEL}): target ppy.osu.Game ${NUGET_VER} for manual base ${MANUAL_BASE}"
      echo "Committed the real $CHANNEL dependency target: $CURRENT_CSPROJ_VER/$CURRENT_SOURCE_CHANNEL -> $NUGET_VER/$TARGET_SOURCE_CHANNEL."
    else
      echo "The selected dependency and source channel are already present; no channel commit is needed."
    fi

    NEW_TAG="v${MANUAL_BASE}-${CHANNEL}.${TARGET_VER}"
    echo "::notice::Manual base $MANUAL_BASE supersedes $LOCAL_TAG; creating channel tag $NEW_TAG on main."
    if ! git rev-parse -q --verify "refs/tags/$NEW_TAG" >/dev/null; then
      git tag "$NEW_TAG"
    fi

    git push origin main
    if ! git ls-remote --exit-code --tags origin "refs/tags/$NEW_TAG" >/dev/null 2>&1; then
      git push origin "$NEW_TAG"
    fi

    schedule_release "$NEW_TAG" "$NUGET_VER"
    echo "::endgroup::"
    exit 0
  fi

  TAG_CSPROJ_VER="$(read_tag_version "$LOCAL_TAG")"
  if [ "$TAG_CSPROJ_VER" != "$NUGET_VER" ]; then
    echo "::warning::Existing tag $LOCAL_TAG records ppy.osu.Game ${TAG_CSPROJ_VER:-<unknown>}, not $NUGET_VER. The publisher will override it from the immutable channel tag."
  fi

  schedule_release "$LOCAL_TAG" "$NUGET_VER"
  echo "::endgroup::"
  exit 0
fi

echo "Target $TARGET_VER is newer than ${LOCAL_OSU_VER:-<no channel tag>}; update needed."

CURRENT_CSPROJ_VER="$(read_project_version)"
CURRENT_SOURCE_CHANNEL="$(read_project_source_channel)"
if [[ ! "$CURRENT_CSPROJ_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::Could not read ppy.osu.Game version from $CSPROJ"
  exit 1
fi
echo "Current ppy.osu.Game dependency: $CURRENT_CSPROJ_VER/$CURRENT_SOURCE_CHANNEL (selected: $NUGET_VER/$TARGET_SOURCE_CHANNEL)"

if [ "$CURRENT_CSPROJ_VER" = "$NUGET_VER" ] && [ "$CURRENT_SOURCE_CHANNEL" = "$TARGET_SOURCE_CHANNEL" ]; then
  echo "Dependency and source channel are already selected; using the current main commit for the catch-up tag."
else
  set_project_target "$NUGET_VER" "$TARGET_SOURCE_CHANNEL"
  git add "$CSPROJ"
  git commit -m "chore(${CHANNEL}): bump ppy.osu.Game to ${NUGET_VER} for osu! ${TARGET_VER}"
  echo "Committed ppy.osu.Game target $NUGET_VER/$TARGET_SOURCE_CHANNEL."
fi

# A manual code release sets the base for future channel releases. This does
# not require an empty commit: the dependency bump above is the real change.
CHANNEL_BASE=""
[ -n "$LOCAL_TAG" ] && CHANNEL_BASE="$(extract_base "$LOCAL_TAG")"
MANUAL_BASE="$(find_highest_manual_base)"
MAX_BASE=""
for base in "$CHANNEL_BASE" "$MANUAL_BASE"; do
  [ -z "$base" ] && continue
  if [ -z "$MAX_BASE" ] || version_at_least "$base" "$MAX_BASE"; then
    MAX_BASE="$base"
  fi
done
[ -z "$MAX_BASE" ] && MAX_BASE="0.1.0"

NEW_TAG="v${MAX_BASE}-${CHANNEL}.${TARGET_VER}"
echo "New tag: $NEW_TAG"

if ! git rev-parse -q --verify "refs/tags/$NEW_TAG" >/dev/null; then
  git tag "$NEW_TAG"
fi

# Push main first. A non-fast-forward failure leaves the remote untouched and
# makes the next scheduled run retry safely.
git push origin main
if ! git ls-remote --exit-code --tags origin "refs/tags/$NEW_TAG" >/dev/null 2>&1; then
  git push origin "$NEW_TAG"
  echo "::notice::Pushed $NEW_TAG"
fi

schedule_release "$NEW_TAG" "$NUGET_VER"

echo "::endgroup::"
