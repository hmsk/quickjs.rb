#include "ruby.h"

#define MAX_NUM_OF_PROC 100

typedef struct ProcEntry {
  char *key;
  VALUE proc;
  struct ProcEntry *next;
} ProcEntry;

typedef struct ProcEntryMap {
  ProcEntry **entries;
} ProcEntryMap;

typedef struct QuickjsrbRuntimeState {
  ProcEntryMap *procs;
} QuickjsrbRuntimeState;

QuickjsrbRuntimeState *create_quickjsrb_runtime_state();
VALUE get_proc(ProcEntryMap *entryMap, const char *key);
void set_proc(ProcEntryMap *entryMap, const char *key, VALUE proc);
void free_quickjsrb_runtime_state(QuickjsrbRuntimeState *state);
