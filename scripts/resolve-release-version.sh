#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GITHUB_REF_TYPE:?GITHUB_REF_TYPE is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"

DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
MANUAL_BUMP="${MANUAL_BUMP:-}"

SOURCE=""
PR_NUMBER=""
BUMP=""
TAG=""
VERSION=""
SKIP_REASON=""

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

semver_greater() {
  local left_major left_minor left_patch
  local right_major right_minor right_patch
  IFS=. read -r left_major left_minor left_patch <<< "$1"
  IFS=. read -r right_major right_minor right_patch <<< "$2"

  if (( 10#$left_major != 10#$right_major )); then
    (( 10#$left_major > 10#$right_major ))
  elif (( 10#$left_minor != 10#$right_minor )); then
    (( 10#$left_minor > 10#$right_minor ))
  else
    (( 10#$left_patch > 10#$right_patch ))
  fi
}

write_skip_outputs() {
  {
    echo "should_release=false"
    echo "source=$SOURCE"
    echo "pr_number=$PR_NUMBER"
    echo "bump=none"
    echo "tag="
    echo "version="
    echo "build_number="
    echo "dmg_name="
    echo "source_sha=$GITHUB_SHA"
  } >> "$GITHUB_OUTPUT"

  {
    echo "### 跳过发布"
    echo
    echo "- 来源：$SOURCE"
    echo "- 原因：$SKIP_REASON"
  } >> "$GITHUB_STEP_SUMMARY"
}

if [[ "$GITHUB_REF_TYPE" == "tag" ]]; then
  TAG="$GITHUB_REF_NAME"
  VERSION="${TAG#v}"
  SOURCE="显式标签 $TAG"
  BUMP="tag"
else
  if [[ "$GITHUB_REF_NAME" != "$DEFAULT_BRANCH" ]]; then
    echo "Automatic and manual releases must run from '$DEFAULT_BRANCH', got '$GITHUB_REF_NAME'" >&2
    exit 1
  fi

  existing_tag_output="$(
    git tag --points-at "$GITHUB_SHA" --list 'v*' |
      awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/ { print }'
  )"
  existing_tags=()
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && existing_tags+=("$candidate")
  done <<< "$existing_tag_output"

  if (( ${#existing_tags[@]} > 1 )); then
    echo "Commit $GITHUB_SHA has multiple release tags: ${existing_tags[*]}" >&2
    exit 1
  elif (( ${#existing_tags[@]} == 1 )); then
    TAG="${existing_tags[0]}"
    VERSION="${TAG#v}"
    SOURCE="复用当前提交已有标签 $TAG"
    BUMP="existing-tag"
  elif [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" ]]; then
    BUMP="${MANUAL_BUMP:-patch}"
    SOURCE="手动发布 ($BUMP)"
  elif [[ "$GITHUB_EVENT_NAME" == "push" ]]; then
    PR_NUMBER="$(
      gh api \
        -H "Accept: application/vnd.github+json" \
        "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" \
        --jq "map(select(.merged_at != null and .base.ref == \"$DEFAULT_BRANCH\")) | sort_by(.merged_at) | last | .number // empty"
    )"

    if [[ -z "$PR_NUMBER" ]]; then
      SOURCE="main 直接推送"
      SKIP_REASON="该提交没有关联已合并 PR；自动发布只处理 PR 合并"
      write_skip_outputs
      exit 0
    fi

    label_output="$(
      gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" \
        --jq '.labels[].name | select(test("^release:(major|minor|patch|none)$"))'
    )"
    release_labels=()
    while IFS= read -r label; do
      [[ -n "$label" ]] && release_labels+=("$label")
    done <<< "$label_output"

    if (( ${#release_labels[@]} > 1 )); then
      echo "PR #$PR_NUMBER has conflicting release labels: ${release_labels[*]}" >&2
      exit 1
    elif (( ${#release_labels[@]} == 1 )); then
      BUMP="${release_labels[0]#release:}"
      SOURCE="PR #$PR_NUMBER (${release_labels[0]})"
    else
      BUMP="patch"
      SOURCE="PR #$PR_NUMBER (无发布标签，默认 patch)"
    fi

    if [[ "$BUMP" == "none" ]]; then
      SKIP_REASON="PR 使用了 \`release:none\` 标签"
      write_skip_outputs
      exit 0
    fi
  else
    echo "Unsupported release event '$GITHUB_EVENT_NAME'" >&2
    exit 1
  fi

  if [[ -z "$VERSION" ]]; then
    if [[ ! "$BUMP" =~ ^(major|minor|patch)$ ]]; then
      echo "Invalid version bump '$BUMP'" >&2
      exit 1
    fi

    latest_tag="$(
      git tag --list 'v*' --sort=-v:refname |
        awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/ { print; exit }'
    )"
    base_version="${latest_tag#v}"
    project_version="$(
      sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);/\1/p' \
        whistleYoo.xcodeproj/project.pbxproj |
        head -n 1
    )"

    if [[ -n "$project_version" ]] && ! is_semver "$project_version"; then
      echo "Invalid MARKETING_VERSION '$project_version' in Xcode project" >&2
      exit 1
    fi
    if [[ -n "$project_version" ]] && { [[ -z "$base_version" ]] || semver_greater "$project_version" "$base_version"; }; then
      base_version="$project_version"
    fi
    [[ -n "$base_version" ]] || base_version="0.0.0"

    IFS=. read -r major minor patch <<< "$base_version"
    case "$BUMP" in
      major)
        major=$((10#$major + 1))
        minor=0
        patch=0
        ;;
      minor)
        minor=$((10#$minor + 1))
        patch=0
        ;;
      patch)
        patch=$((10#$patch + 1))
        ;;
    esac

    VERSION="$major.$minor.$patch"
    TAG="v$VERSION"
  fi
fi

if [[ "$TAG" == "$VERSION" ]] || ! is_semver "$VERSION"; then
  echo "Invalid release tag '$TAG'; expected vX.Y.Z" >&2
  exit 1
fi

IFS=. read -r major minor patch <<< "$VERSION"
if (( 10#$major > 999 || 10#$minor > 999 || 10#$patch > 999 )); then
  echo "Version components must each be between 0 and 999" >&2
  exit 1
fi
build_number=$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))
if (( build_number < 1 )); then
  echo "Version v0.0.0 cannot be published" >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/tags/$TAG"; then
  tag_commit="$(git rev-list -n 1 "$TAG")"
  if [[ "$tag_commit" != "$GITHUB_SHA" ]]; then
    echo "Tag $TAG already points to $tag_commit instead of $GITHUB_SHA" >&2
    exit 1
  fi
fi

{
  echo "should_release=true"
  echo "source=$SOURCE"
  echo "pr_number=$PR_NUMBER"
  echo "bump=$BUMP"
  echo "tag=$TAG"
  echo "version=$VERSION"
  echo "build_number=$build_number"
  echo "dmg_name=WhistleYoo-$VERSION.dmg"
  echo "source_sha=$GITHUB_SHA"
} >> "$GITHUB_OUTPUT"

{
  echo "### 发布决策"
  echo
  echo "- 来源：$SOURCE"
  echo "- 版本：\`$VERSION\`"
  echo "- 标签：\`$TAG\`"
  echo "- 构建号：\`$build_number\`"
  echo "- 提交：\`$GITHUB_SHA\`"
} >> "$GITHUB_STEP_SUMMARY"
