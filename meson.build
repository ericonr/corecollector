project(
    'corecollector',
    'd',
    license: 'GPL-3.0-or-later',
    meson_version: '>=0.50',
    version: '0.0.1',
)

project_soversion = 0

d_mod_version = []

src_inc = include_directories('source')

hunt_dep = dependency('hunt-1')

prefix = get_option('prefix')
libexec_dir = join_paths(prefix, get_option('libexecdir'), 'corecollector')
varlib_dir = join_paths(prefix, get_option('localstatedir'), 'lib', 'corecollector')
sysconf_dir = join_paths(prefix, get_option('sysconfdir'), 'corecollector')
include_dir = join_paths(prefix, get_option('includedir'), 'd', 'corecollector')

subdir('source')
subdir('data')