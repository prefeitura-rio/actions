#!/usr/bin/env bash
# GitLab replacement for the GitHub actions/setup-java + stCarolas/setup-maven
# steps: provisions a Temurin JDK and Maven when the repo is a Java project, and
# publishes JAVA_HOME + PATH through the GitHub-compat env files so the shared
# orchestrator (gitlab-run.sh) picks them up for `mvn` and the Sonar scan.
#
# Reads: TOOL_DIR (where to install), GITHUB_ENV, GITHUB_PATH.
# Optional: JDK_VERSION (Temurin major, default 24), MAVEN_VERSION (default 3.9.12).
set -eo pipefail

JDK_VERSION="${JDK_VERSION:-24}"
MAVEN_VERSION="${MAVEN_VERSION:-3.9.12}"
DEST="${TOOL_DIR:-$HOME/.sast-tools}"
mkdir -p "$DEST"

if [ ! -x "$DEST/jdk/bin/java" ]; then
  echo "setup-java: installing Temurin JDK ${JDK_VERSION}..."
  tmp="$(mktemp -d)"
  curl -sfL "https://api.adoptium.net/v3/binary/latest/${JDK_VERSION}/ga/linux/x64/jdk/hotspot/normal/eclipse" -o "$tmp/jdk.tar.gz"
  rm -rf "$DEST/jdk" && mkdir -p "$DEST/jdk"
  tar -xzf "$tmp/jdk.tar.gz" -C "$DEST/jdk" --strip-components=1
  rm -rf "$tmp"
fi

if [ ! -x "$DEST/maven/bin/mvn" ]; then
  echo "setup-java: installing Maven ${MAVEN_VERSION}..."
  tmp="$(mktemp -d)"
  curl -sfL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o "$tmp/mvn.tgz"
  rm -rf "$DEST/maven" && mkdir -p "$DEST/maven"
  tar -xzf "$tmp/mvn.tgz" -C "$DEST/maven" --strip-components=1
  rm -rf "$tmp"
fi

{
  echo "JAVA_HOME=$DEST/jdk"
} >>"$GITHUB_ENV"
{
  echo "$DEST/jdk/bin"
  echo "$DEST/maven/bin"
} >>"$GITHUB_PATH"

echo "setup-java: JAVA_HOME=$DEST/jdk, maven $MAVEN_VERSION ready."
