# frozen_string_literal: true

require 'mkmf'

$VPATH << "$(srcdir)/quickjs"

$srcs = [
  'dtoa.c',
  'libunicode.c',
  'libregexp.c',
  'cutils.c',
  'quickjs.c',
  'quickjs-libc.c',
  'polyfill-intl-en.min.c',
  'polyfill-file.min.c',
  'quickjsrb.c',
]

append_cflags('-I$(srcdir)/quickjs')

append_cflags('-g')
append_cflags('-O2')
append_cflags('-Wall')
append_cflags('-MMD')
append_cflags('-MF')

case CONFIG['arch']
when /darwin/
  append_cflags('-Wextra')
  append_cflags('-Wno-sign-compare')
  append_cflags('-Wno-missing-field-initializers')
  append_cflags('-Wundef -Wuninitialized')
  append_cflags('-Wunused -Wno-unused-parameter')
  append_cflags('-Wwrite-strings')
  append_cflags('-Wchar-subscripts -funsigned-char')
else
  append_cflags('-Wno-array-bounds -Wno-format-truncation')
end

append_cflags('-fwrapv')
# NDEBUG: suppress QuickJS debug assertions that conflict with Ruby 4.0 GC
$CFLAGS << ' ' << '-D_GNU_SOURCE -DCONFIG_VERSION=\"2024-02-14\" -DNDEBUG'

abort('could not find quickjs.h') unless find_header('quickjs.h')
abort('could not find cutils.h') unless find_header('cutils.h')
abort('could not find quickjs-libc.h') unless find_header('quickjs-libc.h')

# Makes all symbols private by default to avoid unintended conflict
# with other gems. To explicitly export symbols you can use RUBY_FUNC_EXPORTED
# selectively, or entirely remove this flag.
append_cflags('-fvisibility=hidden')
$warnflags = ''

create_makefile('quickjs/quickjsrb') do |conf|
  conf.push <<COMPILE_POLYFILL
QJS_LIB_OBJS= quickjs.o dtoa.o libregexp.o libunicode.o cutils.o quickjs-libc.o
POLYFILL_OPTS=-fno-string-normalize -fno-typedarray -fno-typedarray -fno-eval -fno-proxy -fno-module-loader

qjsc: ./qjsc.o $(QJS_LIB_OBJS)
		$(CC) -g -o $@ $^ -lm -ldl -lpthread
polyfill-intl-en.min.js:
		$(COPY) $(srcdir)/vendor/$@ $@
polyfill-intl-en.min.c: ./qjsc polyfill-intl-en.min.js
		./qjsc $(POLYFILL_OPTS) -c -M polyfill/intl-en.so,intlen -m -o $@ polyfill-intl-en.min.js
polyfill-file.min.js:
		$(COPY) $(srcdir)/vendor/$@ $@
polyfill-file.min.c: ./qjsc polyfill-file.min.js
		./qjsc -fno-string-normalize -fno-eval -fno-proxy -fno-module-loader -c -M polyfill/file.so,file -m -o $@ polyfill-file.min.js
COMPILE_POLYFILL
  conf
end
