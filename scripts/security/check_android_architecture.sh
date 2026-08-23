#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

android_project="$ORBIT_ROOT/clients/android/OrbitTermAndroid"

for module in app core data domain feature design; do
  [[ -f "$android_project/$module/build.gradle.kts" ]] || fail "Android module is missing: $module"
done

require_no_app_imports() {
  local module="$1"
  if rg -n '^import com\.orbitterm\.android\.app\.' "$android_project/$module/src/main" -g '*.kt'; then
    fail "$module must not depend on app implementation types"
  fi
}

require_no_app_imports core
require_no_app_imports data
require_no_app_imports feature
require_no_app_imports domain
require_no_app_imports design

if rg -n 'project\(":(app|data|feature|design|core)"\)' "$android_project/domain/build.gradle.kts"; then
  fail "domain may not depend on upper Android modules"
fi
if rg -n 'project\(":(app|data|feature|design)"\)' "$android_project/core/build.gradle.kts"; then
  fail "core may depend only on domain"
fi
if rg -n 'project\(' "$android_project/design/build.gradle.kts"; then
  fail "design may not depend on feature, data, core, or app"
fi
if rg -n 'project\(":(app|feature|design)"\)' "$android_project/data/build.gradle.kts"; then
  fail "data may depend only on core and domain"
fi
if rg -n 'project\(":app"\)' "$android_project/feature/build.gradle.kts"; then
  fail "feature must not depend on app"
fi

pass "Android architecture boundaries"
