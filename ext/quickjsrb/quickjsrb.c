#include "quickjsrb.h"

VALUE rb_mQuickjs;


VALUE rb_module_say_hi(VALUE klass)
{
    VALUE r_hello = rb_str_new2("Hello!");
    return r_hello;
}

RUBY_FUNC_EXPORTED void
Init_quickjsrb(void)
{
  rb_mQuickjs = rb_define_module("Quickjs");
  rb_define_module_function(rb_mQuickjs, "say_hi", rb_module_say_hi, 0);
}
