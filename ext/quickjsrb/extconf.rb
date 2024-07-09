# frozen_string_literal: true

require 'mkmf'

$VPATH << "$(srcdir)/quickjs"

$srcs = [
  'libunicode.c',
  'libbf.c',
  'libregexp.c',
  'cutils.c',
  'quickjs.c',
  'quickjs-libc.c',
  'procs.c',
  'quickjsrb.c',
]

append_cflags('-I$(srcdir)/quickjs')

append_cflags('-fwrapv')
append_cflags('-g')
append_cflags('-O2')
append_cflags('-Wall')
append_cflags('-MMD')
append_cflags('-MF')
append_cflags('-Wextra')
append_cflags('-Wno-sign-compare')
append_cflags('-Wno-missing-field-initializers')
append_cflags('-Wundef -Wuninitialized')
append_cflags('-Wunused -Wno-unused-parameter')
append_cflags('-Wwrite-strings')
append_cflags('-Wchar-subscripts -funsigned-char')
append_cflags('-D_GNU_SOURCE -DCONFIG_VERSION=\"2024-02-14\" -DCONFIG_BIGNUM')

abort('could not find quickjs.h') unless find_header('quickjs.h')
abort('could not find cutils.h') unless find_header('cutils.h')
abort('could not find quickjs-libc.h') unless find_header('quickjs-libc.h')
#abort('could not find libbf.h') unless find_header('libbf.h')

# Makes all symbols private by default to avoid unintended conflict
# with other gems. To explicitly export symbols you can use RUBY_FUNC_EXPORTED
# selectively, or entirely remove this flag.
append_cflags('-fvisibility=hidden')
$warnflags = ''

create_makefile('quickjs/quickjsrb')
