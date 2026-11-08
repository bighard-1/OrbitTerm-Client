#!/usr/bin/env python3
"""Select the hosted image's JDK 17; let setup-java handle an absent JDK."""

import os
from pathlib import Path
import re
import subprocess


def select_java(env):
    if env.get('GITHUB_ACTIONS') != 'true' or env.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        return None
    arch = env.get('RUNNER_ARCH', '')
    expected_arch = {'ARM64': {'aarch64', 'arm64'}, 'X64': {'amd64', 'x86_64'}}.get(arch)
    if expected_arch is None:
        raise RuntimeError('Unsupported hosted Java architecture')
    home = next((env[key] for key in (f'JAVA_HOME_17_{arch.lower()}', f'JAVA_HOME_17_{arch}')
                 if env.get(key)), None)
    if home is None:
        return None
    if '\n' in home or '\r' in home or not Path(home).is_absolute():
        raise RuntimeError('Invalid hosted JDK path')
    java, javac = Path(home) / 'bin/java', Path(home) / 'bin/javac'
    if not java.is_file() or not javac.is_file():
        raise RuntimeError('Advertised hosted JDK is incomplete')
    result = subprocess.run([str(java), '-XshowSettings:properties', '-version'],
                            capture_output=True, text=True, check=True, timeout=20)
    properties = dict(re.findall(r'^\s*([\w.]+)\s*=\s*(.*?)\s*$',
                                 result.stdout + result.stderr, re.MULTILINE))
    if properties.get('java.specification.version') != '17' or properties.get('os.arch') not in expected_arch:
        raise RuntimeError('Hosted JDK major version or architecture differs from the required JDK')
    compiler = subprocess.run([str(javac), '-version'], capture_output=True,
                              text=True, check=True, timeout=20)
    if not re.fullmatch(r'javac 17(?:\.[\w.+-]+)?\s*', compiler.stdout + compiler.stderr):
        raise RuntimeError('Hosted compiler does not match JDK 17')
    resolved = str(Path(home).resolve())
    if '\n' in resolved or '\r' in resolved:
        raise RuntimeError('Invalid resolved hosted JDK path')
    return resolved


def main():
    home = select_java(os.environ)
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        output.write(f'available={str(home is not None).lower()}\n')
    if home is not None:
        with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as output:
            output.write(f'JAVA_HOME={home}\n')
        with open(os.environ['GITHUB_PATH'], 'a', encoding='utf-8') as output:
            output.write(f'{home}/bin\n')
        print('Using hosted-image JDK 17 after checking the runtime, compiler, and architecture.')
    else:
        print('No hosted-image JDK 17 advertised; use the normal setup-java step.')


if __name__ == '__main__':
    main()
