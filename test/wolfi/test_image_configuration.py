"""Configuration-dependent runtime metadata and Docker invocation contracts."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('image_build', ROOT / 'src/wolfi/image/build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class ImageConfigurationTests(unittest.TestCase):
    def footer(self, **config):
        return build.image_footer({'config': {'build': {}, 'utilities': {}, **config}})

    def test_root_ci_has_no_optional_runtime_environment(self):
        result = self.footer()
        self.assertIn('HOME="/root"', result)
        self.assertIn('USER 0\n', result)
        for variable in ('DOCKER_HOST', 'WOLFI_DOD', 'JAVA_HOME', 'CARGO_HOME', 'RUSTUP_HOME'):
            self.assertNotIn(variable, result)

    def test_named_user_does_not_implicitly_enable_docker_or_languages(self):
        result = self.footer(user={'name': 'developer', 'uid': 1200, 'gid': 1300})
        self.assertIn('HOME="/home/developer"', result)
        self.assertIn('USER developer\n', result)
        self.assertNotIn('DOCKER_HOST', result)
        self.assertNotIn('CARGO_HOME', result)

    def test_rust_caches_follow_root_and_custom_user_homes(self):
        for user, home in [(None, '/root'), ({'name': 'developer'}, '/home/developer')]:
            config = {'build': {'rust': {'toolchain': 'nightly-2026-09-04'}}}
            if user:
                config['user'] = user
            result = self.footer(**config)
            self.assertIn(f'CARGO_HOME="{home}/.cargo"', result)
            self.assertIn('RUSTUP_HOME="/usr/local/rustup"', result)
            self.assertNotIn('DOCKER_HOST', result)

    def test_cli_does_not_implicitly_start_socket_proxy(self):
        self.assertNotIn('DOCKER_HOST', self.footer(docker={'cli': 'latest'}))
        result = self.footer(user={'name': 'developer'}, docker={'cli': 'latest', 'socket': True})
        self.assertIn('WOLFI_DOD_REMOTE_USER="developer"', result)
        self.assertIn('DOCKER_HOST="unix:///var/run/docker.sock"', result)


if __name__ == '__main__':
    unittest.main()
