#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/build/pure-local-tests"
BASE="$ROOT/build/jvm-test"
BUILT="$ROOT/../../android-standalone/build/android/classes"
TASK_JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
SDK=${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
JSON_JAR="$ROOT/build/dependencies/json-20240303.jar"
# The standalone suite builds the real application and JVM Android fixtures first.
test -f "$BUILT/com/airsim/phonecontrol/BridgeApplication.class"
test -f "$BASE/android/content/Context.class"
CP="$OUT:$JSON_JAR:$BASE:$BUILT:$ANDROID_JAR"
"$TASK_JAVA_HOME/bin/javac" --release 17 -cp "$CP" -d "$OUT" \
  "$ROOT/test/android/content/SharedPreferences.java" \
  "$ROOT/src/com/airsim/phonecontrol/ForwardingConfigStore.java" \
  "$ROOT/src/com/airsim/phonecontrol/StandaloneAgentStore.java" \
  "$ROOT/test/hero/RelayProfile.java" \
  "$ROOT/src/com/airsim/phonecontrol/HomeRelayRoute.java" \
  "$ROOT/src/com/airsim/phonecontrol/SMSDeliveryIdentity.java" \
  "$ROOT/src/com/airsim/phonecontrol/E2EKeyStore.java" \
  "$ROOT/src/com/airsim/phonecontrol/StandaloneSMSStore.java" \
  "$ROOT/src/com/airsim/phonecontrol/SMSRecentDeliveryIDs.java" \
  "$ROOT/test/com/airsim/phonecontrol/PureLocalSMSStoreTests.java" \
  "$ROOT/test/com/airsim/phonecontrol/RegistrationE2EKeyTests.java"
"$TASK_JAVA_HOME/bin/java" -ea -cp "$CP" com.airsim.phonecontrol.PureLocalSMSStoreTests
"$TASK_JAVA_HOME/bin/java" -ea -cp "$CP" com.airsim.phonecontrol.RegistrationE2EKeyTests
