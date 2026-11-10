#!/usr/bin/env bash
# Puts the native Android SDK (sdks/android) into your local Maven repository (~/.m2), so the example and any
# local app can resolve ai.zellio:zellio-chat. Nothing is published to a remote repository.
#
# Why not a Gradle composite build? The example uses the AGP of the Flutter template; sdks/android uses its own
# AGP. Gradle refuses two AGP versions in one build, so the SDK is built on its own and consumed as an AAR.
#
# Usage: scripts/publish-android-local.sh   (JDK 17+ and the Android SDK must be installed)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/../../android"
./gradlew :zellio-chat:publishReleasePublicationToMavenLocal
