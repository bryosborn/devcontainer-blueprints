#!/usr/bin/env bash
set -Eeuo pipefail

test "$(id -un)" = "${EXPECTED_USER}"
test "${HOME}" = "${EXPECTED_HOME}"
touch "${HOME}/.toolbox-write-test"
rm "${HOME}/.toolbox-write-test"
mkdir -p "${HOME}/.cache/Microsoft"
touch "${HOME}/.cache/Microsoft/.wolfi-write-test"
rm "${HOME}/.cache/Microsoft/.wolfi-write-test"
test "$(stat -c %u "${HOME}/.cache")" = "$(id -u)"
if [ "${DEVCONTAINER}" = true ]; then sudo -n true; fi
test "$(stat -c '%U:%G' /opt)" = "root:root"
test "$(stat -c '%U:%G' /workspaces)" = "root:root"
if [ "$DOCKER_CLI" = true ]; then docker --version; fi
if [ "$DOCKER_BUILDX" = true ]; then
  docker buildx version
elif [ "$DOCKER_CLI" = true ] && docker buildx version >/dev/null 2>&1; then
  echo 'Unexpected Buildx plugin' >&2; exit 1
fi
if [ "$DOCKER_COMPOSE" = true ]; then
  docker-compose version
  if [ "$DOCKER_CLI" = true ]; then docker compose version; fi
elif [ "$DOCKER_CLI" = true ] && docker compose version >/dev/null 2>&1; then
  echo 'Unexpected Compose plugin' >&2; exit 1
fi

if [ -n "${PYTHON_SELECTORS}" ]; then
  default_python=""
  for version in ${PYTHON_SELECTORS}; do
    python_command="python${version}"
    pip_command="pip${version}"
    "${python_command}" -c 'assert 40 + 2 == 42'
    "${python_command}" -m pip --version
    "${pip_command}" --version
    "${python_command}" -m venv "/tmp/venv-${version}"
    "/tmp/venv-${version}/bin/python" -c 'import pip; assert 40 + 2 == 42'
    "${python_command}" -m pip list --disable-pip-version-check >/dev/null
    default_python="$(printf '%s\n%s\n' "${default_python}" "${version}" | awk 'NF' | sort -V | tail -1)"
  done
  test "$(readlink -f "$(command -v python3)")" = \
    "$(readlink -f "$(command -v "python${default_python}")")"
fi

if [ -n "${JAVA_SELECTOR}" ]; then
  java --version 2>&1 | head -1 | grep -Eq "(^| )${JAVA_SELECTOR}([.+-]|$)"
  javac --version 2>&1 | grep -Eq "(^| )${JAVA_SELECTOR}([.+-]|$)"
  cat >/tmp/WolfiSmoke.java <<'JAVA'
public class WolfiSmoke {
  public static void main(String[] args) { System.out.println(40 + 2); }
}
JAVA
  javac /tmp/WolfiSmoke.java
  test "$(java -cp /tmp WolfiSmoke)" = 42
fi
if [ -n "${MAVEN_SELECTOR}" ]; then
  mvn --version | head -1 | grep -Eq "Apache Maven ${MAVEN_SELECTOR}([.+-]|$)"
  mkdir -p /tmp/maven-smoke
  cat >/tmp/maven-smoke/pom.xml <<'POM'
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>local.smoke</groupId>
  <artifactId>wolfi</artifactId>
  <version>1</version>
</project>
POM
  mvn --offline --batch-mode --file /tmp/maven-smoke/pom.xml validate
fi

if [ -n "${NODE_SELECTOR}" ]; then
  node -e 'if (40 + 2 !== 42) process.exit(1)'
  node --version | grep -Eq "^v${NODE_SELECTOR}([.+-]|$)"
  corepack --version
  node -e 'require("node:assert").strictEqual(process.platform, "linux")'
fi
if [ -n "${NPM_SELECTOR}" ]; then
  npm --version | grep -Eq "^${NPM_SELECTOR}([.+-]|$)"
  npx --version | grep -Eq "^${NPM_SELECTOR}([.+-]|$)"
  mkdir -p /tmp/npm-smoke
  printf '{"name":"toolbox-npm-smoke","version":"1.0.0"}\n' >/tmp/npm-smoke/package.json
  (cd /tmp/npm-smoke && npm pack --offline --ignore-scripts >/dev/null)
fi

if [ "${BUILD_ENABLED}" = true ]; then
  cat >/tmp/wolfi-smoke.c <<'C'
#include <stdio.h>
int main(void) { printf("%d\n", 40 + 2); return 0; }
C
  cc /tmp/wolfi-smoke.c -o /tmp/wolfi-smoke-cc
  if [ "$CLANG_ENABLED" = true ]; then clang /tmp/wolfi-smoke.c -o /tmp/wolfi-smoke-clang; fi
  test "$(/tmp/wolfi-smoke-cc)" = 42
  if [ "$CLANG_ENABLED" = true ]; then test "$(/tmp/wolfi-smoke-clang)" = 42; fi
  cat >/tmp/wolfi-smoke.cpp <<'CPP'
#include <iostream>
int main() { std::cout << 40 + 2 << '\n'; }
CPP
  c++ /tmp/wolfi-smoke.cpp -o /tmp/wolfi-smoke-cxx
  if [ "$CLANG_ENABLED" = true ]; then clang++ /tmp/wolfi-smoke.cpp -o /tmp/wolfi-smoke-clangxx; fi
  test "$(/tmp/wolfi-smoke-cxx)" = 42
  if [ "$CLANG_ENABLED" = true ]; then test "$(/tmp/wolfi-smoke-clangxx)" = 42; fi
  mkdir -p /tmp/cmake-smoke
  cat >/tmp/cmake-smoke/CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.20)
project(wolfi_smoke C)
add_executable(wolfi-smoke ../wolfi-smoke.c)
CMAKE
  cmake -S /tmp/cmake-smoke -B /tmp/cmake-smoke/build -DCMAKE_C_COMPILER=cc
  cmake --build /tmp/cmake-smoke/build
  test "$(/tmp/cmake-smoke/build/wolfi-smoke)" = 42
  openssl version
fi

if [ -n "${KUBECTL_SELECTOR}" ]; then
  kubectl version --client --output=json | jq -e ".clientVersion.gitVersion == \"v${KUBECTL_SELECTOR}\"" >/dev/null
  kubectl create configmap toolbox-fixture --from-literal=answer=42 --dry-run=client -o json \
    | jq -e '.kind == "ConfigMap" and .data.answer == "42"' >/dev/null
fi
if [ -n "${YQ_SELECTOR}" ]; then
  yq --version | grep -Eq "version v?${YQ_SELECTOR}([.+-]|$)"
  test "$(printf 'answer: 42\n' | yq '.answer')" = 42
fi

if [ -n "${RUST_TOOLCHAIN}" ]; then
  rustup show active-toolchain | grep -q "^${RUST_TOOLCHAIN}-"
  for component in ${RUST_COMPONENTS}; do
    rustup component list --installed | awk '{print $1}' | grep -Eq "^${component}(-|$)"
  done
  test "${CARGO_HOME}" = "${EXPECTED_HOME}/.cargo"
  case ":${PATH}:" in *":${CARGO_HOME}/bin:"*) ;; *) exit 1 ;; esac
  touch "${CARGO_HOME}/.write-test"
  rm "${CARGO_HOME}/.write-test"
  mkdir -p /tmp/rust-smoke/src
  cat >/tmp/rust-smoke/Cargo.toml <<'TOML'
[package]
name = "wolfi-smoke"
version = "0.1.0"
edition = "2021"

[dependencies]
TOML
  cat >/tmp/rust-smoke/src/main.rs <<'RUST'
fn answer() -> i32 {
    40 + 2
}

fn main() {
    println!("{}", answer());
}

#[cfg(test)]
mod tests {
    #[test]
    fn computes_answer() {
        assert_eq!(super::answer(), 42);
    }
}
RUST
  (cd /tmp/rust-smoke && cargo test --offline)
  case " ${RUST_COMPONENTS} " in
    *' clippy '*) (cd /tmp/rust-smoke && cargo clippy --offline --all-targets -- -D warnings) ;;
  esac
  case " ${RUST_COMPONENTS} " in
    *' rustfmt '*) (cd /tmp/rust-smoke && cargo fmt --check) ;;
  esac
  test "$(cd /tmp/rust-smoke && cargo run --offline --quiet)" = 42
fi

for forbidden_command in dockerd containerd ffmpeg; do
  if command -v "${forbidden_command}" >/dev/null 2>&1; then echo "Forbidden command: $forbidden_command" >&2; exit 1; fi
done
for process_file in /proc/[0-9]*/comm; do
  case "$(cat "$process_file" 2>/dev/null || true)" in dockerd|containerd) exit 1 ;; esac
done
forbidden_packages="docker docker-dind containerd ffmpeg font-noto chromium electron"
if [ "${PLAYWRIGHT_ENABLED}" != true ]; then
  forbidden_packages="$forbidden_packages fontconfig gtk+3.0 xorg-server mesa xvfb-run font-noto-cjk font-noto-emoji font-noto-thai"
fi
for forbidden_package in $forbidden_packages; do
  if apk info --installed "${forbidden_package}" >/dev/null 2>&1; then echo "Forbidden package: $forbidden_package" >&2; exit 1; fi
done

set -Eeuo pipefail
if [ -n "${ORAS_SELECTOR}" ]; then
  oras version | grep -Eq "Version:[[:space:]]+${ORAS_SELECTOR}([.+-]|$)|^${ORAS_SELECTOR}([.+-]|$)"
  mkdir -p /tmp/oras-input /tmp/oras-layout /tmp/oras-output
  printf 'wolfi offline oras\n' >/tmp/oras-input/payload.txt
  (cd /tmp/oras-input && oras push --oci-layout /tmp/oras-layout:smoke payload.txt:text/plain)
  oras manifest fetch --oci-layout /tmp/oras-layout:smoke >/tmp/oras-manifest.json
  jq -e '.schemaVersion == 2' /tmp/oras-manifest.json >/dev/null
  oras pull --oci-layout /tmp/oras-layout:smoke --output /tmp/oras-output
  cmp /tmp/oras-input/payload.txt /tmp/oras-output/payload.txt
fi

if [ -n "${MONGOSH_SELECTOR}" ]; then
  mongosh --version | grep -Eq "^${MONGOSH_SELECTOR}([.+-]|$)"
  test "$(mongosh --nodb --quiet --eval 'print(40 + 2)')" = 42
fi
if [ -n "${MONGODB_TOOLS_SELECTOR}" ]; then
  for mongodb_binary in bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop; do
    "${mongodb_binary}" --version 2>&1 | grep -Eq "${MONGODB_TOOLS_SELECTOR}([.+-]|$)"
  done
  python3 - <<'PY'
import struct
open('/tmp/toolbox.bson', 'wb').write(struct.pack('<i', 17) + b'\x10answer\x00' + struct.pack('<i', 42) + b'\x00')
PY
  bsondump --pretty /tmp/toolbox.bson 2>/tmp/bsondump.log \
    | jq -e '.answer["$numberInt"] == "42"' >/dev/null
fi
echo "Passed every selected compiler, runtime, and client fixture."
