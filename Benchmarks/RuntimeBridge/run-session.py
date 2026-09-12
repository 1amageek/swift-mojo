#!/usr/bin/env python3
"""Benchmark the prepared public session binding against its exact C dispatcher."""
import argparse
import json
import os
import pathlib
import platform
import re
import subprocess


def run(arguments, **options):
    subprocess.run([str(value) for value in arguments], check=True, timeout=120, **options)


def main():
    root = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products', type=pathlib.Path, default=root / '.build/out/Products/Debug')
    parser.add_argument('--swiftc', default='swiftc')
    parser.add_argument('--allocations', action='store_true', help='Run allocator interception separately from timing')
    options = parser.parse_args()
    products = options.products.resolve()
    proof = root / '.build/runtime-session-benchmark'
    proof.mkdir(parents=True, exist_ok=True)
    artifact = root / 'Generated/MojoBuildPluginIntegrationFixture'
    manifest = json.loads((artifact / 'MojoArtifact.json').read_text())
    ids = {binding['functionName']: str(binding['bindingID']) for binding in manifest['bindings']}
    apple = platform.system() == 'Darwin'
    machine = platform.machine()
    if not ((apple and machine in ('arm64', 'x86_64')) or (platform.system() == 'Linux' and machine == 'aarch64')):
        raise SystemExit('No prepared native fixture slice for this host')
    triple = machine + '-apple-macosx14.0' if apple else 'aarch64-unknown-linux-gnu'
    cpu = 'x86-64' if machine == 'x86_64' else 'generic'
    source = root / 'Sources/MojoBuildPluginIntegrationFixture/MojoBuildPluginIntegrationFixture.swift'
    registry = proof / 'Bindings.swift'
    run([products / 'swift-mojo', 'verify', '--output-dir', artifact,
         '--source-root', root, '--source', source, '--mojo-package', root / 'Mojo/SessionModel',
         '--generated-source', registry, '--target-triple', triple, '--target-cpu', cpu])
    # Read the domain emitted by the verifier. It is not the factory binding ID.
    domain = re.search(r'case ' + ids['integrationOpenSession'] + r': sessionDomainID = (\d+)', registry.read_text())
    if domain is None:
        raise SystemExit('Verified registry did not emit the expected session factory')
    text = (root / 'Benchmarks/RuntimeBridge/SessionBenchmark.swift.template').read_text()
    text = text.replace('__SESSION_DOMAIN__', domain[1]).replace('__BINDING_ID__', ids['integrationScale'])
    text = text.replace('__DIRECT_SYMBOL__', manifest['artifactIdentity']['symbolPrefix'] + '_call_session_f32_buffer_f32_buffer_i32_v1')
    benchmark = proof / 'SessionBenchmark.swift'
    benchmark.write_text(text)
    compiler = [options.swiftc, '-swift-version', '6', '-O', '-load-plugin-executable', str(products / 'MojoMacros') + '#MojoMacros']
    if apple:
        compiler += ['-target', machine + '-apple-macosx15.0']
    library = proof / ('libMojo.dylib' if apple else 'libMojo.so')
    run(compiler + ['-parse-as-library', '-emit-library', '-emit-module', '-module-name', 'Mojo',
        '-emit-module-path', proof / 'Mojo.swiftmodule', *sorted((root / 'Sources/Mojo').glob('*.swift')), '-o', library])
    if apple:
        linkage = ['-F', artifact / 'SwiftMojo_MojoBuildPluginIntegrationFixture_ABI.xcframework/macos-arm64_x86_64',
                   '-framework', 'SwiftMojo_MojoBuildPluginIntegrationFixture_ABI']
    else:
        bundle = artifact / 'SwiftMojo_MojoBuildPluginIntegrationFixture_ABI.artifactbundle'
        variant = next(item for item in manifest['slices'] if item['target']['triple'] == triple)
        linkage = ['-I', bundle / 'include', bundle / 'variants' / variant['libraryIdentifier'] / 'libSwiftMojo_MojoBuildPluginIntegrationFixture_ABI.a']
    environment = os.environ.copy()
    if options.allocations:
        probe = root / 'Benchmarks/RuntimeBridge/AllocationProbe'
        probe_library = proof / ('libAllocationProbe.dylib' if apple else 'libAllocationProbe.so')
        flags = ['-dynamiclib', '-mmacosx-version-min=15.0'] if apple else ['-fPIC', '-shared', '-ldl', '-pthread']
        run(['cc', '-O2', *flags, probe / 'probe.c', '-o', probe_library])
        linkage += ['-I', probe, '-lAllocationProbe']
        benchmark = probe / 'AllocationAcceptance.swift'
        environment['DYLD_INSERT_LIBRARIES' if apple else 'LD_PRELOAD'] = str(probe_library)
    binary = proof / ('allocation-acceptance' if options.allocations else 'session-benchmark')
    run(compiler + ['-parse-as-library', '-I', proof, source, registry, benchmark,
        '-L', proof, '-lMojo', *linkage, '-Xlinker', '-rpath', '-Xlinker', proof, '-o', binary])
    run([options.swiftc, '--version'])
    run([binary], env=environment)


if __name__ == '__main__':
    main()
