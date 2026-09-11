#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Select JDK 21 for this process without changing the user's global Java setup.
conditional_lock_java() {
  local candidate version
  local candidates=("${JAVA_HOME:-}" /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home /usr/local/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home)
  if [[ -x /usr/libexec/java_home ]]; then
    candidate="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
    candidates+=("$candidate")
  fi
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" && -x "$candidate/bin/java" ]] || continue
    version="$("$candidate/bin/java" -version 2>&1)" || continue
    if [[ "$version" == *'version "21.'* ]]; then
      export JAVA_HOME="$candidate"
      export PATH="$JAVA_HOME/bin:$PATH"
      return
    fi
  done
  version="$(java -version 2>&1 || true)"
  if [[ "$version" == *'version "21.'* ]]; then
    unset JAVA_HOME
    return
  fi
  echo 'JDK 21 is required. Install openjdk@21 or set JAVA_HOME to a working JDK 21.' >&2
  return 1
}
