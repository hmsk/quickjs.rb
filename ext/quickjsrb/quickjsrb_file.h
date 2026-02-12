#ifndef QUICKJSRB_FILE_H
#define QUICKJSRB_FILE_H 1

// This header is included by quickjsrb.c (which already includes quickjsrb.h)
// and quickjsrb_file.c (which includes quickjsrb.h before this header).
// So we rely on VMData, JSValue, etc. being already defined.

void quickjsrb_init_file_proxy(VMData *data);
JSValue quickjsrb_file_to_js(JSContext *ctx, VALUE r_file);

#endif /* QUICKJSRB_FILE_H */
